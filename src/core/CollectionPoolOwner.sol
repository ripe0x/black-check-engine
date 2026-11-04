// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Governed} from "./Governed.sol";
import {
    IFWAPool, IFWAFactory, IPurchaseOperator, IFWABurnable, FWA_ACQUISITIONS_ENABLED
} from "../interfaces/IFWA.sol";
import {ICollectionGame} from "../interfaces/ICollectionGames.sol";
import {IChecksOriginals} from "../interfaces/IChecks.sol";

interface IGameGate {
    function gateParams() external view returns (uint256 minShapes, uint256 maxEdgeBps);
}

interface IERC721Min {
    function ownerOf(uint256 tokenId) external view returns (address);
    function setApprovalForAll(address operator, bool approved) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
}

interface IShapesMinter {
    function burn(uint256 tokenId) external;
    function mintTo(uint256 amountWei, address to) external payable returns (uint256 tokenId);
    function mintFee() external view returns (uint256);
    function denominationCount() external view returns (uint8);
    function denominationAt(uint8 index) external view returns (uint256);
}

/// @dev The dedicated Draw Packs instance (lib/shape-packs, `ShapePacks`): an ERC-721 whose token holds Shapes.
interface IDrawPacks {
    function MIN_PACK_VALUE() external view returns (uint256);
    function createPackTo(uint256[] calldata shapeIds, uint32[] calldata mintCounts, address to)
        external
        payable
        returns (uint256 packId);
    function redeem(uint256 packId) external;
}

/// @title CollectionPoolOwner
/// @notice Creates and permanently owns the FWA V2 pool of the Checks game, and holds its NFTs: Checks Originals (in
///         custody or listed) and the Shapes and Draw Packs it lists. FWA ownership can never change, so this contract
///         is deliberately small and has no generic execute: each FWA owner action is a narrow function.
/// @dev Provenance: ripe0x/collection-games `src/core/CollectionPoolOwner.sol` (409ca75). Changed for Checks
///      (docs/REBASE_PLAN.md R3): Checks are valued by a council-set price schedule per tier (D003) instead of their
///      cost, decay per survived draw to a floor (D005) instead of shared gameplay credit, survival is derived in O(1)
///      from FWA's own counts (C010, from rc2 `FwaV2Controller`), and the Checks desk (composition, Black Check
///      formation, buyouts) may withdraw specific eligible listings for those operations only.
///      Who may do what:
///      - the game (CollectionGame, set once at wiring) has ordinary prizes minted here and listed (`mintAndList`,
///        paid with the game's ETH): a Shape at a Shapes denomination, or a Draw Pack of the fewest Shapes that make it
///        up exactly; it withdraws them (a withdrawn Shape is burned and a withdrawn Pack redeemed, their backing to the
///        game), toggles FWA purchases, collects owner proceeds (forwarded to the game), retires the pool, and runs
///        `processCollection`;
///      - the vault (FundingVault) registers Checks it delivered here (bought or donated);
///      - the desk (ChecksDesk, set once at wiring) composes two listed Checks, forms a Black Check from 64 listed
///        singles, or releases one listed Check to a buyer who paid for it (`deskCompose`, `deskFormBlack`,
///        `deskRelease`); it checks eligibility and payment, this contract checks the listings and moves the tokens;
///      - once the game has retired (a migration, or the sunset), the MigrationAuthority moves custody Checks to the
///        successor (`migrateApe`).
///      Check listing rules:
///      - every Check held is listed, in batches during maintenance (`processCollection`), at its tier's `schedule`
///        price; a tier with no schedule price stays in custody until the council sets one;
///      - survival: a draw that allocated any prize while a Check stayed listed counts one survived draw for it. FWA
///        removes exactly one active listing per allocation, so allocations = listed - withdrawn - active (every
///        listing and withdrawal goes through this contract, and listings are made only with no request unsettled, so
///        they are active at once). A new listing records that count as its entry (C010, D002);
///      - its notional is the schedule price less `decayBps` of it per survived draw and less `dailyDecayBps` of it per
///        day in the draw (the decay clock, off at launch), never below `floorBps` of it (D005). A schedule change
///        (council) moves notionals up or down at the next reprice, keeping earned decay;
///      - the expected cost of Check prizes, `sum(schedule_i / notional_i) / activeListings`, stays within `targetBps`
///        after any listing or repricing made here, even after the most requests the purchase gate can admit have each
///        removed a listing (`gateHeadroom`). A listing or decay step that would exceed it waits, and `rowsShort` tells
///        the game how many more board listings would let it proceed;
///      - Checks leave only to FWA (listing), back here (withdrawal or recovered refund), to a winning player (FWA
///        delivery), into canonical composition (burned by Checks), to a buyer through the desk, or, once the game has
///        retired, to the successor (`migrateApe`).
///      It is also FWA's purchase operator. `canPurchase` reads live FWA state and this contract's conservative
///      exposure total only, never the game's ledger, so it stays safe however long keepers are away (see there).
contract CollectionPoolOwner is IPurchaseOperator, ReentrancyGuard, Governed {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    /// @notice The lowest reference cost a registered Check is recorded at (its cash cost stays what was paid).
    uint256 public constant MIN_REF_COST = 0.01 ether;
    /// @notice The most Shapes one Draw Pack prize may hold: every maintenance call that mints Packs is measured under
    ///         EIP-7825's gas cap with Packs of this size (D85), so no pattern can make one exceed it.
    uint256 public constant MAX_PACK_SHAPES = 4;
    /// @notice Checks tiers (`divisorIndex`): 0 = 80 checks, 1 = 40, 2 = 20, 3 = 10, 4 = 5, 5 = 4, 6 = 1, 7 = Black.
    uint256 public constant TIERS = 8;
    uint8 internal constant SINGLE = 6;
    uint8 internal constant BLACK = 7;
    /// @notice Bounds on a scheduled tier price (zero: the tier is not listed).
    uint256 public constant MIN_SCHEDULE = 0.001 ether;
    uint256 public constant MAX_SCHEDULE = 100_000 ether;
    /// @notice The purchase gate's exposure ceiling, and the highest target the owner may set.
    uint256 public constant MAX_EXPOSURE_BPS = 5_000;
    /// @notice Collection NFTs listed per call (FWA takes up to 20 in one inventory batch).
    uint256 public constant LIST_BATCH = 10;
    /// @notice Collection NFTs listed in a call that also minted Packs: a Pack restock and a full Ape batch together
    ///         came within 2% of EIP-7825's per-transaction gas cap (test/fork/TxCap.t.sol); the rest wait a window.
    uint256 public constant LIST_BATCH_AFTER_PACKS = 5;
    /// @dev Transient: set when this transaction minted a Pack (`_mintPrize`), read by `_listBatch`.
    uint256 private constant _PACKS_MINTED_SLOT = uint256(keccak256("CollectionPoolOwner.packsMinted"));
    /// @notice Listed collection NFTs examined for repricing per call.
    uint256 public constant DECAY_BATCH = 10;
    /// @notice Largest FWA batch assumed if the pool's own limit cannot be read.
    uint256 public constant MAX_BATCH_FALLBACK = 10;

    IFWAFactory public immutable factory;
    address public immutable expectedImplementation;
    address public immutable shapes;
    /// @notice The dedicated Draw Packs instance whose Packs are listed as ordinary prizes.
    address public immutable packs;
    address public immutable collection;
    address public immutable vault;
    /// @notice The MigrationAuthority, the only caller of `migrateApe`.
    address public immutable migrator;

    address public game;
    /// @notice The Checks desk (composition, Black Check formation, buyouts), set once at wiring.
    address public desk;
    IFWAPool public pool;
    /// @notice The rest of the system (burner, hook, liquidity, coin, Admin, Sunset, adapter, Lens, router, the Draw
    ///         Packs renderer), recorded at wiring: none may be a purchaser, since none can move a prize it receives.
    mapping(address => bool) public isSystem;

    /// @notice How Checks decay and fit the board (council: they set what each Check is worth in the draw, D012).
    struct ListingParams {
        uint256 decayBps; // notional drop per survived draw, bps of the schedule price (D005: 20)
        uint256 floorBps; // lowest notional, bps of the schedule price (D005: 8,500), 1 to 10,000
        uint256 stepBps; // smallest change worth an FWA reprice, bps of the current notional
        uint256 targetBps; // Check exposure target, at most MAX_EXPOSURE_BPS
        uint256 dailyDecayBps; // notional drop per day in the draw, bps of the schedule price (zero: off, D015)
    }

    ListingParams internal _lp;
    /// @notice Price per tier (council, D003): the value a Check is listed at before decay, and its exposure value.
    uint256[8] internal _schedule;
    /// @notice Every listing this contract made at FWA, and every listing it withdrew (survival, C010).
    uint256 public listedTotal;
    uint256 public withdrawnTotal;
    /// @notice A purchase is admitted only while fewer than `maxInFlight` FWA requests are unsettled.
    uint256 public maxInFlight;
    /// @notice FWA's per-transaction request limit for this pool (read at pool creation). FWA asks the purchase
    ///         operator once per transaction without the count, so every purchase is assumed to be a full batch.
    uint256 public maxBatch;
    /// @notice `sum(refCost × 1e18 / notional)` over collection listings marked open here. Listings leave it only when
    ///         this contract records them won, returned or out of the draw, so a stale value (no keeper) overstates it.
    uint256 public exposureSum;
    /// @notice Collection listings marked open here (stale value overstates, like `exposureSum`).
    uint256 public openCollection;
    /// @notice More active listings (ordinary board rows) the last `processCollection` needed to list or reprice
    ///         every NFT it examined within the target. The game grows the board by it when the vault can pay.
    uint256 public rowsShort;
    /// @notice Next position in `_listed` the decay pass examines.
    uint256 public decayCursor;
    /// @dev The decay clock at `_clockAt`: the time decay credited to each NFT in the draw, bps of its reference
    ///      cost scaled by WAD. It runs at `dailyDecayBps` a day and is checkpointed whenever the rate changes, so a
    ///      rate switched on later applies from then, never back to launch.
    uint256 internal _clock;
    uint256 internal _clockAt;

    enum NftState {
        None,
        Custody,
        Listed,
        Won,
        Migrated,
        Burned, // consumed by canonical composition or Black Check formation
        Sold // released to a buyer through the desk
    }

    /// @notice Source of a Check: 0 bought, 1 donated.
    struct Nft {
        uint128 refCost; // what it was recorded at on arrival (accounting, the sunset's floor)
        uint128 cashCost; // ETH the protocol actually paid
        uint8 tier; // Checks `divisorIndex`, updated by composition
        uint8 source;
        NftState state;
    }

    /// @notice A Check listing (one survival episode).
    struct CListing {
        uint256 tokenId;
        uint128 notional; // published at FWA
        uint128 term; // its exposure term when last priced: schedule × 1e18 / notional
        uint64 entry; // allocations (`allocated()`) when listed: its survival starts here
        bool open; // in the draw (Active at FWA)
        uint128 clockStart; // `decayClock()` when listed
    }

    mapping(uint256 tokenId => Nft) public nfts;
    mapping(uint256 listingId => CListing) public cListings;
    mapping(uint256 listingId => bool) public isCollectionListing;
    mapping(uint256 listingId => uint256) internal _listedIndex; // index + 1 in `_listed`
    uint256[] internal _custody;
    mapping(uint256 tokenId => uint256) internal _custodyIndex; // index + 1 in `_custody`
    uint256[] internal _listed;

    uint256 public registeredCount;
    uint256 public wonCount;
    uint256 public wonRefCost;
    uint256[2] public wonCashCost; // by source
    uint256 public migratedCount;
    uint256 public burnedCount;
    uint256 public soldCount;

    event PoolCreated(address pool, uint256 creationFee);
    event Registered(uint256 indexed tokenId, uint256 refCost, uint256 cashCost, uint8 source);
    event CollectionListed(uint256 indexed listingId, uint256 indexed tokenId, uint256 notional);
    event Decayed(uint256 indexed listingId, uint256 fromNotional, uint256 toNotional);
    event CollectionWon(uint256 indexed listingId, uint256 indexed tokenId, uint256 refCost, uint256 cashCost);
    event CollectionReturned(uint256 indexed listingId, uint256 indexed tokenId);
    event ListingParamsSet(ListingParams p);
    event MaxInFlightSet(uint256 n);
    event ApeMigrated(uint256 indexed tokenId, address indexed custody, uint256 refCost, uint256 cashCost, uint8 source);
    event ScheduleSet(uint256[8] prices);
    event Composed(uint256 indexed keep, uint256 indexed burned, uint8 tier);
    event BlackFormed(uint256 indexed tokenId);
    event Released(uint256 indexed tokenId, address indexed to);

    error NotGame();
    error NotVault();
    error PoolExists();
    error NotCustody();
    error WrongCollection();
    error NotRetired();
    error Unsolicited();
    error BadPrize();
    error NotMigrator();
    error NotDesk();
    error Busy();
    error NotListed();

    /// @notice Constructor arguments.
    struct Init {
        address admin;
        address factory;
        address expectedImplementation;
        address shapes;
        address packs;
        address collection;
        address vault;
        address migrator;
        ListingParams listing;
        uint256[8] schedule;
        uint256 maxInFlight;
    }

    constructor(Init memory i) Governed(i.admin, true) {
        if (
            i.factory == address(0) || i.shapes == address(0) || i.collection == address(0) || i.vault == address(0)
                || i.collection == i.shapes || i.packs.code.length == 0
                || i.packs == i.collection || i.packs == i.shapes
        ) revert ZeroAddress();
        factory = IFWAFactory(i.factory);
        expectedImplementation = i.expectedImplementation;
        shapes = i.shapes;
        packs = i.packs;
        collection = i.collection;
        vault = i.vault;
        migrator = i.migrator;
        _setListingParams(i.listing);
        _setSchedule(i.schedule);
        _setMaxInFlight(i.maxInFlight);
    }

    modifier onlyGame() {
        if (msg.sender != game) revert NotGame();
        _;
    }

    modifier onlyDesk() {
        if (msg.sender != desk) revert NotDesk();
        _;
    }

    /// @notice One-shot wiring by the deployer: the game, the desk and the rest of the system's contracts (none of
    ///         which may be a purchaser). It can never change.
    function wire(address game_, address desk_, address[] calldata system) external onlyWiring {
        if (game_.code.length == 0 || desk_.code.length == 0) revert ZeroAddress();
        game = game_;
        desk = desk_;
        isSystem[desk_] = true;
        for (uint256 i; i < system.length; ++i) {
            isSystem[system[i]] = true;
        }
    }

    /// @dev Shapes the game burns pay their backing here; it is forwarded to the game in the same call.
    receive() external payable {}

    /// @notice Sends any ETH this contract holds to the vault (a contribution there). Every ETH flow through here is
    ///         forwarded in the same call (FWA proceeds to the game, redeemed backing to the game), so a balance
    ///         between calls can only be ETH someone else sent, for example a marketplace order's consideration.
    ///         Anyone; never during another call of this contract.
    function flushStray() external nonReentrant returns (uint256 amount) {
        amount = address(this).balance;
        if (amount != 0) SafeTransferLib.forceSafeTransferETH(vault, amount);
    }

    /// @notice Shapes' current mint fee, part of every prize's cost (the game recounts what it owes when it changes).
    function mintFee() external view returns (uint256) {
        return IShapesMinter(shapes).mintFee();
    }

    /// @dev Accepts Shapes and Draw Packs (minted here, or returned by an FWA withdrawal) and collection NFTs only from
    ///      the FWA pool (withdrawals). Anything else sent with a safe transfer is refused so it cannot become
    ///      stranded. A collection NFT sent with a plain `transferFrom` can be registered as a donation through
    ///      `FundingVault.claimStray`.
    function onERC721Received(address operator, address, uint256, bytes calldata) external view returns (bytes4) {
        bool ok = (msg.sender == shapes || msg.sender == packs)
            ? (operator == address(this) || operator == address(pool))
            : (msg.sender == collection && operator == address(pool) && address(pool) != address(0));
        if (!ok) revert Unsolicited();
        return this.onERC721Received.selector;
    }

    // ------------------------------------------------------------------ pool creation

    /// @notice Creates the FWA pool, paying the factory's creation fee from FWA held here. Anyone, once. This
    ///         contract becomes the pool's permanent owner and its purchase operator. Leftover FWA is burned.
    function createPool(bytes32 salt) external nonReentrant returns (address created) {
        if (address(pool) != address(0)) revert PoolExists();
        if (game == address(0)) revert NotGame();
        address fwa = factory.fwaToken();
        uint256 fee = factory.poolCreationFee();
        SafeTransferLib.safeApprove(fwa, address(factory), fee);
        created = factory.createPool(salt, fee, expectedImplementation);
        pool = IFWAPool(created);
        IERC721Min(shapes).setApprovalForAll(created, true);
        IERC721Min(packs).setApprovalForAll(created, true);
        IERC721Min(collection).setApprovalForAll(created, true);
        pool.setPurchaseOperator(address(this));
        maxBatch = _readMaxBatch();
        uint256 left = SafeTransferLib.balanceOf(fwa, address(this));
        if (left != 0) IFWABurnable(fwa).burn(left);
        emit PoolCreated(created, fee);
    }

    /// @dev FWA's per-transaction limit is internal; its quote reverts above it.
    function _readMaxBatch() internal view returns (uint256 n) {
        for (n = MAX_BATCH_FALLBACK; n > 1; --n) {
            try pool.quoteAcquisitionPrice(n) returns (uint256, uint256, uint256) {
                return n;
            } catch {}
        }
    }

    // ------------------------------------------------------------------ registration (vault)

    /// @notice Records a Check the vault delivered here, with its tier read from Checks. `refCost` is what it is
    ///         recorded at (accounting and the sunset's floor); `cashCost` what the protocol paid (0 for a donation).
    function register(uint256 tokenId, uint256 refCost, uint256 cashCost, uint8 source) external {
        if (msg.sender != vault) revert NotVault();
        if (IERC721Min(collection).ownerOf(tokenId) != address(this) || nfts[tokenId].state != NftState.None) {
            revert NotCustody();
        }
        if (refCost == 0 || refCost > type(uint128).max || source > 1) revert OutOfBounds();
        // a reference this small would round the minimum notional to zero and make every exposure term divide by it:
        // lift it (the cash cost stays what was paid; an NFT bought or valued that cheaply is never refused)
        if (refCost < MIN_REF_COST) refCost = MIN_REF_COST;
        uint8 tier = IChecksOriginals(collection).getCheck(tokenId).stored.divisorIndex;
        // a donation arrives at the vault's 80-Check reference; a donated higher tier is recorded at its own price
        if (source == 1 && tier != 0 && _schedule[tier] > refCost && _schedule[tier] <= type(uint128).max) {
            refCost = _schedule[tier];
        }
        nfts[tokenId] = Nft(uint128(refCost), uint128(cashCost), tier, source, NftState.Custody);
        _toCustody(tokenId);
        ++registeredCount;
        emit Registered(tokenId, refCost, cashCost, source);
    }

    // ------------------------------------------------------------------ Shapes and pool controls (game)

    /// @notice An ordinary prize to mint and list: its backing and its FWA price.
    struct Prize {
        uint256 backing;
        uint256 price;
    }

    /// @notice What minting a prize of `backing` costs, with every underlying Shapes mint fee, and whether it is a
    ///         Draw Pack: a Shapes denomination is one Shape; any other multiple of `unit` at or above the Pack
    ///         minimum is a Pack of the fewest Shapes adding up to it exactly (`makeup`). Anything else reverts.
    function prizeCost(uint256 backing) public view returns (uint256 cost, bool isPack) {
        (cost, isPack,) = _prizeCost(backing, _denominations(), IShapesMinter(shapes).mintFee());
    }

    function _prizeCost(uint256 backing, uint256[] memory dens, uint256 fee)
        internal
        view
        returns (uint256 cost, bool isPack, uint32[] memory counts)
    {
        uint256 n;
        (counts, n) = _makeup(backing, dens);
        isPack = n > 1;
        if (isPack && (backing < IDrawPacks(packs).MIN_PACK_VALUE() || n > MAX_PACK_SHAPES)) revert BadPrize();
        cost = backing + n * fee;
    }

    /// @notice The fewest Shapes whose backing adds up to exactly `backing`: a count per Shapes denomination, taken
    ///         largest first (exact for Shapes' 1-5-10 denominations), and their number. Reverts if no exact makeup.
    function makeup(uint256 backing) public view returns (uint32[] memory counts, uint256 n) {
        return _makeup(backing, _denominations());
    }

    /// @dev Shapes' denominations, smallest first. `pure` in Shapes, so one read serves a whole call.
    function _denominations() internal view returns (uint256[] memory dens) {
        IShapesMinter s = IShapesMinter(shapes);
        dens = new uint256[](s.denominationCount());
        for (uint8 i; i < dens.length; ++i) {
            dens[i] = s.denominationAt(i);
        }
    }

    function _makeup(uint256 backing, uint256[] memory dens) internal pure returns (uint32[] memory counts, uint256 n) {
        uint256 len = dens.length;
        counts = new uint32[](len);
        uint256 rem = backing;
        for (uint256 d = len; d != 0; --d) {
            uint256 den = dens[d - 1];
            uint256 c = rem / den;
            counts[d - 1] = uint32(c);
            n += c;
            rem -= c * den;
        }
        if (rem != 0 || n == 0) revert BadPrize();
    }

    /// @notice Mints `prizes` into custody and lists them at their prices. `msg.value` must be exactly their total
    ///         cost (`prizeCost`). Returns the FWA listing ids and the token ids.
    function mintAndList(Prize[] calldata prizes)
        external
        payable
        onlyGame
        nonReentrant
        returns (uint256[] memory ids, uint256[] memory tokenIds)
    {
        IFWAPool.ListingInput[] memory inputs = new IFWAPool.ListingInput[](prizes.length);
        tokenIds = new uint256[](prizes.length);
        uint256 spent;
        uint256[] memory dens = _denominations();
        uint256 fee = IShapesMinter(shapes).mintFee();
        for (uint256 i; i < prizes.length; ++i) {
            (address c, uint256 id, uint256 cost) = _mintPrize(prizes[i].backing, dens, fee);
            spent += cost;
            tokenIds[i] = id;
            inputs[i] = IFWAPool.ListingInput(c, id, prizes[i].price);
        }
        if (spent != msg.value) revert BadPrize();
        ids = pool.listNFTs(inputs);
        listedTotal += ids.length;
    }

    /// @dev Mints one prize into this contract: a Shape, or a Draw Pack of its `makeup`.
    function _mintPrize(uint256 backing, uint256[] memory dens, uint256 fee)
        internal
        returns (address c, uint256 id, uint256 cost)
    {
        bool isPack;
        uint32[] memory counts;
        (cost, isPack, counts) = _prizeCost(backing, dens, fee);
        if (isPack) {
            id = IDrawPacks(packs).createPackTo{value: cost}(new uint256[](0), counts, address(this));
            c = packs;
            uint256 slot = _PACKS_MINTED_SLOT;
            assembly ("memory-safe") {
                tstore(slot, 1)
            }
        } else {
            id = IShapesMinter(shapes).mintTo{value: cost}(backing, address(this));
            c = shapes;
        }
    }

    /// @notice Withdraws prize listings (Shapes or Packs), cashes them out and sends their backing to the game.
    function withdrawShapes(uint256[] calldata ids) external onlyGame nonReentrant returns (uint256 eth) {
        address[] memory cs = new address[](ids.length);
        uint256[] memory tokenIds = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            (cs[i], tokenIds[i]) = _prizeOf(ids[i]);
        }
        pool.withdrawListingsTo(ids, address(this));
        withdrawnTotal += ids.length;
        eth = _cashOut(cs, tokenIds);
    }

    /// @notice Recovers a prize whose delivery the player refunded, cashes it out and sends its backing to the game.
    function recoverShape(uint256 listingId) external onlyGame nonReentrant returns (uint256 eth) {
        address[] memory cs = new address[](1);
        uint256[] memory tokenIds = new uint256[](1);
        (cs[0], tokenIds[0]) = _prizeOf(listingId);
        pool.recoverRefundedNFT(listingId);
        eth = _cashOut(cs, tokenIds);
    }

    function _prizeOf(uint256 listingId) internal view returns (address c, uint256 tokenId) {
        (c,,, tokenId,,,,) = pool.listings(listingId);
        if (c != shapes && c != packs) revert WrongCollection();
    }

    /// @dev Burns Shapes and redeems Packs held here (Shapes pays their backing to this contract either way), then
    ///      forwards the ETH to the game.
    function _cashOut(address[] memory cs, uint256[] memory tokenIds) internal returns (uint256 eth) {
        uint256 before = address(this).balance;
        for (uint256 i; i < tokenIds.length; ++i) {
            if (cs[i] == packs) IDrawPacks(packs).redeem(tokenIds[i]);
            else IShapesMinter(shapes).burn(tokenIds[i]);
        }
        eth = address(this).balance - before;
        if (eth != 0) SafeTransferLib.forceSafeTransferETH(game, eth);
    }

    function setAcquisitions(bool enabled) external onlyGame {
        pool.setBool(FWA_ACQUISITIONS_ENABLED, enabled);
    }

    /// @notice Withdraws FWA owner proceeds and forwards them to the game.
    function collectProceeds() external onlyGame nonReentrant returns (uint256 amount) {
        if (pool.ownerProceeds() == 0) return 0;
        amount = pool.withdrawOwnerProceeds();
        SafeTransferLib.forceSafeTransferETH(game, amount);
    }

    function retirePool() external onlyGame {
        if (!pool.retired()) pool.retirePool();
    }

    // ------------------------------------------------------------------ Check listings

    /// @notice Maintenance of the Check listings (the game, at its maintenance windows): while no FWA request is
    ///         unsettled, lists up to `LIST_BATCH` Checks from custody and reprices up to `DECAY_BATCH` listed Checks
    ///         whose notional has moved a step (or reached its floor), each within the target. Records `rowsShort` (a
    ///         new or larger shortage counts as work). Returns units of work. `turnover` is unused: survival, not
    ///         turnover, drives Check decay (the game's interface is kept).
    function processCollection(uint256) external onlyGame nonReentrant returns (uint256 work) {
        if (pool.retired() || factory.globalWithdrawOnly() || pool.unsettledAcquisitionCount() != 0) return 0;
        ListingParams memory p = _lp;
        Pass memory s = Pass({n: pool.activeListingCount(), sum: exposureSum, wanted: 0, extra: 0, work: 0});
        _listBatch(p, s);
        _decayBatch(p, s);
        exposureSum = s.sum;
        // listings needed so that (sum + wanted) / (listings - headroom) <= target
        uint256 need = s.wanted == 0 ? 0 : (s.sum + s.wanted) * BPS / (p.targetBps * WAD) + 1 + gateHeadroom();
        uint256 short = need > s.n + s.extra ? need - s.n - s.extra : 0;
        // a newly found (or larger) shortage is work: it must be recorded for the game's growth and the vault's
        // reserve even when nothing else changed
        if (short > rowsShort) ++s.work;
        rowsShort = short;
        return s.work;
    }

    /// @dev State of one `processCollection` pass: active listings, exposure total, exposure the deferred listings
    ///      and decay steps would add, the listings those deferred listings would add themselves, and work done.
    struct Pass {
        uint256 n;
        uint256 sum;
        uint256 wanted;
        uint256 extra;
        uint256 work;
    }

    /// @dev Lists up to `LIST_BATCH` Checks (`LIST_BATCH_AFTER_PACKS` if this transaction minted Packs) from the end of
    ///      custody, in one FWA batch, stopping at the first that does not fit the target (it and the rest wait).
    ///      A Check whose tier has no schedule price stays in custody. The Pack flag is per transaction on purpose:
    ///      the gas cap it keeps under (EIP-7825) is the transaction's.
    function _listBatch(ListingParams memory p, Pass memory s) internal {
        uint256 packsMinted;
        uint256 slot = _PACKS_MINTED_SLOT;
        assembly ("memory-safe") {
            packsMinted := tload(slot)
        }
        uint256 max = packsMinted == 0 ? LIST_BATCH : LIST_BATCH_AFTER_PACKS;
        uint256 len = _custody.length;
        IFWAPool.ListingInput[] memory inputs = new IFWAPool.ListingInput[](max);
        uint256 listed;
        for (uint256 i; i < len && listed + s.extra < max; ++i) {
            uint256 tokenId = _custody[len - 1 - i];
            uint256 sched = _schedule[nfts[tokenId].tier];
            if (sched == 0) continue; // not listed at this tier
            uint256 term = WAD; // a new listing opens at its schedule price
            if (s.wanted != 0 || !_fits(s.sum + term, s.n + listed + 1, p.targetBps)) {
                s.wanted += term;
                ++s.extra;
                continue;
            }
            s.sum += term;
            inputs[listed++] = IFWAPool.ListingInput(collection, tokenId, sched);
        }
        if (listed == 0) return;
        assembly ("memory-safe") {
            mstore(inputs, listed)
        }
        uint256 entry = allocated(); // before this batch: listing does not change it
        uint256[] memory ids = pool.listNFTs(inputs);
        listedTotal += listed;
        for (uint256 i; i < listed; ++i) {
            _recordListing(ids[i], inputs[i].tokenId, inputs[i].price, entry, p);
        }
        s.n += listed;
        s.work += listed;
    }

    /// @dev Examines up to `DECAY_BATCH` listed Checks from the cursor and reprices those whose notional has moved at
    ///      least a step (or reached its floor), within the target; stops at the first the target holds back.
    function _decayBatch(ListingParams memory p, Pass memory s) internal {
        uint256 len = _listed.length;
        uint256 cursor = decayCursor;
        for (uint256 j; j < DECAY_BATCH && j < len; ++j) {
            if (cursor >= len) cursor = 0;
            if (!_reprice(_listed[cursor++], p, s)) {
                // the target binds: stop here and start the next pass at this Check, so the shortage stays recorded
                // (`rowsShort`) until the board has grown for it
                --cursor;
                break;
            }
        }
        decayCursor = cursor;
    }

    /// @dev Reprices listing `id` if its notional has moved a step (or reached its floor). False when the target holds
    ///      it back (its extra exposure is added to `s.wanted`).
    function _reprice(uint256 id, ListingParams memory p, Pass memory s) internal returns (bool) {
        CListing storage l = cListings[id];
        if (!l.open) return true;
        uint256 current = l.notional;
        (uint256 target, uint256 sched, uint256 floor) = _notional(l, p);
        if (target == current || sched == 0) return true;
        uint256 diff = current > target ? current - target : target - current;
        if (diff < current * p.stepBps / BPS && target != floor) return true;
        if (_status(id) != IFWAPool.ListingStatus.Active) return true;
        uint256 term = sched * WAD / target;
        uint256 old = l.term;
        if (term > old && !_fits(s.sum + term - old, s.n, p.targetBps)) {
            s.wanted += term - old;
            return false;
        }
        pool.updatePrice(id, target);
        l.notional = uint128(target);
        l.term = uint128(term);
        s.sum = s.sum + term - old;
        ++s.work;
        emit Decayed(id, current, target);
        return true;
    }

    /// @notice The notional listing `id` would be repriced to now.
    function notionalOf(uint256 id) public view returns (uint256 target) {
        (target,,) = _notional(cListings[id], _lp);
    }

    /// @dev Schedule price less `decayBps` of it per survived draw and `dailyDecayBps` of it per day in the draw, at
    ///      least `floorBps` of it. With no schedule price the published notional stands.
    function _notional(CListing memory l, ListingParams memory p)
        internal
        view
        returns (uint256 target, uint256 sched, uint256 floor)
    {
        sched = _schedule[nfts[l.tokenId].tier];
        if (sched == 0) return (l.notional, 0, 0);
        floor = sched * p.floorBps / BPS;
        uint256 survivedDraws = l.open ? allocated() - l.entry : 0;
        uint256 drop = sched * p.decayBps * survivedDraws / BPS
            + sched * (_clockNow(p.dailyDecayBps) - l.clockStart) / (BPS * WAD);
        target = sched > floor + drop ? sched - drop : floor;
    }

    /// @notice Records the outcome of a Check listing from FWA's state: Settled (won, delivered), returned to custody
    ///         (the winner took a refund), or out of the draw (delivery pending). The game calls it for every request
    ///         it books that drew a Check listing; anyone may, it only follows FWA. Returns whether `listingId` is a
    ///         Check listing.
    function settleListing(uint256 listingId) external nonReentrant returns (bool) {
        if (!isCollectionListing[listingId]) return false;
        uint256 idx = _listedIndex[listingId];
        if (idx == 0) return true; // already closed for good
        CListing storage l = cListings[listingId];
        IFWAPool.ListingStatus st = _status(listingId);
        if (st == IFWAPool.ListingStatus.Settled) {
            Nft storage n = nfts[l.tokenId];
            n.state = NftState.Won;
            ++wonCount;
            wonRefCost += n.refCost;
            wonCashCost[n.source] += n.cashCost;
            emit CollectionWon(listingId, l.tokenId, n.refCost, n.cashCost);
            _close(listingId);
        } else if (st == IFWAPool.ListingStatus.DeliveryRefunded) {
            // the winner refused delivery: the Check returns with a new episode (it was selected, D002)
            pool.recoverRefundedNFT(listingId);
            _toCustody(l.tokenId);
            emit CollectionReturned(listingId, l.tokenId);
            _close(listingId);
        } else if (st == IFWAPool.ListingStatus.DeliveryPending) {
            _markClosed(listingId);
        }
        return true;
    }

    function _recordListing(uint256 id, uint256 tokenId, uint256 notional, uint256 entry, ListingParams memory p)
        internal
    {
        _removeCustody(tokenId);
        nfts[tokenId].state = NftState.Listed;
        isCollectionListing[id] = true;
        cListings[id] = CListing({
            tokenId: tokenId,
            notional: uint128(notional),
            term: uint128(WAD),
            entry: uint64(entry),
            open: true,
            clockStart: uint128(_clockNow(p.dailyDecayBps))
        });
        ++openCollection;
        _listed.push(id);
        _listedIndex[id] = _listed.length;
        emit CollectionListed(id, tokenId, notional);
    }

    /// @dev Removes `id` from the listed set (won, returned, withdrawn).
    function _close(uint256 id) internal {
        _markClosed(id);
        uint256 i = _listedIndex[id] - 1;
        uint256 last = _listed[_listed.length - 1];
        _listed[i] = last;
        _listedIndex[last] = i + 1;
        _listed.pop();
        delete _listedIndex[id];
    }

    /// @dev True when an exposure total of `sum` over `n` active listings, less the gate's headroom, is within
    ///      `targetBps`: listing and decay leave room for every request the gate can admit.
    function _fits(uint256 sum, uint256 n, uint256 targetBps) internal view returns (bool) {
        uint256 h = gateHeadroom();
        return n > h && sum * BPS <= targetBps * (n - h) * WAD;
    }

    function _markClosed(uint256 id) internal {
        CListing storage l = cListings[id];
        if (!l.open) return;
        l.open = false;
        exposureSum -= l.term;
        --openCollection;
    }

    function _toCustody(uint256 tokenId) internal {
        nfts[tokenId].state = NftState.Custody;
        _custody.push(tokenId);
        _custodyIndex[tokenId] = _custody.length;
    }

    function _removeCustody(uint256 tokenId) internal {
        uint256 i = _custodyIndex[tokenId] - 1;
        uint256 last = _custody[_custody.length - 1];
        _custody[i] = last;
        _custodyIndex[last] = i + 1;
        _custody.pop();
        delete _custodyIndex[tokenId];
    }

    /// @notice Listings the requests the gate can let in might remove before this contract acts again: up to
    ///         `maxInFlight - 1` already unsettled plus one full batch.
    function gateHeadroom() public view returns (uint256) {
        return maxInFlight - 1 + (maxBatch == 0 ? MAX_BATCH_FALLBACK : maxBatch);
    }

    // ------------------------------------------------------------------ survival (C010)

    /// @notice Draws that allocated a prize in this pool since it opened: FWA removes exactly one active listing per
    ///         allocation, and every listing and withdrawal goes through this contract.
    function allocated() public view returns (uint256) {
        if (address(pool) == address(0)) return 0;
        return listedTotal - withdrawnTotal - pool.activeListingCount();
    }

    /// @notice Draws listing `id` has survived in its current episode (0 once it is out of the draw).
    function survived(uint256 id) public view returns (uint256) {
        CListing memory l = cListings[id];
        if (!l.open || _status(id) != IFWAPool.ListingStatus.Active) return 0;
        return allocated() - l.entry;
    }

    // ------------------------------------------------------------------ the desk

    /// @dev Withdraws open, active Check listings here with no request unsettled (FWA's rule for withdrawals, and so
    ///      no draw in flight can still select them). Returns their token ids, removed from the listed set.
    function _take(uint256[] memory ids) internal returns (uint256[] memory tokenIds) {
        if (pool.unsettledAcquisitionCount() != 0) revert Busy();
        tokenIds = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            CListing storage l = cListings[id];
            if (!l.open || _status(id) != IFWAPool.ListingStatus.Active) revert NotListed();
            tokenIds[i] = l.tokenId;
            _close(id);
        }
        // FWA withdraws at most 20 listings per call (MAX_INVENTORY_BATCH); 64 singles take four calls
        uint256 n = ids.length;
        for (uint256 i; i < n; i += 20) {
            uint256 k = n - i < 20 ? n - i : 20;
            uint256[] memory batch = new uint256[](k);
            for (uint256 j; j < k; ++j) {
                batch[j] = ids[i + j];
            }
            pool.withdrawListingsTo(batch, address(this));
        }
        withdrawnTotal += n;
    }

    /// @notice Canonical composition of two listed Checks: `keep` survives at the next tier (with `swap`, carrying the
    ///         burned Check's art) and returns to custody for a new episode; `burn` is burned by Checks. The desk only.
    function deskCompose(uint256 keepListing, uint256 burnListing, bool swap)
        external
        onlyDesk
        nonReentrant
        returns (uint256 keep, uint256 burned)
    {
        uint256[] memory ids = new uint256[](2);
        ids[0] = keepListing;
        ids[1] = burnListing;
        uint256[] memory t = _take(ids);
        (keep, burned) = (t[0], t[1]);
        IChecksOriginals(collection).composite(keep, burned, swap); // same tier <= 5, distinct, owned here
        nfts[burned].state = NftState.Burned;
        ++burnedCount;
        uint8 tier = nfts[keep].tier + 1;
        nfts[keep].tier = tier;
        _toCustody(keep);
        emit Composed(keep, burned, tier);
    }

    /// @notice Forms a Black Check from 64 listed singles: the first survives as the Black Check and returns to
    ///         custody, the other 63 are burned by Checks. The desk only.
    function deskFormBlack(uint256[] calldata listingIds) external onlyDesk nonReentrant returns (uint256 black) {
        uint256[] memory t = _take(listingIds);
        IChecksOriginals(collection).infinity(t); // exactly 64 singles owned here
        for (uint256 i = 1; i < t.length; ++i) {
            nfts[t[i]].state = NftState.Burned;
        }
        burnedCount += t.length - 1;
        black = t[0];
        nfts[black].tier = BLACK;
        _toCustody(black);
        emit BlackFormed(black);
    }

    /// @notice Releases one listed Check to `to`, who has paid the desk for it. The desk only.
    function deskRelease(uint256 listingId, address to) external onlyDesk nonReentrant returns (uint256 tokenId) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = listingId;
        tokenId = _take(ids)[0];
        nfts[tokenId].state = NftState.Sold;
        ++soldCount;
        IERC721Min(collection).transferFrom(address(this), to, tokenId);
        emit Released(tokenId, to);
    }

    // ------------------------------------------------------------------ views

    function _status(uint256 id) internal view returns (IFWAPool.ListingStatus st) {
        (,,,,,,, st) = pool.listings(id);
    }

    function listingParams() external view returns (ListingParams memory) {
        return _lp;
    }

    function schedule() external view returns (uint256[8] memory) {
        return _schedule;
    }

    function scheduleOf(uint8 tier) external view returns (uint256) {
        return _schedule[tier];
    }

    function tierOf(uint256 tokenId) external view returns (uint8) {
        return nfts[tokenId].tier;
    }

    /// @notice The lowest notional an 80-Check can reach (its schedule price at the decay floor): the vault's floor for
    ///         its funding reference, as collection-games' absolute Ape floor was (D83).
    function minNotionalWei() external view returns (uint256 m) {
        m = _schedule[0] * _lp.floorBps / BPS;
        if (m < MIN_REF_COST) m = MIN_REF_COST;
    }

    /// @notice The decay clock now: time decay credited to each Check in the draw since launch, bps of its schedule
    ///         price scaled by WAD.
    function decayClock() external view returns (uint256) {
        return _clockNow(_lp.dailyDecayBps);
    }

    function _clockNow(uint256 dailyDecayBps) internal view returns (uint256) {
        return _clock + dailyDecayBps * (block.timestamp - _clockAt) * WAD / 1 days;
    }

    /// @notice Expected cost of Check prizes as bps of FWA's base expected purchase amount, at the pool's current
    ///         active listing count.
    function exposureBps() public view returns (uint256) {
        if (address(pool) == address(0)) return 0;
        uint256 n = pool.activeListingCount();
        return n == 0 ? 0 : exposureSum * BPS / (n * WAD);
    }

    /// @notice True when at least one Check is in the draw.
    function collectionAvailable() public view returns (bool) {
        return openCollection != 0;
    }

    /// @notice FWA purchase operator: live checks only, so purchases stop on their own before the pool becomes unsafe,
    ///         whether or not any keeper is running. Admits a purchase when all hold:
    ///         - fewer than `maxInFlight` requests are unsettled (this purchase may itself be a batch of `maxBatch`);
    ///         - FWA's edge is within the game's `maxEdgeBps` (booking relies on it, CollectionGame `_bookCapture`);
    ///         - after every unsettled request plus a full batch had each removed a Shape, at least the game's
    ///           `minShapes` would remain and Check exposure would stay within `MAX_EXPOSURE_BPS` (listing and
    ///           decay keep it within the lower target, so neither the council's target nor its own changes close it);
    ///         `exposureSum` and `openCollection` only overstate while records are stale, so the checks stay
    ///         conservative. Fits FWA's 100,000 gas stipend; fails closed. A refused purchase reverts in FWA before any
    ///         fee is paid.
    ///         No system address may be the purchaser: the FWA pool, this contract, the game, the vault, the migration
    ///         authority, Checks, Shapes, Packs or any `isSystem` address (Checks Editions and the desk among them): a
    ///         prize sent to any of them is lost to every route.
    function canPurchase(address purchaser) external view returns (bool) {
        IFWAPool p = pool;
        if (address(p) == address(0)) return false;
        if (
            purchaser == address(p) || purchaser == address(this) || purchaser == game || purchaser == vault
                || purchaser == migrator || purchaser == collection || purchaser == shapes || purchaser == packs
                || isSystem[purchaser]
        ) return false;
        uint256 u = p.unsettledAcquisitionCount();
        if (u >= maxInFlight) return false;
        (uint256 minShapes, uint256 maxEdge) = IGameGate(game).gateParams();
        if (factory.edgeBps() > maxEdge) return false;
        uint256 n = p.activeListingCount();
        uint256 worst = u + maxBatch;
        if (n < worst + openCollection + minShapes) return false;
        return exposureSum * BPS <= MAX_EXPOSURE_BPS * (n - worst) * WAD;
    }

    function heldCount() external view returns (uint256) {
        return _custody.length + _listed.length;
    }

    function custodyCount() external view returns (uint256) {
        return _custody.length;
    }

    function custodyAt(uint256 i) external view returns (uint256) {
        return _custody[i];
    }

    function listedCount() external view returns (uint256) {
        return _listed.length;
    }

    function listedAt(uint256 i) external view returns (uint256) {
        return _listed[i];
    }

    // ------------------------------------------------------------------ retirement

    /// @notice During retirement, after the pool is retired and settled, withdraws Check listings still in the
    ///         draw back into custody, up to FWA's batch of 20 per call. Returns the listings not examined yet (0 once
    ///         every withdrawable one is back).
    function withdrawCollection() external onlyGame nonReentrant returns (uint256 left) {
        uint256[] memory ids = new uint256[](20);
        uint256 n;
        uint256 i = _listed.length;
        // from the end: closing a listing moves the last (already examined) one into its place
        while (i != 0 && n < 20) {
            uint256 id = _listed[--i];
            IFWAPool.ListingStatus st = _status(id);
            if (st != IFWAPool.ListingStatus.Active && st != IFWAPool.ListingStatus.Staged) continue;
            ids[n++] = id;
            _toCustody(cListings[id].tokenId);
            _close(id);
        }
        left = i;
        if (n == 0) return left;
        assembly ("memory-safe") {
            mstore(ids, n)
        }
        pool.withdrawListingsTo(ids, address(this));
        withdrawnTotal += n;
    }

    // ------------------------------------------------------------------ migration (MigrationAuthority only)

    /// @notice Moves one custody Check to the successor (`to`) once the game has retired: settled, every listing
    ///         withdrawn (a delivery refunded later returns to custody through `settleListing`). The Check's record
    ///         (`nfts`) stays readable (the sunset reads it for the auction).
    function migrateApe(address to) external nonReentrant returns (bool found, uint256 tokenId) {
        if (msg.sender != migrator) revert NotMigrator();
        if (!ICollectionGame(game).retired()) revert NotRetired();
        uint256 n = _custody.length;
        if (n == 0) return (false, 0);
        tokenId = _custody[n - 1];
        _removeCustody(tokenId);
        Nft storage r = nfts[tokenId];
        r.state = NftState.Migrated;
        ++migratedCount;
        IERC721Min(collection).transferFrom(address(this), to, tokenId);
        emit ApeMigrated(tokenId, to, r.refCost, r.cashCost, r.source);
        return (true, tokenId);
    }

    // ------------------------------------------------------------------ governance

    /// @notice How Checks decay and fit the board. Council only (D012): these set what each Check is worth in the
    ///         draw. Applies to every listing at its next reprice. Lowering the target defers listing and decay until
    ///         the board grows; it never closes the purchase gate (its ceiling is `MAX_EXPOSURE_BPS`).
    function setListingParams(ListingParams calldata p) external onlyCouncil {
        _setListingParams(p);
    }

    /// @notice The price of each tier (council only, D003, D012). Zero keeps a tier out of the draw. Applies at each
    ///         listing's next reprice, up or down, keeping its earned decay.
    function setSchedule(uint256[8] calldata prices) external onlyCouncil {
        _setSchedule(prices);
    }

    /// @notice The in-flight purchase bound, 1 to 50. With batches, up to `maxInFlight - 1 + maxBatch`
    ///         requests can be unsettled at once.
    function setMaxInFlight(uint256 n) external onlyOwner {
        _setMaxInFlight(n);
    }

    function _setMaxInFlight(uint256 n) internal {
        if (n == 0 || n > 50) revert OutOfBounds();
        maxInFlight = n;
        emit MaxInFlightSet(n);
    }

    function _setSchedule(uint256[8] memory prices) internal {
        for (uint256 t; t < TIERS; ++t) {
            uint256 v = prices[t];
            if (v != 0 && (v < MIN_SCHEDULE || v > MAX_SCHEDULE)) revert OutOfBounds();
        }
        _schedule = prices;
        emit ScheduleSet(prices);
    }

    function _setListingParams(ListingParams memory p) internal {
        if (
            p.floorBps == 0 || p.floorBps > BPS || p.decayBps > BPS || p.stepBps > BPS || p.targetBps == 0
                || p.targetBps > MAX_EXPOSURE_BPS || p.dailyDecayBps > BPS
        ) revert OutOfBounds();
        _clock = _clockNow(_lp.dailyDecayBps); // the old rate runs until now
        _clockAt = block.timestamp;
        _lp = p;
        emit ListingParamsSet(p);
    }
}
