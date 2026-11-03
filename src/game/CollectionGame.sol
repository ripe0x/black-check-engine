// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Governed} from "../core/Governed.sol";
import {IFWAPool, IFWAFactory} from "../interfaces/IFWA.sol";
import {ICollectionGame, IFundingVault, IBurner} from "../interfaces/ICollectionGames.sol";

interface IPoolOwnerGame {
    function pool() external view returns (IFWAPool);
    struct Prize {
        uint256 backing;
        uint256 price;
    }

    function prizeCost(uint256 backing) external view returns (uint256 cost, bool isPack);
    function mintFee() external view returns (uint256);
    function mintAndList(Prize[] calldata prizes)
        external
        payable
        returns (uint256[] memory ids, uint256[] memory tokenIds);
    function withdrawShapes(uint256[] calldata ids) external returns (uint256 eth);
    function recoverShape(uint256 listingId) external returns (uint256 eth);
    function setAcquisitions(bool enabled) external;
    function collectProceeds() external returns (uint256 amount);
    function retirePool() external;
    function processCollection(uint256 turnover) external returns (uint256 work);
    function settleListing(uint256 listingId) external returns (bool isCollection);
    function withdrawCollection() external returns (uint256 left);
    function collectionAvailable() external view returns (bool);
    function rowsShort() external view returns (uint256);
}

/// @title CollectionGame
/// @notice The game ledger and working capital of one collection game. It pays for the ordinary prizes (Shapes, and Draw
///         Packs of Shapes) with its capital and has the pool owner mint and list them; walks FWA's request sequence
///         (`sync`) to book every pull exactly once; replaces won prizes at maintenance windows; grows the board when the
///         collection NFTs need more rows for the exposure target (CollectionPoolOwner `rowsShort`) and the vault can fund
///         it; opens and closes FWA purchases by its admission rules; pays whoever runs that maintenance its gas plus a
///         flat fee, within an allowance earned from captures; and sends only realised, distributable surplus onward: a
///         share to the vault while the vault is short of one Ape, the rest to the CollectionBurner. When the game
///         retires (a migration, or the sunset) it returns everything to the vault.
/// @dev Accounting (docs/SPEC.md "Accounting"). Prizes are capital carried at cost: backing plus every Shapes mint fee
///      paid for them (one for a Shape, one per Shape inside a Draw Pack). A capture books the owner proceeds FWA pays
///      for it as revenue; a prize capture books the prize's carried cost as its one expense (the replacement is a capital movement). A collection capture books its proceeds as revenue and
///      no expense here: the collection NFT was paid for by the vault (trading fees, contributions, or surplus the
///      game already distributed), so charging it again would double count;
///      the pool owner records its cost by source. Keeper pay is an expense when it is paid; it is limited by an allowance
///      that grows by `opsBps` of each capture's expected replacement cost. Profit is cumulative and signed, so losses
///      carry forward; capital in (vault funding) never enters it. A distribution needs both undistributed profit and
///      cash above every protected amount.
///      ETH leaves only to: the Shapes contract (mint cost), the caller of a maintenance call (keeper pay), the vault
///      (surplus share and retirement return) and the CollectionBurner (surplus).
///      Provenance: ripe0x/draw-shapes PR #9 `FwaGame` (MIT): the walk, booking, replacement, admission and capital
///      protection are kept; genesis epochs, promotions, conversion and pool ownership are removed; collection
///      captures, activation, board growth and the surplus split are new.
contract CollectionGame is ICollectionGame, ReentrancyGuard, Governed {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_LIST_BATCH = 10; // prize withdrawals per retirement step
    // setter ceilings: on a board of four-Shape Packs (the heaviest launch prize) every maintenance call at them stays
    // within 90% of EIP-7825's transaction gas cap (test/fork/TxCap.t.sol), so no permitted setting can stall upkeep
    uint256 internal constant MAX_PER_CALL = 10; // the most `maxPerCall` may be set to
    uint256 internal constant MAX_BOOK_PER_CALL = 20; // the most `bookPerCall` may be set to
    uint256 internal constant MAX_PATTERN = 1_000;
    uint256 internal constant MAX_GROWTH_STEP = 50;
    uint256 public constant MAX_MARKUP_BPS = 10_000;
    uint256 public constant MAX_OPS_BPS = 10_000;
    uint256 public constant MAX_CONTINUITY_SHARE_BPS = 10_000;
    uint256 internal constant MAX_COOLDOWN = 30 days;
    uint256 internal constant MAX_MAINTENANCE_INTERVAL = 30 days;
    uint256 internal constant MAX_RESERVE_TARGET = 1_000 ether;
    /// @notice A paid `sync` lighter than this (what a player's draw takes on through the DrawRouter) is refused within
    ///         the keeper `payDelay` of a player's upkeep that did work: the next draw does it unpaid.
    uint256 public constant PLAYER_UPKEEP_GAS = 2_500_000;

    IFWAFactory public immutable factory;
    IPoolOwnerGame public immutable poolOwner;
    IFundingVault public immutable vault;
    /// @notice The CollectionBurner: surplus beyond the vault's share, and the milestone release on a collection win.
    address public immutable burner;
    /// @notice The MigrationAuthority: the only caller of `retire` (a migration after its notice, or the sunset).
    address public immutable migrator;

    /// @notice The ordinary board: a pattern of prize backings repeated without end; row `r` asks for
    ///         `pattern[r % length]`. A new pattern applies to each row the next time that row is listed.
    uint256[] internal _pattern;
    /// @notice The largest backing in the pattern (the operating reserve must cover it).
    uint256 public maxBacking;
    /// @notice Empty rows that make a replacement window due before `maintenanceInterval` has passed.
    uint256 public listBatch;
    /// @notice The most prizes one maintenance call lists (sized for EIP-7825's gas cap; at most 20).
    uint256 public maxPerCall;
    /// @notice The most requests one `sync` or `retireStep` settles, resolves and books, each (sized for EIP-7825's gas
    ///         cap; at most 100). Fixed by the owner, not the caller, so a backlog cannot be split into many paid calls.
    uint256 public bookPerCall;
    /// @notice Prize price = full replacement cost (backing + mint fees) × (1 + markup); frozen at listing.
    uint256 public markupBps;
    /// @notice Keeper allowance earned per capture, in bps of its expected replacement cost; frozen at listing.
    uint256 public opsBps;

    /// @notice Keeper pay: `(gasUsed + gasOverhead) × min(tx.gasprice, maxGasPrice) + flatFee`.
    struct KeeperParams {
        uint256 maxGasPrice; // gas is reimbursed at the transaction's gas price up to this cap
        uint256 gasOverhead; // gas outside the game's own measurement (intrinsic, calldata, the payment)
        uint256 flatFee; // on top of the gas, per useful call, so third-party keepers have a reason to run
        uint256 payDelay; // after an upkeep that did work, light work is left to players' draws this long (0: off)
    }

    KeeperParams internal _keeper;

    /// @notice Capital and admission settings (`setSettings`, bounded).
    struct Settings {
        uint256 reserveTarget; // operating reserve kept before any distribution
        uint256 maintenanceInterval; // longest wait before replacements list
        uint256 minLiveBps; // board fill below which new purchases close
        uint256 maxOutstanding; // unsettled requests above which new purchases close
        uint256 maxEdgeBps; // FWA edge above which new purchases close
        uint256 maxCooldown; // FWA inventory cooldown above which new purchases close
        uint256 minDistribution; // smallest distribution worth sending
        uint256 continuityShareBps; // share of each distribution to the vault while it is short of one Ape
    }

    Settings public settings;

    /// @notice One record per Shape listing this game made.
    struct Item {
        uint48 tokenId;
        uint72 backing;
        uint72 cost; // backing + mint fee paid
        uint24 row;
        uint16 markupBps; // frozen at listing
        uint16 opsBps; // frozen at listing
        bool isPack; // a Draw Pack of `backing / unit` Shapes; otherwise one Shape
    }

    mapping(uint256 listingId => Item) public items;
    uint256[] internal _live;
    mapping(uint256 listingId => uint256) internal _liveIndex; // index + 1
    /// @dev Rows in play without a live listing: each is owed a prize (`_restock` lists them, last first).
    uint256[] internal _owed;
    /// @notice Rows `[0, boardSize)` of the pattern are in play.
    uint256 public boardSize;
    /// @notice Average cost of a row added by the last growth (estimates the next growth's cost).
    uint256 public rowCost;

    uint64 public seenSeq = 1;
    /// @notice When an `upkeep` last did work (a player's draw, or anyone unpaid).
    uint64 public lastUpkeepAt;
    uint64[] internal _open;

    // capital
    uint256 public capitalIn; // from the vault
    uint256 public inventoryBacking; // backing of Shapes held or listed
    uint256 public inventoryCost; // carried cost of Shapes held or listed
    uint256 public replacementsOwed; // cost of board rows in play without a live Shape, at `owedFee`
    uint256 public owedFee; // Shapes' mint fee `replacementsOwed` is counted at
    uint256 internal _feeFrom; // first FWA listing id made at `owedFee` (FWA numbers listings in order)
    uint256 public maxItemCost; // largest Shape cost, for settlement exposure

    // keeper pay
    uint256 public keeperAllowance; // earned so far: the opening allowance plus `opsBps` of every capture
    uint256 public keeperPaid; // paid so far (an expense)

    // profit and loss
    uint256 public turnover; // ticket ETH of delivered pulls (FWA fee, excluding the VRF fee)
    uint256 public revenue; // owner proceeds of every delivered pull (a lower bound, trued up to ETH received)
    uint256 public proceedsCollected; // owner proceeds actually received from FWA
    uint256 public proceedsBooked; // owner proceeds booked as revenue (estimates plus true-ups)
    /// @notice The highest `maxEdgeBps` ever set. The purchase gate admits no request above the then-current setting,
    ///         so booking with this edge never overstates FWA's owner proceeds.
    uint256 public bookingEdgeBps;
    /// @notice `opsBps` of the most recent listing batch, used for collection captures.
    uint256 public lastOpsBps;
    uint256 public collectionRevenue; // the part of `revenue` from pulls that won a collection NFT
    uint256 public prizeExpense; // carried cost of Shapes won, plus mint fees written off
    uint256 public distributed; // total distributions (vault share + burner)
    uint256 public toVault;
    uint256 public toBurner;
    uint256 public returnedToVault;

    // request outcomes
    uint256 public pullsFulfilled;
    uint256 public collectionWins;
    uint256 public pullsRefunded; // slippage or no listing
    uint256 public pullsExpired; // VRF timeout or expiry
    uint256 public deliveriesRefunded;

    bool public activated;
    bool public paused;
    bool public retiring;
    bool public retired;
    uint256 public lastMaintenanceAt;

    event Activated(uint256 boardSize, uint256 cash);
    event Funded(uint256 amount);
    event Admission(bool open);
    event Listed(uint256 indexed listingId, uint256 indexed row, uint256 price);
    event Resolved(uint256 indexed sequence, uint256 indexed listingId, uint8 status);
    event Captured(uint256 indexed listingId, bool collection, uint256 proceeds, uint256 cost, uint256 ops);
    event Distributed(uint256 toVault, uint256 toBurner);
    event KeeperPaid(address indexed keeper, uint256 amount);
    event BoardGrown(uint256 from, uint256 to, uint256 cost);
    event RetireStarted();
    event Retired(uint256 returned);
    event PatternSet(uint256 length, uint256 maxBacking);
    event PricingSet(uint256 markupBps, uint256 opsBps);
    event BoardParamsSet(uint256 listBatch, uint256 maxPerCall, uint256 bookPerCall);
    event KeeperParamsSet(KeeperParams p);
    event SettingsSet(Settings s);
    event Paused(bool paused);
    event StepFailed(bytes32 indexed step);
    event ProceedsTrueUp(uint256 amount);

    error NotVault();
    error NotPoolOwner();
    error Retiring();
    error NotRetiring();
    error NotReady();
    error NoWork();
    error OutOfGas();
    error NotSelf();

    struct Config {
        address admin;
        address factory;
        address poolOwner;
        address vault;
        address burner;
        address migrator;
        uint256[] pattern;
        uint256 initialBoardSize;
        uint256 listBatch;
        uint256 maxPerCall;
        uint256 bookPerCall;
        uint256 markupBps;
        uint256 opsBps;
        KeeperParams keeper;
        uint256 openingAllowance; // keeper pay available before any capture (listing the opening board)
        Settings settings;
    }

    constructor(Config memory c) Governed(c.admin, false) {
        if (
            c.factory == address(0) || c.poolOwner == address(0) || c.vault == address(0) || c.burner == address(0)
                || c.migrator == address(0)
        ) revert ZeroAddress();
        factory = IFWAFactory(c.factory);
        poolOwner = IPoolOwnerGame(c.poolOwner);
        vault = IFundingVault(c.vault);
        burner = c.burner;
        migrator = c.migrator;
        _setPattern(c.pattern);
        _setBoardParams(c.listBatch, c.maxPerCall, c.bookPerCall);
        _setPricing(c.markupBps, c.opsBps);
        _keeper = c.keeper;
        emit KeeperParamsSet(c.keeper);
        keeperAllowance = c.openingAllowance;
        _setSettings(c.settings);
        if (c.initialBoardSize == 0) revert OutOfBounds();
        owedFee = poolOwner.mintFee();
        _grow(c.initialBoardSize);
    }

    /// @dev ETH from the pool owner: owner proceeds and burned Shapes' backing, accounted by the call that caused it.
    receive() external payable {
        if (msg.sender != address(poolOwner)) revert NotPoolOwner();
    }

    function pool() public view returns (IFWAPool) {
        return poolOwner.pool();
    }

    // ------------------------------------------------------------------ inflows

    /// @notice Capital from the vault. Capital is never profit.
    function receiveCapital() external payable {
        if (msg.sender != address(vault)) revert NotVault();
        capitalIn += msg.value;
        emit Funded(msg.value);
    }

    // ------------------------------------------------------------------ activation and pause

    /// @notice True when every activation requirement holds: the pool exists, every board row in play is listed
    ///         and active, a collection NFT is in the draw, no request is unsettled, the operating reserve is in
    ///         cash or the vault can cover it, and FWA's settings are in the supported range.
    function ready() public view returns (bool) {
        IFWAPool p = pool();
        if (address(p) == address(0) || activated || retiring) return false;
        return _owed.length == 0 && p.unsettledAcquisitionCount() == 0
            && p.activeListingCount() > boardSize && poolOwner.collectionAvailable()
            && capitalNeed() <= vault.generalBalance() && admissible();
    }

    /// @notice Opens paid gameplay once `ready()`, first drawing from the vault the reserve the opening keeper pay
    ///         took (a refill smaller than a row's cost does not count as paid work in `sync`). Anyone may call; it happens at most once.
    function activate() external nonReentrant {
        if (!ready()) revert NotReady();
        if (capitalNeed() != 0) vault.fundGame();
        if (cash() < settings.reserveTarget) revert NotReady();
        activated = true;
        _admit();
        emit Activated(boardSize, cash());
    }

    /// @notice Pauses or resumes new purchases. Settlement, delivery, refunds and claims continue either way.
    function setPaused(bool paused_) external onlyOwner {
        if (retiring) revert Retiring();
        paused = paused_;
        emit Paused(paused_);
        if (address(pool()) != address(0)) _admit();
    }

    // ------------------------------------------------------------------ keeper work

    /// @notice Settles and books up to `bookPerCall` requests, collects proceeds, pays the operating allocation and
    ///         distributable surplus, requests vault capital when needed, at a maintenance window grows the board,
    ///         lists replacements and maintains the collection listings, and applies the admission rules. Anyone may
    ///         call; paid its gas plus a flat fee (`quoteTip`, within the keeper allowance). Reverts `NoWork` when there
    ///         is nothing to do. Light work (under `PLAYER_UPKEEP_GAS`) within the keeper `payDelay` of a player's
    ///         upkeep that did work is done but not paid: players are active, and the next draw would do it unpaid.
    /// @dev Each step after booking runs in its own `try`: a failing module, Shapes mint, FWA listing call or
    ///      distribution emits `StepFailed` and leaves the other steps working. The purchase gate (CollectionPoolOwner
    ///      `canPurchase`) does not depend on any of these steps.
    function sync() external nonReentrant returns (uint256 work) {
        uint256 gasStart = gasleft();
        work = _sync(bookPerCall);
        if (gasStart - gasleft() < PLAYER_UPKEEP_GAS && block.timestamp < lastUpkeepAt + _keeper.payDelay) {
            if (work == 0) revert NoWork();
            return work;
        }
        _tip(gasStart, work);
    }

    /// @notice `sync` without the keeper pay: the same work, paid by nobody, so it spends no keeper allowance.
    ///         A player's draw through the DrawRouter calls it; keepers call `sync`. Does not revert when there is
    ///         nothing to do.
    function upkeep(uint256 maxCount) external nonReentrant returns (uint256 work) {
        work = _sync(maxCount < bookPerCall ? maxCount : bookPerCall); // never more than a keeper's call (D85)
        if (work != 0) lastUpkeepAt = uint64(block.timestamp);
    }

    function _sync(uint256 maxCount) internal returns (uint256 work) {
        IFWAPool p = pool();
        if (address(p) == address(0)) revert NotReady();
        if (retiring) revert Retiring();
        // Shapes' admin may change its mint fee: recount what the owed rows will cost before anything is paid out
        if (poolOwner.mintFee() != owedFee) _recountOwed();
        work = _advance(p, maxCount);
        // funding counts as work only when it covers the whole need and the need was at least one row's cost: keeper
        // pay itself draws the reserve down, and refilling that dust must not earn the next call a fee
        uint256 need = capitalNeed();
        uint256 g = gasleft();
        if (need != 0) {
            try vault.fundGame() {
                if (capitalNeed() == 0 && need >= rowCost) ++work;
            } catch {
                _gasCheck(g);
            }
        }
        if (!p.retired() && !factory.globalWithdrawOnly()) {
            g = gasleft();
            try this.maintainStep() returns (uint256 changes) {
                work += changes;
            } catch {
                _gasCheck(g);
                emit StepFailed("maintenance");
            }
        }
        g = gasleft();
        try this.admitStep() returns (bool changed) {
            if (changed) ++work;
        } catch {
            _gasCheck(g);
            emit StepFailed("admission");
        }
    }

    /// @notice Internal step of `sync`, external only so that it can fail on its own. Self-call only.
    function maintainStep() external returns (uint256 changes) {
        if (msg.sender != address(this)) revert NotSelf();
        if (!_maintenanceDue()) return 0;
        changes = _restock();
        // collection NFTs: credit gameplay, list from custody, decay (each FWA change in the same window); then the
        // board grows by the rows they are waiting for, in the same call
        uint256 g = gasleft();
        try poolOwner.processCollection(turnover) returns (uint256 w) {
            changes += w;
        } catch {
            _gasCheck(g);
            emit StepFailed("collection");
        }
        changes += _maybeGrow();
        if (changes != 0) lastMaintenanceAt = block.timestamp;
    }

    /// @notice Internal step of `sync`. Self-call only.
    function admitStep() external returns (bool) {
        if (msg.sender != address(this)) revert NotSelf();
        return _admit();
    }

    /// @notice Internal step of booking: pays out distributable surplus. Self-call only.
    function payStep() external {
        if (msg.sender != address(this)) revert NotSelf();
        _pay();
    }

    /// @notice What the purchase gate needs from the game: the Shape floor (half the board in play) and the highest
    ///         FWA edge purchases may open at.
    function gateParams() external view returns (uint256 minShapes, uint256 maxEdgeBps) {
        return (boardSize / 2, settings.maxEdgeBps);
    }

    /// @notice Starts retirement: retires the FWA pool, which stops new purchases for good. Settlement, delivery and
    ///         refunds continue. The MigrationAuthority only: a migration after its notice, or the sunset; the pool
    ///         owner and vault then hand the assets to the successor.
    function retire() external {
        if (msg.sender != migrator) revert NotOwner();
        if (retiring) revert Retiring();
        retiring = true;
        if (address(pool()) != address(0)) poolOwner.retirePool();
        emit RetireStarted();
    }

    /// @notice Retirement, step by step: settle and book; withdraw and burn every Shape still listed; withdraw the
    ///         collection NFTs into custody; then return everything to the vault (the MigrationAuthority then hands the
    ///         Apes and the vault's ETH to the successor). A prize stuck in FWA's delivery quarantine does not block it:
    ///         later calls sweep what it yields. Anyone.
    function retireStep() external nonReentrant returns (uint256 work) {
        uint256 gasStart = gasleft();
        if (!retiring) revert NotRetiring();
        IFWAPool p = pool();
        bool caughtUp = true;
        if (address(p) != address(0)) {
            work = _advance(p, bookPerCall);
            caughtUp = p.unsettledAcquisitionCount() == 0 && seenSeq > p.lastIssuedSequence();
        }
        uint256 left;
        if (caughtUp && !retired && address(p) != address(0)) {
            work += _withdrawSome(p);
            uint256 apes = poolOwner.withdrawCollection();
            left = _withdrawable(p) + apes;
            if (apes != 0) ++work;
        }
        uint256 amount = address(this).balance;
        if (caughtUp && left == 0 && (!retired || amount != 0)) {
            replacementsOwed = 0;
            returnedToVault += amount;
            if (!retired) {
                retired = true;
                if (amount != 0) vault.receiveReturn{value: amount}();
                emit Retired(amount);
            } else {
                vault.receiveReturn{value: amount}(); // a late settlement after retirement
            }
            ++work;
        }
        _tip(gasStart, work);
    }

    /// @notice What a maintenance call that used `gasUsed` gas is paid, before the allowance and cash limits:
    ///         `(gasUsed + gasOverhead) × min(tx.gasprice, maxGasPrice) + flatFee`. The gas price is read from the
    ///         calling transaction (an off-chain quote made with a zero gas price is the flat fee alone). The burner uses it for its
    ///         own keeper.
    function quoteTip(uint256 gasUsed) public view returns (uint256) {
        KeeperParams memory k = _keeper;
        uint256 price = tx.gasprice < k.maxGasPrice ? tx.gasprice : k.maxGasPrice;
        return (gasUsed + k.gasOverhead) * price + k.flatFee;
    }

    /// @notice Keeper pay still available: the allowance earned less what has been paid.
    function keeperAvailable() public view returns (uint256) {
        return keeperAllowance > keeperPaid ? keeperAllowance - keeperPaid : 0;
    }

    /// @dev Pays the caller of a useful call. Always within the allowance (so no keeper parameter can reach the cash a
    ///      retirement hands to the successor or the sunset); never out of cash owed to replacements, except during
    ///      retirement, when nothing is owed.
    function _tip(uint256 gasStart, uint256 work) internal {
        if (work == 0) revert NoWork();
        uint256 pay = quoteTip(gasStart - gasleft());
        uint256 avail = keeperAvailable();
        if (pay > avail) pay = avail;
        uint256 c = cash();
        uint256 owed = retiring ? 0 : replacementsOwed;
        uint256 free = c > owed ? c - owed : 0;
        if (pay > free) pay = free;
        if (pay == 0) return;
        keeperPaid += pay;
        emit KeeperPaid(msg.sender, pay);
        SafeTransferLib.forceSafeTransferETH(msg.sender, pay);
    }

    /// @dev After an isolated step fails: if less than 1/8 of the gas it started with is left, it most likely ran out of
    ///      gas somewhere down its call chain (EIP-150 leaves each caller 1/64; a chain of a few calls a few 64ths), so
    ///      the whole call fails. A caller cannot skip work by sending too little gas and still be paid, and a gas
    ///      estimate covers every step. A step that reverts on its own fails alone, as before, given enough gas: a
    ///      deterministic failure that used most of a small limit passes with a larger one.
    function _gasCheck(uint256 before) internal view {
        if (gasleft() < before / 8) revert OutOfGas();
    }

    function _advance(IFWAPool p, uint256 maxCount) internal returns (uint256 work) {
        uint256 g = gasleft();
        try p.processAcquisitions(maxCount) {} catch {
            _gasCheck(g);
        }
        uint256 edge = bookingEdgeBps;
        // one budget for both: a call books at most `maxCount` requests in all (D85)
        work = _resolveOpen(p, maxCount, edge);
        if (work < maxCount) work += _see(p, maxCount - work, edge);
        if (p.ownerProceeds() != 0) {
            g = gasleft();
            try poolOwner.collectProceeds() returns (uint256 got) {
                proceedsCollected += got;
            } catch {
                _gasCheck(g);
                emit StepFailed("proceeds");
            }
        }
        _trueUp(p);
        g = gasleft();
        try this.payStep() {} catch {
            _gasCheck(g);
            emit StepFailed("distribution");
        }
    }

    /// @dev Once every issued request is booked and FWA holds no owner proceeds, books what FWA actually paid above the
    ///      booked estimates (they are lower bounds: `_bookCapture`).
    function _trueUp(IFWAPool p) internal {
        if (
            proceedsCollected <= proceedsBooked || _open.length != 0 || seenSeq <= p.lastIssuedSequence()
                || p.ownerProceeds() != 0
        ) return;
        uint256 extra = proceedsCollected - proceedsBooked;
        proceedsBooked += extra;
        revenue += extra;
        emit ProceedsTrueUp(extra);
    }

    // ------------------------------------------------------------------ accounting views

    function cash() public view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Realised profit since launch, signed: revenue less prize expense and keeper pay.
    function profit() public view returns (int256) {
        return int256(revenue) - int256(prizeExpense + keeperPaid);
    }

    /// @notice Worst-case replacement cost of requests FWA has issued and not settled: each wins the costliest
    ///         prize, but together they cannot win more than every prize held or listed.
    function exposure() public view returns (uint256 e) {
        IFWAPool p = pool();
        if (address(p) != address(0)) e = p.unsettledAcquisitionCount() * maxItemCost;
        if (e > inventoryCost) e = inventoryCost;
    }

    /// @notice Cash protected before any distribution: replacements owed, the operating reserve and the settlement
    ///         exposure.
    function protectedCash() public view returns (uint256) {
        return replacementsOwed + settings.reserveTarget + exposure();
    }

    /// @notice What may be distributed now: the lesser of undistributed profit and cash above protection.
    function distributable() public view returns (int256 undistributed, uint256 amount) {
        undistributed = profit() - int256(distributed);
        uint256 c = cash();
        uint256 keep = protectedCash();
        if (retiring || !activated || undistributed <= 0 || c <= keep) return (undistributed, 0);
        c -= keep;
        amount = uint256(undistributed) < c ? uint256(undistributed) : c;
    }

    /// @notice Capital the game needs from the vault to cover every protected amount.
    function capitalNeed() public view returns (uint256) {
        if (retiring || retired) return 0;
        uint256 need = protectedCash();
        uint256 c = cash();
        return need > c ? need - c : 0;
    }

    /// @notice Estimated cost of the board rows the collection NFTs are waiting for (beyond rows already owed). The
    ///         vault keeps it before bidding for more NFTs.
    function growthNeed() external view returns (uint256) {
        if (retiring || retired || !activated) return 0;
        uint256 rows = poolOwner.rowsShort();
        uint256 owed = _owed.length;
        return rows > owed ? (rows - owed) * rowCost : 0;
    }

    /// @notice True when FWA's settings are in the supported range and the board and queue allow new purchases.
    function admissible() public view returns (bool) {
        IFWAPool p = pool();
        Settings memory s = settings;
        return factory.edgeBps() <= s.maxEdgeBps && factory.inventoryChangeCooldown() <= s.maxCooldown
            && _liveRows() * BPS >= s.minLiveBps * boardSize && p.unsettledAcquisitionCount() <= s.maxOutstanding;
    }

    /// @dev Pays out distributable surplus: `continuityShareBps` of it to the vault while the vault is short of one Ape
    ///      (never more than the shortfall), the rest to the burner (which locks its milestone share).
    function _pay() internal {
        (, uint256 d) = distributable();
        if (d == 0 || d < settings.minDistribution) return;
        uint256 v = d * settings.continuityShareBps / BPS;
        uint256 short = vault.shortfall();
        if (v > short) v = short;
        distributed += d;
        toVault += v;
        toBurner += d - v;
        if (v != 0) vault.receiveSurplus{value: v}();
        SafeTransferLib.safeTransferETH(burner, d - v);
        emit Distributed(v, d - v);
    }

    /// @dev Opens or closes FWA purchases to match the rules. True when it changed.
    function _admit() internal returns (bool) {
        IFWAPool p = pool();
        if (p.retired()) return false;
        bool ok = activated && !paused && !retiring && admissible();
        if (ok == p.localPurchasesEnabled()) return false;
        poolOwner.setAcquisitions(ok);
        emit Admission(ok);
        return true;
    }

    // ------------------------------------------------------------------ the walk

    /// @dev First cursor: every issued request is seen once and resolved at once if already terminal; otherwise it
    ///      joins the open set.
    function _see(IFWAPool p, uint256 maxCount, uint256 edge) internal returns (uint256 n) {
        uint64 seq = seenSeq;
        uint64 last = p.lastIssuedSequence();
        while (n < maxCount && seq <= last) {
            if (!_tryResolve(p, seq, edge)) _open.push(seq);
            ++seq;
            ++n;
        }
        seenSeq = seq;
    }

    /// @dev Second cursor: resolves open requests that have become terminal, in any order.
    function _resolveOpen(IFWAPool p, uint256 maxCount, uint256 edge) internal returns (uint256 n) {
        uint256 i;
        while (i < _open.length && n < maxCount) {
            if (_tryResolve(p, _open[i], edge)) {
                _open[i] = _open[_open.length - 1];
                _open.pop();
                ++n;
            } else {
                ++i;
            }
        }
    }

    /// @dev Resolves a request if terminal. A pending delivery of a Shape vacates its row at once (FWA has taken it out
    ///      of the draw) and stays open until FWA settles it.
    function _tryResolve(IFWAPool p, uint64 seq, uint256 edge) internal returns (bool) {
        (, , uint256 paid, uint256 listingId, IFWAPool.AcquisitionStatus st) = p.acquisitions(p.requestIdAtSequence(seq));
        if (
            st == IFWAPool.AcquisitionStatus.Pending || st == IFWAPool.AcquisitionStatus.Ready
                || st == IFWAPool.AcquisitionStatus.None
        ) return false;
        if (st == IFWAPool.AcquisitionStatus.DeliveryPending) {
            if (items[listingId].cost == 0) _settleCollection(listingId); // a collection NFT leaves the draw
            else _vacate(listingId);
            return false;
        }
        if (st == IFWAPool.AcquisitionStatus.Fulfilled) {
            ++pullsFulfilled;
            turnover += paid;
            _bookCapture(listingId, paid, edge);
        } else if (st == IFWAPool.AcquisitionStatus.DeliveryRefunded) {
            if (items[listingId].cost != 0) {
                // The player took the refund: recover the Shape and burn it; its row is replaced as usual. If that
                // fails the request stays open and is retried; it blocks nothing else.
                _vacate(listingId);
                uint256 g = gasleft();
                try poolOwner.recoverShape(listingId) {
                    _burnBook(listingId);
                } catch {
                    _gasCheck(g);
                    emit StepFailed("recover");
                    return false;
                }
            } else {
                _settleCollection(listingId); // a collection NFT returns to custody
            }
            ++deliveriesRefunded;
        } else if (st == IFWAPool.AcquisitionStatus.Refunded) {
            ++pullsRefunded;
        } else {
            ++pullsExpired;
        }
        emit Resolved(seq, listingId, uint8(st));
        return true;
    }

    /// @dev Books a delivered pull. Revenue: FWA's owner proceeds, `paid - (paid - base) / 2` with FWA's request-time
    ///      base price. FWA does not expose that base after settlement, so it is taken as `paid / (1 + edge)` with
    ///      `edge = bookingEdgeBps`, the highest edge the purchase gate has ever admitted: a lower bound, never an
    ///      overstatement (`_trueUp` books the rest once FWA has paid it). A Shape's carried cost is the expense; a
    ///      collection NFT's cost was paid by the vault and is not charged again. The keeper allowance grows by the
    ///      prize's `opsBps` (frozen at listing) of its carried cost, its replacement cost; for a collection capture, by
    ///      the last listed `opsBps` of the base price.
    function _bookCapture(uint256 listingId, uint256 paid, uint256 edge) internal {
        uint256 base = paid * BPS / (BPS + edge);
        uint256 proceeds = paid - (paid - base) / 2;
        revenue += proceeds;
        proceedsBooked += proceeds;
        Item memory it = items[listingId];
        uint256 ops = it.cost != 0 ? uint256(it.cost) * it.opsBps / BPS : base * lastOpsBps / BPS;
        keeperAllowance += ops;
        bool isCollection;
        if (it.cost != 0) {
            _vacate(listingId);
            inventoryBacking -= it.backing;
            inventoryCost -= it.cost;
            prizeExpense += it.cost;
            delete items[listingId];
            // a big prize releases its tier of the burner's milestone reserve; the burner checks FWA again
            if (uint256(it.cost) * (BPS + it.markupBps) / BPS >= IBurner(burner).bigPrizeWei()) _release(listingId);
        } else if (_settleCollection(listingId)) {
            isCollection = true;
            ++collectionWins;
            collectionRevenue += proceeds;
            _release(listingId);
        }
        emit Captured(listingId, isCollection, proceeds, it.cost, ops);
    }

    /// @dev Asks the burner to release the milestone tier of a delivered win; a failure never blocks booking (anyone can
    ///      release it later).
    function _release(uint256 listingId) internal {
        uint256 g = gasleft();
        try IBurner(burner).release(listingId) {} catch {
            _gasCheck(g);
        }
    }

    /// @dev Has the pool owner record a collection listing's outcome from FWA's state. A failure is reported and
    ///      retried by the next booking or by anyone (`CollectionPoolOwner.settleListing`); it never blocks booking.
    function _settleCollection(uint256 listingId) internal returns (bool isCollection) {
        uint256 g = gasleft();
        try poolOwner.settleListing(listingId) returns (bool c) {
            isCollection = c;
        } catch {
            _gasCheck(g);
            emit StepFailed("collection");
        }
    }

    /// @dev Takes a prize listing off the board: its row needs a replacement, at the backing the pattern asks for now
    ///      (after a pattern change it may differ from the prize that left). Once per listing.
    function _vacate(uint256 listingId) internal {
        uint256 idx = _liveIndex[listingId];
        if (idx == 0) return;
        uint256 lastId = _live[_live.length - 1];
        _live[idx - 1] = lastId;
        _liveIndex[lastId] = idx;
        _live.pop();
        delete _liveIndex[listingId];
        Item storage it = items[listingId];
        _owed.push(it.row);
        uint256 want = rowAt(it.row);
        // owed at today's cost: the prize's own cost if it was listed at today's mint fee and the row still asks for the
        // same backing, otherwise priced again (the pattern or Shapes' fee changed since it was listed)
        if (want == it.backing && listingId >= _feeFrom) {
            replacementsOwed += it.cost;
        } else {
            (uint256 c,) = poolOwner.prizeCost(want);
            replacementsOwed += c;
        }
    }

    /// @dev Books a Shape the pool owner burned for its backing: the mint fee is written off.
    function _burnBook(uint256 listingId) internal {
        Item memory it = items[listingId];
        inventoryBacking -= it.backing;
        inventoryCost -= it.cost;
        prizeExpense += it.cost - it.backing;
        delete items[listingId];
    }

    // ------------------------------------------------------------------ inventory

    /// @dev True when Shapes may be listed now: always before activation (nobody is buying) or below the admission
    ///      fill; otherwise when the window has passed since the last inventory change, or `listBatch` rows are waiting
    ///      and FWA has no inventory cooldown. Every FWA inventory change invalidates in-flight purchase quotes and
    ///      restarts FWA's cooldown (read live), so the window is at least six cooldowns: purchases stay open at least
    ///      five sixths of the time whatever FWA sets.
    function _maintenanceDue() internal view returns (bool) {
        uint256 live = _liveRows();
        if (!activated || live * BPS < settings.minLiveBps * boardSize) return true;
        uint256 cooldown = factory.inventoryChangeCooldown();
        uint256 interval = settings.maintenanceInterval;
        if (cooldown * 6 > interval) interval = cooldown * 6;
        if (block.timestamp >= lastMaintenanceAt + interval) return true;
        return cooldown == 0 && boardSize - live >= listBatch;
    }

    /// @dev Rows in play with a live listing.
    function _liveRows() internal view returns (uint256) {
        return boardSize - _owed.length;
    }

    /// @dev Grows the board by the rows the collection NFTs are waiting for (`rowsShort`, less rows already owed, at
    ///      most `MAX_GROWTH_STEP` at a time) when the vault's general bucket can fund them on top of the game's own
    ///      capital need. The rows are then listed like replacements.
    function _maybeGrow() internal returns (uint256) {
        if (!activated) return 0;
        uint256 rows = poolOwner.rowsShort();
        uint256 owed = _owed.length;
        if (rows <= owed) return 0;
        rows -= owed;
        if (rows > MAX_GROWTH_STEP) rows = MAX_GROWTH_STEP;
        if (vault.generalBalance() < rows * rowCost + capitalNeed()) return 0;
        _grow(boardSize + rows);
        return 1;
    }

    function _grow(uint256 to) internal {
        uint256 from = boardSize;
        uint256 cost;
        for (uint256 r = from; r < to; ++r) {
            (uint256 c,) = poolOwner.prizeCost(rowAt(r));
            cost += c;
            _owed.push(r);
        }
        emit BoardGrown(from, to, cost);
        replacementsOwed += cost;
        rowCost = cost / (to - from);
        boardSize = to;
    }

    /// @dev Mints and lists Shapes for rows in play without a live listing, while cash covers them. Once players
    ///      can buy, it lists only when no request is unsettled, even below the admission fill (purchases are then
    ///      closed, so the wait is until requests in flight settle or expire): FWA stages a listing made while requests
    ///      are unsettled and activates it in a batch just before a later request settles, which moves that request's
    ///      fee after it was quoted and can refund it.
    function _restock() internal returns (uint256 count) {
        if (activated && pool().unsettledAcquisitionCount() != 0) return 0;
        uint256 maxList = maxPerCall; // sized for EIP-7825's per-transaction gas cap
        IPoolOwnerGame.Prize[] memory prizes = new IPoolOwnerGame.Prize[](maxList);
        Item[] memory made = new Item[](maxList);
        uint256 spent;
        uint256 markup = markupBps;
        uint256 ops = opsBps;
        lastOpsBps = ops;
        for (uint256 o = _owed.length; o != 0 && count < maxList; --o) {
            uint256 r = _owed[o - 1];
            uint256 backing = rowAt(r);
            Item memory it;
            (uint256 cost, bool isPack) = poolOwner.prizeCost(backing);
            if (cash() < spent + cost) break;
            _owed.pop();
            spent += cost;
            it.cost = uint72(cost);
            it.backing = uint72(backing);
            it.row = uint24(r);
            it.markupBps = uint16(markup);
            it.opsBps = uint16(ops);
            it.isPack = isPack;
            inventoryBacking += backing;
            inventoryCost += cost;
            replacementsOwed = replacementsOwed > cost ? replacementsOwed - cost : 0;
            if (cost > maxItemCost) maxItemCost = cost;
            prizes[count] = IPoolOwnerGame.Prize(backing, cost * (BPS + markup) / BPS);
            made[count] = it;
            ++count;
        }
        if (count == 0) return 0;
        assembly ("memory-safe") {
            mstore(prizes, count)
        }
        (uint256[] memory ids, uint256[] memory tokenIds) = poolOwner.mintAndList{value: spent}(prizes);
        for (uint256 i; i < ids.length; ++i) {
            Item memory it = made[i];
            it.tokenId = uint48(tokenIds[i]);
            items[ids[i]] = it;
            _liveIndex[ids[i]] = _live.length + 1;
            _live.push(ids[i]);
            emit Listed(ids[i], it.row, prizes[i].price);
        }
    }

    /// @dev Retirement: withdraws up to MAX_LIST_BATCH prize listings FWA still holds as Active or Staged; the pool
    ///      owner burns or redeems them and returns their backing here.
    function _withdrawSome(IFWAPool p) internal returns (uint256 n) {
        uint256[] memory ids = new uint256[](MAX_LIST_BATCH);
        for (uint256 i = _live.length; i != 0 && n < MAX_LIST_BATCH; --i) {
            uint256 id = _live[i - 1];
            if (_withdrawableListing(p, id)) ids[n++] = id;
        }
        if (n == 0) return 0;
        assembly ("memory-safe") {
            mstore(ids, n)
        }
        for (uint256 i; i < n; ++i) {
            _vacate(ids[i]);
        }
        poolOwner.withdrawShapes(ids);
        for (uint256 i; i < n; ++i) {
            _burnBook(ids[i]);
        }
    }

    function _withdrawable(IFWAPool p) internal view returns (uint256 n) {
        for (uint256 i; i < _live.length; ++i) {
            if (_withdrawableListing(p, _live[i])) ++n;
        }
    }

    function _withdrawableListing(IFWAPool p, uint256 id) internal view returns (bool) {
        (,,,,,,, IFWAPool.ListingStatus st) = p.listings(id);
        return st == IFWAPool.ListingStatus.Active || st == IFWAPool.ListingStatus.Staged;
    }

    // ------------------------------------------------------------------ views

    function liveCount() external view returns (uint256) {
        return _live.length;
    }

    function liveAt(uint256 i) external view returns (uint256) {
        return _live[i];
    }

    function openCount() external view returns (uint256) {
        return _open.length;
    }

    /// @notice Rows in play without a live listing (owed a prize).
    function owedCount() external view returns (uint256) {
        return _owed.length;
    }

    // ------------------------------------------------------------------ board views

    /// @notice The backing row `r` asks for under the current pattern.
    function rowAt(uint256 r) public view returns (uint256) {
        return _pattern[r % _pattern.length];
    }

    function patternLength() external view returns (uint256) {
        return _pattern.length;
    }

    function keeperParams() external view returns (KeeperParams memory) {
        return _keeper;
    }

    // ------------------------------------------------------------------ governance

    /// @notice Replaces the board's pattern. It applies to each row the next time that row is listed (after its prize
    ///         is won, or when the row is new): prizes already listed stay until they are won. Every backing must be a
    ///         prize the pool owner can mint, and the operating reserve must still cover the largest.
    function setPattern(uint256[] calldata pattern) external onlyOwner {
        _setPattern(pattern);
        _setSettings(settings); // the reserve must still cover the largest prize
        _recountOwed(); // rows already owed are listed at the new backings
    }

    /// @dev Recounts what the owed rows will cost at today's backings and mint fee (after a pattern change, or when
    ///      Shapes' mint fee changes). One prize cost per owed row.
    function _recountOwed() internal {
        owedFee = poolOwner.mintFee();
        IFWAPool p = pool();
        if (address(p) != address(0)) _feeFrom = p.nextListingId();
        uint256 owed;
        for (uint256 j; j < _owed.length; ++j) {
            (uint256 c,) = poolOwner.prizeCost(rowAt(_owed[j]));
            owed += c;
        }
        replacementsOwed = owed;
    }

    /// @notice Grows the board to `to` rows (never shrinks), at most `MAX_GROWTH_STEP` rows a call, when the vault can
    ///         fund them on top of the game's capital need. The rows are listed like replacements.
    function setBoardSize(uint256 to) external onlyOwner {
        if (to <= boardSize || to - boardSize > MAX_GROWTH_STEP || retiring) revert OutOfBounds();
        uint256 cost;
        for (uint256 r = boardSize; r < to; ++r) {
            (uint256 c,) = poolOwner.prizeCost(rowAt(r));
            cost += c;
        }
        if (vault.generalBalance() < cost + capitalNeed()) revert OutOfBounds();
        _grow(to);
    }

    /// @notice Markup and keeper allowance rate, each 0-100%; frozen into each prize when it is listed.
    function setPricing(uint256 markupBps_, uint256 opsBps_) external onlyOwner {
        _setPricing(markupBps_, opsBps_);
    }

    /// @notice The replacement trigger, the most prizes one maintenance call lists and the most requests one call books:
    ///         `listBatch` 1-20, `maxPerCall` 1-10, `bookPerCall` 1-20 (every call at the ceilings fits EIP-7825's gas
    ///         cap on a board of four-Shape Packs, the heaviest a pattern may hold: CollectionPoolOwner.MAX_PACK_SHAPES).
    function setBoardParams(uint256 listBatch_, uint256 maxPerCall_, uint256 bookPerCall_) external onlyOwner {
        _setBoardParams(listBatch_, maxPerCall_, bookPerCall_);
    }

    /// @notice Keeper pay: the gas-price cap, overhead, flat fee and pay delay. Payment never exceeds the allowance.
    function setKeeperParams(KeeperParams calldata k) external onlyOwner {
        if (k.flatFee > 0.1 ether || k.payDelay > 1 hours) revert OutOfBounds();
        _keeper = k;
        emit KeeperParamsSet(k);
    }

    /// @notice Capital and admission settings, within the bounds below.
    function setSettings(Settings calldata s) external onlyOwner {
        _setSettings(s);
        if (activated && !retiring) _admit();
    }

    function _setSettings(Settings memory s) internal {
        if (
            s.reserveTarget > MAX_RESERVE_TARGET || s.maintenanceInterval > MAX_MAINTENANCE_INTERVAL
                || s.minLiveBps > BPS || s.maxOutstanding == 0 || s.maxOutstanding > 10_000 || s.maxEdgeBps > BPS
                || s.maxCooldown > MAX_COOLDOWN || s.minDistribution > 100 ether
                || s.continuityShareBps > MAX_CONTINUITY_SHARE_BPS || s.reserveTarget < maxBacking
        ) revert OutOfBounds();
        settings = s;
        if (s.maxEdgeBps > bookingEdgeBps) bookingEdgeBps = s.maxEdgeBps;
        emit SettingsSet(s);
    }

    function _setPattern(uint256[] memory pattern) internal {
        uint256 n = pattern.length;
        if (n == 0 || n > MAX_PATTERN) revert OutOfBounds();
        delete _pattern;
        uint256 max;
        for (uint256 i; i < n; ++i) {
            uint256 b = pattern[i];
            poolOwner.prizeCost(b); // reverts unless the pool owner can mint a prize of this backing
            if (b > max) max = b;
            _pattern.push(b);
        }
        maxBacking = max;
        emit PatternSet(n, max);
    }

    function _setPricing(uint256 m, uint256 o) internal {
        if (m > MAX_MARKUP_BPS || o > MAX_OPS_BPS) revert OutOfBounds();
        markupBps = m;
        opsBps = o;
        emit PricingSet(m, o);
    }

    function _setBoardParams(uint256 b, uint256 m, uint256 k) internal {
        if (b == 0 || b > 20 || m == 0 || m > MAX_PER_CALL || k == 0 || k > MAX_BOOK_PER_CALL) revert OutOfBounds();
        listBatch = b;
        maxPerCall = m;
        bookPerCall = k;
        emit BoardParamsSet(b, m, k);
    }
}
