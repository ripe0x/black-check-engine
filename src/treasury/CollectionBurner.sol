// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {Governed} from "../core/Governed.sol";
import {IFWAPool} from "../interfaces/IFWA.sol";
import {ICollectionGame, IBurnable, IHookPrice, ICollectionPoolOwner} from "../interfaces/ICollectionGames.sol";

interface IBurnerPoolOwner {
    function pool() external view returns (IFWAPool);
}

/// @title CollectionBurner
/// @notice Holds ETH irrevocably committed to buybacks of the coin and spends it buying the coin on its v4 pool,
///         burning every token it buys in the same call. Three balances:
///         - `reserve`: the milestone share (`milestoneBps`) of every game surplus, locked until a win releases part of
///           it (`release`, verified from FWA's own records, no owner involved): a big prize (listed at
///           `bigPrizeWei` or more) releases `bigPrizeBps` of it, an Ape exit `firstExitBps`, and a second Ape exit
///           within `exitWindow` of the last one the rest; after the game has retired, `releaseRetired` releases all;
///         - milestone: released reserve, spent first, at the burst cadence;
///         - ongoing: the rest of the game's surplus, the sunset successor's proceeds, any donation.
///         `process` (anyone, reimbursed) buys one slice. The cadence follows play (`n` = FWA draws issued since the
///         last slice): an ongoing slice is `baseSliceWei + perDrawWei × n + backlogBps` of the bucket (so a backlog,
///         such as the vault's fee overflow, is spent too) and may run `idleSpacing × h / (h + n)`
///         after the last (`h` = `drawsToHalve`), never sooner than `minSpacing`; milestone ETH goes at `maxSliceWei`
///         every `minSpacing`, and the first slice after a release may run at once. Each slice may move the price at
///         most `maxImpactBps` and does not start if the price has already moved more than `maxDeviationBps` against
///         the buyer since the block opened (the hook records the opening price). `minOut` can only tighten these.
///         Hard bounds no owner can pass: a slice at most 1 ETH, spacing at least 10 minutes, impact at most 5%,
///         deviation at most 3%.
/// @dev The burner calls `PoolManager.swap` itself, so it is its own fee-exempt sender at the hook; no router and no
///      other contract can borrow that exemption. There is no outflow besides the swap and the keeper's reimbursement:
///      bought tokens are burned before the call returns, and unspent ETH stays in its bucket. The keeper that runs a
///      slice is reimbursed from that slice (the game's keeper formula, `quoteTip`, at most `MAX_TIP_BPS` of it).
///      Provenance: ripe0x/draw-shapes PR #9 `Buyback` and `EngineBuyer` (MIT), merged. The milestone reserve is a
///      balance in this contract (`reserve`), released by the same immutable win trigger.
contract CollectionBurner is IUnlockCallback, ReentrancyGuard, Governed {
    using StateLibrary for IPoolManager;

    uint256 internal constant BPS = 10_000;
    int24 internal constant TICK_SPACING = 200;
    uint256 public constant MAX_SLICE_WEI = 1 ether;
    uint256 public constant MIN_SPACING = 10 minutes;
    uint256 public constant MAX_SPACING = 30 days;
    uint256 public constant MAX_IMPACT_BPS = 500;
    uint256 public constant MAX_DEVIATION_BPS = 300;
    uint256 public constant MAX_EXIT_WINDOW = 7 days;
    uint256 public constant MIN_EXIT_BPS = 1_000;
    /// @notice The keeper reimbursement for a slice is at most this share of the ETH the slice spent.
    uint256 public constant MAX_TIP_BPS = 500;

    IPoolManager public immutable poolManager;
    address public immutable token;
    address public hook;
    /// @notice The game: the source of surplus (split into reserve and ongoing) and of the keeper formula.
    ICollectionGame public game;
    /// @notice The pool owner, whose FWA records verify a delivered collection win.
    address public poolOwner;

    /// @notice How fast the burner buys (owner, within the hard bounds).
    struct Cadence {
        uint256 baseSliceWei; // an ongoing slice with no draws since the last
        uint256 perDrawWei; // added per FWA draw issued since the last slice
        uint256 backlogBps; // added: this share of the ongoing bucket, so a backlog (fee overflow) is spent
        uint256 maxSliceWei; // the largest slice, and every milestone slice
        uint256 idleSpacing; // spacing with no draws
        uint256 minSpacing; // the shortest spacing, and the milestone cadence
        uint256 drawsToHalve; // draws that halve the spacing
        uint256 maxImpactBps; // the most one slice may move the price
        uint256 maxDeviationBps; // price move since the block opened that stops a slice
    }

    /// @notice How much of the milestone reserve each win releases (owner; every release still ends in buybacks, so
    ///         these change only the timing).
    struct Tiers {
        uint256 bigPrizeWei; // a Shape or Pack listed at this price or more is a big prize
        uint256 bigPrizeBps; // of the reserve, released by a big prize
        uint256 firstExitBps; // of the reserve, released by an Ape exit
        uint256 exitWindow; // a second Ape exit within this of the last releases the rest
    }

    Cadence internal _cadence;
    Tiers internal _tiers;
    /// @notice Share of each game surplus locked in the milestone reserve (the rest is ongoing).
    uint256 public milestoneBps;
    uint256 public lastRunAt;
    /// @notice FWA's issued-draw sequence at the last slice (the cadence counts draws since).
    uint256 public lastRunSeq;
    /// @notice When the last Ape exit released reserve (0: none yet).
    uint256 public lastExitAt;

    uint256 public reserve;
    uint256 public ongoingBalance;
    uint256 public milestoneBalance;
    uint256 public reserveIn;
    uint256 public ongoingIn;
    uint256 public milestoneIn;
    uint256 public ongoingSpent;
    uint256 public milestoneSpent;
    uint256 public ongoingBurned;
    uint256 public milestoneBurned;
    uint256 public purchases;
    uint256 public releases;
    /// @notice Releases for Ape exits (the rest of `releases` are big prizes).
    uint256 public exitReleases;
    /// @notice Keeper reimbursements paid out of the buckets (ongoing and milestone together).
    uint256 public keeperPaid;
    mapping(uint256 listingId => bool) public released;

    event SurplusReceived(uint256 toReserve, uint256 toOngoing);
    event OngoingReceived(address indexed from, uint256 amount);
    event Released(uint256 indexed listingId, address indexed winner, uint256 amount);
    event Bought(bool milestone, uint256 ethSpent, uint256 tokensBurned);
    event KeeperPaid(address indexed keeper, bool milestone, uint256 amount);
    event CadenceSet(Cadence cadence);
    event TiersSet(Tiers tiers);
    event MilestoneBpsSet(uint256 bps);

    error NoWork();
    error TooSoon();
    error PriceMoved();
    error InsufficientOutput();
    error NotPoolManager();
    error NotQualifying();
    error AlreadyReleased();
    error NotRetired();

    constructor(
        address admin_,
        IPoolManager manager,
        address token_,
        Cadence memory cadence_,
        Tiers memory tiers_,
        uint256 milestoneBps_
    ) Governed(admin_, true) {
        if (address(manager) == address(0) || token_ == address(0)) revert ZeroAddress();
        poolManager = manager;
        token = token_;
        _setCadence(cadence_);
        _setTiers(tiers_);
        _setMilestoneBps(milestoneBps_);
    }

    /// @notice One-shot wiring by the deployer: the hook (pool key), the game and the pool owner.
    function wire(address hook_, address game_, address poolOwner_) external onlyWiring {
        if (hook_ == address(0) || game_.code.length == 0 || poolOwner_.code.length == 0) revert ZeroAddress();
        hook = hook_;
        game = ICollectionGame(game_);
        poolOwner = poolOwner_;
    }

    /// @notice The game's surplus is split: `milestoneBps` into the locked reserve, the rest ongoing. ETH from anyone
    ///         else (the sunset successor, a donation) is ongoing.
    receive() external payable {
        if (msg.sender == address(game)) {
            uint256 m = msg.value * milestoneBps / BPS;
            reserve += m;
            reserveIn += m;
            ongoingBalance += msg.value - m;
            ongoingIn += msg.value - m;
            emit SurplusReceived(m, msg.value - m);
        } else {
            ongoingBalance += msg.value;
            ongoingIn += msg.value;
            emit OngoingReceived(msg.sender, msg.value);
        }
    }

    // ------------------------------------------------------------------ milestone reserve

    /// @notice What `listingId` would release now, as a share of the reserve in bps (0: it does not qualify). It
    ///         qualifies when FWA shows it `Settled` to a purchaser other than the pool owner (a delivered win), it has
    ///         not released before, and it is either one of the pool owner's collection listings (an Ape exit) or a
    ///         prize listed at `bigPrizeWei` or more. Only the pool owner lists in its pool.
    function releaseBps(uint256 listingId) public view returns (uint256) {
        address po = poolOwner;
        if (released[listingId]) return 0;
        IFWAPool pl = IBurnerPoolOwner(po).pool();
        (,, address purchaser,,, uint256 price,, IFWAPool.ListingStatus st) = pl.listings(listingId);
        // a "win" by the pool itself leaves the NFT where it was: no release (the purchase gate refuses it too)
        if (st != IFWAPool.ListingStatus.Settled || purchaser == address(0) || purchaser == po || purchaser == address(pl)) {
            return 0;
        }
        Tiers memory t = _tiers;
        if (ICollectionPoolOwner(po).isCollectionListing(listingId)) {
            return lastExitAt != 0 && block.timestamp <= lastExitAt + t.exitWindow ? BPS : t.firstExitBps;
        }
        return price >= t.bigPrizeWei ? t.bigPrizeBps : 0;
    }

    /// @notice True when `listingId` releases part of the reserve now.
    function qualifies(uint256 listingId) public view returns (bool) {
        return releaseBps(listingId) != 0;
    }

    /// @notice Releases the tier's share of the reserve into the milestone bucket for a delivered win, and lets the
    ///         next slice run at once. Anyone (the game calls it when it books a qualifying win). A small prize, a
    ///         refunded or pending delivery, or a withdrawn listing never qualifies; each listing releases at most once.
    function release(uint256 listingId) external nonReentrant returns (uint256 amount) {
        if (released[listingId]) revert AlreadyReleased();
        uint256 bps = releaseBps(listingId);
        if (bps == 0) revert NotQualifying();
        released[listingId] = true;
        if (ICollectionPoolOwner(poolOwner).isCollectionListing(listingId)) {
            lastExitAt = block.timestamp;
            ++exitReleases;
        }
        amount = reserve * bps / BPS;
        reserve -= amount;
        milestoneBalance += amount;
        milestoneIn += amount;
        ++releases;
        if (amount != 0) lastRunAt = 0; // the first slice of a release may run at once
        (,, address purchaser,,,,,) = IBurnerPoolOwner(poolOwner).pool().listings(listingId);
        emit Released(listingId, purchaser, amount);
    }

    /// @notice Once the game has retired (it migrated or ended into the sunset), no win can come: releases the reserve
    ///         into the milestone bucket. Anyone; repeatable.
    function releaseRetired() external nonReentrant returns (uint256 amount) {
        if (!game.retired()) revert NotRetired();
        amount = reserve;
        if (amount == 0) return 0;
        reserve = 0;
        milestoneBalance += amount;
        milestoneIn += amount;
        emit Released(0, address(0), amount);
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });
    }

    /// @notice FWA draws issued since the last slice.
    function drawsSinceLastRun() public view returns (uint256) {
        IFWAPool p = IBurnerPoolOwner(poolOwner).pool();
        if (address(p) == address(0)) return 0;
        uint256 seq = p.lastIssuedSequence();
        return seq > lastRunSeq ? seq - lastRunSeq : 0;
    }

    /// @notice The next slice and the earliest time it may run: milestone ETH first, at `maxSliceWei` every
    ///         `minSpacing`; otherwise ongoing, sized and spaced by the draws since the last slice.
    function nextSlice() public view returns (uint256 amount, bool milestone, uint256 runAt) {
        Cadence memory c = _cadence;
        milestone = milestoneBalance != 0;
        uint256 spacing = c.minSpacing;
        if (milestone) {
            amount = milestoneBalance;
            if (amount > c.maxSliceWei) amount = c.maxSliceWei;
        } else {
            uint256 n = drawsSinceLastRun();
            amount = c.baseSliceWei + c.perDrawWei * n + ongoingBalance * c.backlogBps / BPS;
            if (amount > c.maxSliceWei) amount = c.maxSliceWei;
            if (amount > ongoingBalance) amount = ongoingBalance;
            uint256 s = c.idleSpacing * c.drawsToHalve / (c.drawsToHalve + n);
            if (s > spacing) spacing = s;
        }
        runAt = lastRunAt + spacing;
    }

    /// @notice False when the price has moved more than `maxDeviationBps` against the buyer since the block opened.
    function priceOk() public view returns (bool) {
        (uint160 open, uint160 current) = IHookPrice(hook).blockOpenPrice();
        // Coin per ETH falls when someone buys the coin ahead of us.
        uint256 floor = uint256(open) * FPM.sqrt((BPS - _cadence.maxDeviationBps) * 1e18 / BPS) / 1e9;
        return current >= floor;
    }

    /// @notice Buys one slice of the coin and burns all of it. Anyone may call; the caller is reimbursed from the slice.
    function process(uint256 minOut) external nonReentrant returns (uint256 out) {
        uint256 gasStart = gasleft();
        (uint256 amount, bool milestone, uint256 runAt) = nextSlice();
        if (block.timestamp < runAt) revert TooSoon();
        if (amount == 0) revert NoWork();
        if (!priceOk()) revert PriceMoved();
        (uint160 price,,,) = poolManager.getSlot0(poolKey().toId());
        uint160 limit = uint160(uint256(price) * FPM.sqrt((BPS - _cadence.maxImpactBps) * 1e18 / BPS) / 1e9);
        if (limit <= TickMath.MIN_SQRT_PRICE) limit = TickMath.MIN_SQRT_PRICE + 1;
        uint256 spent;
        (out, spent) = abi.decode(poolManager.unlock(abi.encode(amount, limit)), (uint256, uint256));
        if (out == 0 || out < minOut) revert InsufficientOutput();
        if (milestone) {
            milestoneBalance -= spent;
            milestoneSpent += spent;
            milestoneBurned += out;
        } else {
            ongoingBalance -= spent;
            ongoingSpent += spent;
            ongoingBurned += out;
        }
        ++purchases;
        IBurnable(token).burn(out);
        emit Bought(milestone, spent, out);
        lastRunAt = block.timestamp;
        IFWAPool p = IBurnerPoolOwner(poolOwner).pool();
        if (address(p) != address(0)) lastRunSeq = p.lastIssuedSequence();
        // the keeper is reimbursed from the bucket this slice came from, at the game's keeper formula
        uint256 tip = game.quoteTip(gasStart - gasleft());
        uint256 cap = spent * MAX_TIP_BPS / BPS;
        if (tip > cap) tip = cap;
        uint256 left = milestone ? milestoneBalance : ongoingBalance;
        if (tip > left) tip = left;
        if (tip != 0) {
            if (milestone) milestoneBalance -= tip;
            else ongoingBalance -= tip;
            keeperPaid += tip;
            emit KeeperPaid(msg.sender, milestone, tip);
            SafeTransferLib.forceSafeTransferETH(msg.sender, tip);
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint256 ethIn, uint160 limit) = abi.decode(data, (uint256, uint160));
        PoolKey memory key = poolKey();
        BalanceDelta d = poolManager.swap(
            key, SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: limit}), ""
        );
        uint256 spent = uint256(int256(-d.amount0()));
        uint256 out = uint256(int256(d.amount1()));
        if (spent != 0) poolManager.settle{value: spent}();
        if (out != 0) poolManager.take(key.currency1, address(this), out);
        return abi.encode(out, spent);
    }

    /// @notice Total coins this contract has burned.
    function totalBurned() external view returns (uint256) {
        return ongoingBurned + milestoneBurned;
    }

    function cadence() external view returns (Cadence memory) {
        return _cadence;
    }

    function tiers() external view returns (Tiers memory) {
        return _tiers;
    }

    /// @notice The listed price from which a Shape or Pack win is a big prize (the game asks before releasing).
    function bigPrizeWei() external view returns (uint256) {
        return _tiers.bigPrizeWei;
    }

    /// @notice The buyback cadence, within the hard bounds (slice at most 1 ETH, spacing at least 10 minutes and at
    ///         most 30 days, impact at most 5%, deviation at most 3%).
    function setCadence(Cadence calldata c) external onlyOwner {
        _setCadence(c);
    }

    function _setCadence(Cadence memory c) internal {
        if (
            c.maxSliceWei == 0 || c.maxSliceWei > MAX_SLICE_WEI || c.baseSliceWei == 0 || c.baseSliceWei > c.maxSliceWei
                || c.perDrawWei > c.maxSliceWei || c.backlogBps > 1_000 || c.minSpacing < MIN_SPACING || c.idleSpacing < c.minSpacing
                || c.idleSpacing > MAX_SPACING || c.drawsToHalve == 0 || c.drawsToHalve > 1e6 || c.maxImpactBps == 0
                || c.maxImpactBps > MAX_IMPACT_BPS || c.maxDeviationBps == 0 || c.maxDeviationBps > MAX_DEVIATION_BPS
        ) revert OutOfBounds();
        _cadence = c;
        emit CadenceSet(c);
    }

    /// @notice The milestone tiers: the big-prize share 0-100%, the Ape-exit share 10-100%, the exit window at most 7
    ///         days.
    function setTiers(Tiers calldata t) external onlyOwner {
        _setTiers(t);
    }

    function _setTiers(Tiers memory t) internal {
        // an Ape exit always releases at least 10%, so no setting (then a renounce) can lock the reserve for good
        if (
            t.bigPrizeWei == 0 || t.bigPrizeBps > BPS || t.firstExitBps < MIN_EXIT_BPS || t.firstExitBps > BPS
                || t.exitWindow > MAX_EXIT_WINDOW
        ) revert OutOfBounds();
        _tiers = t;
        emit TiersSet(t);
    }

    /// @notice Share of each future game surplus locked in the milestone reserve, 0-100%.
    function setMilestoneBps(uint256 bps) external onlyOwner {
        _setMilestoneBps(bps);
    }

    function _setMilestoneBps(uint256 bps) internal {
        if (bps > BPS) revert OutOfBounds();
        milestoneBps = bps;
        emit MilestoneBpsSet(bps);
    }
}
