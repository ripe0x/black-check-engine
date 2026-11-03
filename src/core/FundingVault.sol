// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Governed} from "./Governed.sol";
import {
    ICollectionGame,
    ICollectionPoolOwner,
    IAcquisitionAdapter,
    IFundingVault
} from "../interfaces/ICollectionGames.sol";

interface IERC721Owner {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @title FundingVault
/// @notice Holds the game's capital before it reaches the game: every trading fee (the hook pays it here through the
///         PoolManager), ETH contributions, and the game's surplus while the vault is short of one Ape (`shortfall`).
///         It buys collection NFTs (from a holder who sells directly at the standing bid, or through the marketplace
///         adapter fixed at deployment) and capitalises the game. There is no withdraw. Contributions are irrevocable and
///         confer nothing.
/// @dev The live bid (docs/SPEC.md "The bid"), Permanent Collection's funding-driven model adapted to this
///      vault's accounting: one public ETH bid, `bidBalance`, made of real ETH metered into it from what the vault
///      may spend on NFTs (`acquisitionBudget`: everything it holds after the game's protected capital and the board
///      growth its NFTs are waiting for).
///      - `sweep` (anyone; rewarded 0.5% of what it forwards, at most 0.01 ETH, from the vault's general bucket):
///        while the bid is below `activationThreshold`, available ETH enters at once, clamped to land the bid at the
///        threshold, with no cooldown; at or above it, at most `maxSweepWei` per `minBlocksBetweenSweeps` blocks.
///        No time-based rise: the bid grows only by ETH actually forwarded;
///      - an acquisition subtracts the price actually paid from the bid (unspent bid ETH stays) and moves the funding
///        reference (`referencePrice`) to that price, but never below the Ape floor (`poolOwner.minNotionalWei`) nor
///        more than `maxDropBps` below the previous reference (D83: one cheap or mistaken sale cannot collapse the bid);
///        the threshold becomes `thresholdBps` of the reference; no oracle;
///      - a holder accepting the bid names its price, at most the bid (`sellToProtocol`); a marketplace fill
///        (`fillOrder`) pays the listing's actual price plus a finder fee (0.5% of the bid, at most 0.01 ETH);
///      - the game's capital comes first: the bid never exceeds the acquisition budget (`liveBid`), and a sweep
///        clamps `bidBalance` to it;
///      - a ceiling relative to the funding reference: above `ceilingBps` of `referencePrice` a sweep
///        forwards only `slowSweepWei` per cooldown, so a bid nobody accepts climbs slowly instead of
///        piling up, yet still reaches any floor in time (`slowSweepWei` 0: a hard ceiling until the next acquisition; `ceilingBps` 0:
///        no ceiling). It moves with every acquisition; no oracle;
///      - `maxPrice`, if set, caps every acquisition and the bid (0 at launch: an optional emergency brake). The
///        threshold share, the sweep sizes, the ceiling and the cooldown are the owner's; `setActivationThreshold`
///        corrects the threshold until the next acquisition re-syncs it.
///      - fee overflow: trading fees are counted as they arrive (`unsplitFees`: one more storage
///        write in the swap path) and split at the next sweep. Only ETH the bid cannot use goes: once the game is
///        active and while the bid is full, `overflowBps` of them go to the CollectionBurner, never more than the vault holds beyond the game's
///        needs, the board growth, the bid and one more Ape at the funding reference; otherwise they stay as
///        capital. The bid is rate-limited, so without it fees that outrun Ape purchases would sit idle; with it the
///        next Ape is always funded and acquisitions are never slowed.
///      Outflows: `sellToProtocol` (the seller, after the NFT is in custody), `fillOrder` (the adapter, at most the
///      bid, NFT in custody and unspent ETH back in the same call), `fundGame` (what the game reports it needs), the
///      fee overflow (the burner only) and `migrateCapital` (everything to the successor once the game has retired: a
///      migration, or the sunset, which burns it; MigrationAuthority only). One balance; the game's capital comes
///      first.
contract FundingVault is IFundingVault, ReentrancyGuard, Governed {
    uint8 internal constant SOURCE_BOUGHT = 0;
    uint8 internal constant SOURCE_DONATION = 1;
    uint256 internal constant BPS = 10_000;

    address public immutable poolManager;
    address public immutable collection;
    address public immutable burner;
    /// @notice The MigrationAuthority, the only caller of `migrateCapital`.
    address public immutable migrator;

    ICollectionGame public game;
    ICollectionPoolOwner public poolOwner;
    /// @notice The one marketplace adapter (Seaport), fixed at wiring (address(0): none).
    address public adapter;
    /// @notice Token IDs the vault refuses (e.g. known stolen).
    mapping(uint256 tokenId => bool) public excluded;

    /// @notice Marketplace finder fee: 0.5% of the bid, at most 0.01 ETH (as in Permanent Collection). The cap also
    ///         bounds the sweep reward (gas plus flat fee, D82).
    uint256 public constant REWARD_BPS = 50;
    uint256 public constant REWARD_CAP = 0.01 ether;

    /// @notice The live bid's parameters (owner, any time).
    struct BidParams {
        uint256 thresholdBps; // after an acquisition the activation threshold is this share of the funding reference
        uint256 maxSweepWei; // above the threshold, the most one sweep forwards into the bid
        uint256 minBlocksBetweenSweeps; // above the threshold, blocks between two sweeps
        uint256 maxPrice; // optional emergency cap on any acquisition and on the bid (0: none)
        uint256 ceilingBps; // above this share of the funding reference, sweeps forward `slowSweepWei` (0: none)
        uint256 slowSweepWei; // above the ceiling, the most one sweep forwards into the bid (0: none)
        uint256 maxDropBps; // the most one acquisition may lower the funding reference, bps of it (100-10,000)
    }

    BidParams internal _bid;
    /// @notice Share of the fees received since the last sweep that goes to the burner when the vault holds more than
    ///         the bid can use (owner, any time, 0-100%).
    uint256 public overflowBps;
    /// @notice Trading fees received since the last sweep, not yet split.
    uint256 public unsplitFees;
    /// @dev ETH the adapter returned during the current `fillOrder`.
    uint256 transient _adapterReturned;
    /// @notice Trading fees sent to the burner by the overflow.
    uint256 public overflowOut;
    /// @notice ETH metered into the live bid (accounted inside this vault).
    uint256 public bidBalance;
    /// @notice Below this the bid fills at once; above it sweeps are metered.
    uint256 public activationThreshold;
    /// @notice The latest clearing price, exactly as paid (the deploy-time reference before the first acquisition).
    uint256 public lastPrice;
    /// @notice The funding reference: what one more Ape is taken to cost. It sets the bid's threshold and ceiling, the
    ///         surplus target (`shortfall`), the overflow's reserve for the next Ape and a donated NFT's reference
    ///         value. An acquisition moves it to its price, but never below the Ape floor nor more than `maxDropBps`
    ///         below the previous reference (D83).
    uint256 public referencePrice;
    uint256 public lastSweepBlock;
    uint256 public sweepRewards;
    uint256 public finderFees;

    // inflows
    uint256 public tradingFees;
    uint256 public contributions;
    uint256 public surplusIn;
    uint256 public returnedFromGame;
    uint256 public nftContributions;
    // outflows
    uint256 public acquisitionSpend;
    uint256 public acquisitionCount;
    uint256 public gameCapitalSent;
    uint256 public migratedOut;

    event TradingFee(uint256 amount);
    event Contributed(address indexed from, uint256 amount);
    event NftContributed(address indexed from, uint256 indexed tokenId, uint256 refCost);
    event SurplusReceived(uint256 amount);
    event Acquired(uint256 indexed tokenId, address indexed seller, address adapter, uint256 price);
    event GameFunded(uint256 amount);
    event Returned(uint256 amount);
    event BidParamsSet(BidParams p);
    event ThresholdSet(uint256 threshold);
    event Swept(address indexed keeper, uint256 forwarded, uint256 reward, uint256 bidBalance);
    event OverflowBpsSet(uint256 bps);
    event Overflow(uint256 amount);
    event Excluded(uint256 indexed tokenId, bool excluded);
    event CapitalMigrated(address indexed successor, uint256 amount);

    error NotGame();
    error NotAllowed();
    error AboveBid(uint256 bid);
    error SweepTooEarly(uint256 nextBlock);
    error OverBudget();
    error NotDelivered();
    error AdapterKeptFunds();
    error NotEligible();
    error NothingToSend();
    error NotMigrator();

    constructor(
        address admin_,
        address poolManager_,
        address collection_,
        address burner_,
        address migrator_,
        BidParams memory bid_,
        uint256 overflowBps_,
        uint256 refPrice_,
        uint256 firstThresholdBps_
    ) Governed(admin_, true) {
        if (poolManager_ == address(0) || collection_ == address(0) || burner_ == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        collection = collection_;
        burner = burner_;
        migrator = migrator_;
        _setBidParams(bid_);
        _setOverflowBps(overflowBps_);
        if (refPrice_ == 0 || firstThresholdBps_ > BPS) revert OutOfBounds();
        lastPrice = refPrice_;
        referencePrice = refPrice_;
        // the first threshold has its own share of the reference (`firstThresholdBps`), so the opening fees can buy
        // the first NFT at once; after each acquisition it is `thresholdBps` of the price paid
        _setThreshold(refPrice_ * firstThresholdBps_ / BPS);
    }

    /// @notice One-shot wiring by the deployer: the game, the pool owner (custody) and the marketplace adapter
    ///         (address(0): none). None can change.
    function wire(address game_, address poolOwner_, address adapter_) external onlyWiring {
        if (game_.code.length == 0 || poolOwner_.code.length == 0) revert ZeroAddress();
        if (adapter_ != address(0) && adapter_.code.length == 0) revert ZeroAddress();
        game = ICollectionGame(game_);
        poolOwner = ICollectionPoolOwner(poolOwner_);
        adapter = adapter_;
    }

    // ------------------------------------------------------------------ inflows

    /// @notice Trading fees arrive from the PoolManager in the middle of swaps; anything else is a contribution.
    receive() external payable {
        if (msg.sender == poolManager) {
            tradingFees += msg.value;
            unsplitFees += msg.value;
            emit TradingFee(msg.value);
        } else if (msg.sender == adapter && msg.sender != address(0)) {
            // Unspent ETH an adapter returns inside `fillOrder`: the vault's own funds coming back.
            _adapterReturned += msg.value;
        } else {
            contributions += msg.value;
            emit Contributed(msg.sender, msg.value);
        }
    }

    /// @notice An irrevocable ETH contribution. It confers no tokens, rights, repayment or authority.
    function contribute() external payable {
        contributions += msg.value;
        emit Contributed(msg.sender, msg.value);
    }

    /// @notice An irrevocable contribution of an eligible collection NFT (approve this vault first). Its reference
    ///         value for odds and exposure is the bid's reference price, never a value the donor chooses.
    function contributeNFT(uint256 tokenId) external nonReentrant {
        if (excluded[tokenId]) revert NotEligible();
        IERC721Owner(collection).transferFrom(msg.sender, address(poolOwner), tokenId);
        _registerDonation(tokenId, msg.sender);
    }

    /// @notice Registers, as a donation, a collection NFT that reached the pool owner by a plain transfer. Anyone.
    function claimStray(uint256 tokenId) external nonReentrant {
        if (excluded[tokenId]) revert NotEligible();
        _registerDonation(tokenId, address(0));
    }

    function _registerDonation(uint256 tokenId, address from) internal {
        uint256 ref = referencePrice;
        poolOwner.register(tokenId, ref, 0, SOURCE_DONATION);
        ++nftContributions;
        emit NftContributed(from, tokenId, ref);
    }

    /// @notice The game's surplus while the vault is short of one Ape (`shortfall`).
    function receiveSurplus() external payable {
        if (msg.sender != address(game)) revert NotGame();
        surplusIn += msg.value;
        emit SurplusReceived(msg.value);
    }

    /// @notice Capital a retiring game returns.
    function receiveReturn() external payable {
        if (msg.sender != address(game)) revert NotGame();
        returnedFromGame += msg.value;
        emit Returned(msg.value);
    }

    // ------------------------------------------------------------------ views

    /// @notice Everything the vault holds (trading fees, contributions, surplus, returns not yet spent; the bid's ETH
    ///         included).
    function generalBalance() public view returns (uint256) {
        return address(this).balance;
    }

    /// @notice How far what the vault may spend on Apes falls short of one Ape at the funding reference. While it
    ///         is short, the game sends it a share of its surplus (`continuityShareBps`) and the rest to buybacks.
    function shortfall() external view returns (uint256) {
        uint256 b = acquisitionBudget();
        uint256 r = referencePrice;
        return b < r ? r - b : 0;
    }

    function bidParams() external view returns (BidParams memory) {
        return _bid;
    }

    /// @notice The live bid: the ETH metered into it, never above what the vault may spend on NFTs nor `maxPrice`.
    function liveBid() public view returns (uint256 bid) {
        bid = bidBalance;
        uint256 budget = acquisitionBudget();
        if (bid > budget) bid = budget;
        uint256 cap = _bid.maxPrice;
        if (cap != 0 && bid > cap) bid = cap;
    }

    /// @notice Above this bid, sweeps forward only `slowSweepWei` per cooldown: `ceilingBps` of the funding reference
    ///         (unbounded when `ceilingBps` is 0).
    function bidCeiling() public view returns (uint256) {
        uint256 c = _bid.ceilingBps;
        return c == 0 ? type(uint256).max : referencePrice * c / BPS;
    }

    /// @notice First block a metered sweep may run (fills below the threshold have no cooldown).
    function nextSweepBlock() external view returns (uint256) {
        return lastSweepBlock + _bid.minBlocksBetweenSweeps;
    }

    /// @notice What the next sweep would send to the burner out of the unsplit fees: `overflowBps` of them while the
    ///         bid is full, at most what the vault holds beyond its budget's other uses, the bid and one more Ape at the
    ///         last price.
    function pendingOverflow() public view returns (uint256 amount) {
        uint256 fees = unsplitFees;
        // the bid is full: at its fill target (the threshold, or the ceiling or `maxPrice` when lower)
        uint256 full = activationThreshold;
        uint256 c = bidCeiling();
        if (c < full) full = c;
        if (_bid.maxPrice != 0 && _bid.maxPrice < full) full = _bid.maxPrice;
        // only once the game is running: before activation the vault's ETH is the first Ape's and the game's capital
        if (fees == 0 || overflowBps == 0 || !game.activated() || liveBid() < full) return 0;
        uint256 budget = acquisitionBudget();
        // never the game's capital, its growth, the bid's ETH or the next Ape
        uint256 keep = (bidBalance < budget ? bidBalance : budget) + referencePrice;
        if (budget <= keep) return 0;
        amount = fees * overflowBps / BPS;
        if (amount > budget - keep) amount = budget - keep;
    }

    /// @notice Meters available ETH into the live bid, after splitting the trading fees received since the last sweep
    ///         (`pendingOverflow` to the burner). Anyone; rewarded like a keeper, its gas plus the flat fee at the game's
    ///         keeper formula (`quoteTip`, at most 0.01 ETH), from the vault's general ETH. Below the activation threshold it fills the bid up to the threshold at once; at or above it,
    ///         at most `maxSweepWei` (above the ceiling `slowSweepWei`), once per `minBlocksBetweenSweeps` blocks.
    ///         Reverts when it would neither forward nor overflow anything.
    function sweep() external nonReentrant returns (uint256 amount) {
        uint256 gasStart = gasleft();
        uint256 over = pendingOverflow();
        unsplitFees = 0;
        if (over != 0) {
            overflowOut += over;
            emit Overflow(over);
            SafeTransferLib.safeTransferETH(burner, over);
        }
        BidParams memory p = _bid;
        uint256 budget = acquisitionBudget();
        uint256 bid = bidBalance < budget ? bidBalance : budget; // the game's capital comes first
        uint256 room = budget - bid;
        uint256 ceiling = bidCeiling();
        uint256 fill = activationThreshold < ceiling ? activationThreshold : ceiling;
        if (bid < fill) {
            amount = fill - bid;
        } else {
            uint256 next = lastSweepBlock + p.minBlocksBetweenSweeps;
            if (block.number < next) {
                if (over != 0) return 0; // the overflow alone was the work
                revert SweepTooEarly(next);
            }
            amount = bid >= ceiling ? p.slowSweepWei : (p.maxSweepWei < ceiling - bid ? p.maxSweepWei : ceiling - bid);
            lastSweepBlock = block.number;
        }
        if (amount > room) amount = room;
        if (p.maxPrice != 0) amount = bid >= p.maxPrice ? 0 : (amount < p.maxPrice - bid ? amount : p.maxPrice - bid);
        if (amount == 0) {
            if (over != 0) return 0;
            revert NothingToSend();
        }
        uint256 reward = game.quoteTip(gasStart - gasleft());
        if (reward > REWARD_CAP) reward = REWARD_CAP;
        if (room < amount + reward) {
            // carved off the forward when nothing is left beside it; when the overflow was this sweep's work, it stands
            // and the sweep ends unpaid instead of reverting it (round 7 F7-1)
            if (room <= reward) {
                if (over != 0) return 0;
                revert NothingToSend();
            }
            amount = room - reward;
        }
        uint256 general = generalBalance();
        if (reward > general) reward = general;
        bidBalance = bid + amount;
        if (reward != 0) {
            sweepRewards += reward;
            SafeTransferLib.forceSafeTransferETH(msg.sender, reward);
        }
        emit Swept(msg.sender, amount, reward, bid + amount);
    }

    /// @notice ETH acquisitions may spend now. Before activation, only the first NFT (all funds); after, whatever the
    ///         game does not need as capital, including the board rows NFTs already held are waiting for. There
    ///         is no inventory limit.
    function acquisitionBudget() public view returns (uint256) {
        if (game.retiring() || game.retired()) return 0;
        if (!game.activated()) return poolOwner.heldCount() == 0 ? address(this).balance : 0;
        uint256 need = game.capitalNeed() + game.growthNeed();
        uint256 bal = address(this).balance;
        return bal > need ? bal - need : 0;
    }

    // ------------------------------------------------------------------ acquisitions

    /// @notice Sells `tokenId` to the protocol for `price`, at most the live bid (approve this vault first): the
    ///         holder names its price, as in accepting Permanent Collection's live bid. The NFT goes to the pool
    ///         owner's custody, `price` to the seller, and `price` leaves the bid.
    function sellToProtocol(uint256 tokenId, uint256 price) external nonReentrant {
        uint256 bid = liveBid();
        if (price == 0 || price > bid) revert AboveBid(bid);
        if (excluded[tokenId]) revert NotEligible();
        if (IERC721Owner(collection).ownerOf(tokenId) != msg.sender) revert NotAllowed();
        IERC721Owner(collection).transferFrom(msg.sender, address(poolOwner), tokenId);
        _book(tokenId, msg.sender, address(0), price);
        SafeTransferLib.forceSafeTransferETH(msg.sender, price);
    }

    /// @notice Buys `tokenId` through a registered marketplace adapter at its listing's actual price, which with the
    ///         finder fee must fit in the live bid (and `maxSpend`). Anyone may call; the caller is paid the finder
    ///         fee (0.5% of the bid, at most 0.01 ETH). The adapter must deliver the NFT to custody and return unspent
    ///         ETH in the same call.
    function fillOrder(uint256 tokenId, uint256 maxSpend, bytes calldata data)
        external
        nonReentrant
        returns (uint256 spent)
    {
        if (adapter == address(0)) revert NotAllowed();
        if (excluded[tokenId]) revert NotEligible();
        uint256 bid = liveBid();
        uint256 fee = bid * REWARD_BPS / BPS;
        if (fee > REWARD_CAP) fee = REWARD_CAP;
        uint256 cap = bid - fee;
        if (maxSpend < cap) cap = maxSpend;
        if (cap == 0) revert OverBudget();
        address custody = address(poolOwner);
        if (IERC721Owner(collection).ownerOf(tokenId) == custody) revert NotAllowed();
        address a = adapter;
        uint256 aBefore = a.balance; // ETH anyone sent the adapter is not the vault's and stays there
        _adapterReturned = 0;
        IAcquisitionAdapter(a).execute{value: cap}(collection, tokenId, custody, data);
        if (a.balance > aBefore) revert AdapterKeptFunds();
        // the price is what left the vault through the adapter and did not come back from it: other ETH the vault
        // receives during the fill (a game payout, a contribution from an order's consideration) is booked as what it
        // is and does not lower the price
        uint256 back = _adapterReturned;
        if (back > cap) revert OverBudget();
        spent = cap - back;
        if (IERC721Owner(collection).ownerOf(tokenId) != custody) revert NotDelivered();
        _book(tokenId, address(0), a, spent);
        if (fee > generalBalance()) fee = generalBalance();
        if (fee != 0) {
            bidBalance -= fee < bidBalance ? fee : bidBalance;
            finderFees += fee;
            SafeTransferLib.forceSafeTransferETH(msg.sender, fee);
        }
    }

    /// @dev Records an acquisition, registers custody, takes the price out of the bid (the rest of the bid stays) and
    ///      resets the activation threshold from the clearing price.
    function _book(uint256 tokenId, address seller, address via, uint256 price) internal {
        uint256 cap = _bid.maxPrice;
        if (cap != 0 && price > cap) revert OverBudget();
        acquisitionSpend += price;
        ++acquisitionCount;
        uint256 bid = bidBalance;
        bidBalance = bid > price ? bid - price : 0;
        lastPrice = price;
        // the funding reference follows the price, but one sale cannot drag it below the Ape floor or more than
        // `maxDropBps` at once: a real fall is followed over successive purchases (D83)
        uint256 ref = referencePrice;
        uint256 low = ref - ref * _bid.maxDropBps / BPS;
        ref = price > low ? price : low;
        uint256 floor = poolOwner.minNotionalWei();
        if (ref < floor) ref = floor;
        referencePrice = ref;
        _setThreshold(ref * _bid.thresholdBps / BPS);
        poolOwner.register(tokenId, price, price, SOURCE_BOUGHT);
        emit Acquired(tokenId, seller, via, price);
    }

    // ------------------------------------------------------------------ game capital

    /// @notice Sends the game the capital it needs. Anyone may call. Before activation it sends nothing until a
    ///         collection NFT is held and the whole requirement is available.
    function fundGame() external nonReentrant returns (uint256 amount) {
        if (game.retiring() || game.retired()) revert NotAllowed();
        uint256 need = game.capitalNeed();
        uint256 general = generalBalance();
        if (!game.activated()) {
            if (poolOwner.heldCount() == 0 || general < need) revert NotAllowed();
        }
        amount = need < general ? need : general;
        if (amount == 0) revert NothingToSend();
        gameCapitalSent += amount;
        game.receiveCapital{value: amount}();
        emit GameFunded(amount);
    }

    // ------------------------------------------------------------------ migration (MigrationAuthority only)

    /// @notice Sends every wei held (including the retired game's returned capital and the redeemed prize backing) to
    ///         the successor, once the game has retired: a migration's successor or the sunset, which burns it.
    ///         Committed buyback ETH is never here (it is in the burner). Repeatable: later returns and contributions
    ///         follow.
    function migrateCapital(address successor) external nonReentrant returns (uint256 amount) {
        if (msg.sender != migrator) revert NotMigrator();
        if (!game.retired()) revert NotAllowed();
        amount = address(this).balance;
        if (amount == 0) return 0;
        bidBalance = 0;
        migratedOut += amount;
        SafeTransferLib.forceSafeTransferETH(successor, amount);
        emit CapitalMigrated(successor, amount);
    }

    // ------------------------------------------------------------------ governance

    /// @notice The live bid's parameters. The ETH already in the bid stays; the threshold changes at the next
    ///         acquisition (or with `setActivationThreshold`).
    function setBidParams(BidParams calldata p) external onlyOwner {
        _setBidParams(p);
    }

    /// @notice Corrects the activation threshold (for example the deploy-time value); the next acquisition re-syncs
    ///         it from its clearing price.
    function setActivationThreshold(uint256 threshold) external onlyOwner {
        _setThreshold(threshold);
    }

    /// @notice The fee overflow's share (0-100%; 0 turns it off).
    function setOverflowBps(uint256 bps) external onlyOwner {
        _setOverflowBps(bps);
    }

    function _setOverflowBps(uint256 bps) internal {
        if (bps > BPS) revert OutOfBounds();
        overflowBps = bps;
        emit OverflowBpsSet(bps);
    }

    function setExcluded(uint256 tokenId, bool ex) external onlyOwner {
        excluded[tokenId] = ex;
        emit Excluded(tokenId, ex);
    }

    function _setBidParams(BidParams memory p) internal {
        if (
            p.thresholdBps > BPS || p.maxSweepWei == 0 || p.maxSweepWei > 100 ether || p.minBlocksBetweenSweeps == 0
                || p.minBlocksBetweenSweeps > 7_200 || (p.ceilingBps != 0 && (p.ceilingBps < BPS || p.ceilingBps > 100_000))
                || p.slowSweepWei > p.maxSweepWei || p.maxDropBps < 100 || p.maxDropBps > BPS
        ) revert OutOfBounds();
        _bid = p;
        emit BidParamsSet(p);
    }

    function _setThreshold(uint256 t) internal {
        if (t > 1_000 ether) revert OutOfBounds();
        activationThreshold = t;
        emit ThresholdSet(t);
    }
}
