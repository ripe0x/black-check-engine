// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Governed} from "../core/Governed.sol";

interface ISwapTransferGate {
    function allowSwapTransfer(int256 coinDelta) external;
}

/// @title CollectionHook
/// @notice Uniswap v4 hook of the ETH / collection-coin pool. Every swap pays a fee in ETH, taken straight to the
///         fee recipient: the FundingVault at launch (trading fees fund collection inventory and game capital). Only the
///         MigrationAuthority changes it, after its 72-hour public notice (a migration successor, or a recipient the
///         owner proposed), or at once into the sunset successor, which burns everything. It records the pool price at the first swap of
///         each block (`blockOpenPrice`), which the CollectionBurner reads to refuse same-block
///         manipulation. After every swap it allows the coin side of that swap across the PoolManager, which the
///         coin's transfer restriction requires. It holds nothing.
/// @dev Fees, all in ETH (currency0):
///      - buy, exact input: `beforeSwap` takes the fee out of the ETH input;
///      - buy, exact output: `afterSwap` adds the fee to the ETH the swapper pays, `net × f / (1 − f)`, so it is `f` of
///        the gross ETH paid, as on an exact-input buy;
///      - sell, exact input: `afterSwap` takes the fee out of the ETH output;
///      - sell, exact output: unsupported, reverts `ExactOutputSellUnsupported` (the fee could not be charged in ETH
///        without breaking the exact output).
///      Ordinary fees (`buyFeeBps`, `sellFeeBps`) are set by the owner and are capped here at `MAX_FEE_BPS` (10%). The
///      opening curve is immutable and time based: from the single initialisation, buys and sells pay
///      `max(ordinary fee, 69% − 1 point a minute)`, falling linearly (per second) to the ordinary fee by about minute
///      64 at a 5% fee. It exists only after the one initialisation, so it can never return. One exempt sender,
///      immutable (the CollectionBurner, which calls `PoolManager.swap` itself), pays nothing; `sender` is whoever
///      called `PoolManager.swap`, so a public router is never exempt and no function can exempt anyone else.
///      The $LAYER share (D90): once the opening curve is down to the ordinary fee, `layerBps` of each fee (1% at launch,
///      owner 0-5%) goes to the `layerTap` (which forwards it to artcoins' $LAYER burn router), the rest to the fee
///      recipient. The owner may point it at another tap.
///      Provenance: ripe0x/draw-shapes PR #9 `EngineHook` (MIT): the fee placement and block-open price follow it; the
///      opening fee is a fixed time-based curve.
contract CollectionHook is BaseHook, Governed {
    using StateLibrary for IPoolManager;

    uint256 internal constant BPS = 10_000;
    uint256 public constant MAX_FEE_BPS = 1_000;
    /// @notice The opening curve: 69% at launch, one percentage point (100 bps) less each minute, down to the ordinary
    ///         fee. Also the hook's absolute fee ceiling.
    uint256 public constant LAUNCH_FEE_BPS = 6_900;
    uint256 public constant LAUNCH_DECAY_BPS_PER_MINUTE = 100;
    int24 public constant TICK_SPACING = 200;

    address public immutable token;
    address public immutable launcher;
    /// @notice The MigrationAuthority: the only caller of `setFeeRecipient`.
    address public immutable migrator;
    /// @notice Where every trading fee goes.
    address public feeRecipient;
    /// @notice The only fee-exempt swap sender: the CollectionBurner.
    address public immutable exemptSender;

    uint256 public buyFeeBps;
    uint256 public sellFeeBps;
    /// @notice The $LAYER share of each fee after the opening curve (owner, at most `MAX_LAYER_BPS`), and where it goes
    ///         (owner; a contract that accepts ETH from the PoolManager, or swaps revert until it is changed).
    uint256 public constant MAX_LAYER_BPS = 500;
    uint256 public layerBps;
    address public layerTap;
    /// @notice When the pool was initialised (0 before): the start of the opening curve.
    uint64 public launchedAt;
    PoolId public poolId;
    uint160 internal _openPrice;
    uint64 internal _openBlock;

    event FeesSet(uint256 buyFeeBps, uint256 sellFeeBps);
    event FeeTaken(address indexed sender, bool buy, uint256 fee);
    event FeeRecipientSet(address recipient);
    event LayerSet(address tap, uint256 bps);
    event LayerShareTaken(uint256 amount);

    error NotLauncher();
    error NotMigrator();
    error AlreadyInitialized();
    error WrongPool();
    error ExactOutputSellUnsupported();

    constructor(
        IPoolManager manager,
        address admin_,
        address token_,
        address launcher_,
        address migrator_,
        address feeRecipient_,
        address exemptSender_,
        uint256 buyFeeBps_,
        uint256 sellFeeBps_,
        address layerTap_,
        uint256 layerBps_
    ) BaseHook(manager) Governed(admin_, false) {
        if (
            token_ == address(0) || launcher_ == address(0) || migrator_ == address(0) || feeRecipient_ == address(0)
                || exemptSender_ == address(0)
        ) revert ZeroAddress();
        token = token_;
        launcher = launcher_;
        migrator = migrator_;
        feeRecipient = feeRecipient_;
        exemptSender = exemptSender_;
        _setFees(buyFeeBps_, sellFeeBps_);
        _setLayer(layerTap_, layerBps_);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice True only for the CollectionBurner.
    function exempt(address sender) public view returns (bool) {
        return sender == exemptSender;
    }

    /// @notice Points every future trading fee at `recipient`. The MigrationAuthority only (after its notice, or into
    ///         the sunset successor). It must accept ETH from the PoolManager, or swaps revert until it is changed again.
    function setFeeRecipient(address recipient) external {
        if (msg.sender != migrator) revert NotMigrator();
        if (recipient == address(0)) revert ZeroAddress();
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    /// @notice Ordinary fees, each capped at 10%.
    function setFees(uint256 buyFeeBps_, uint256 sellFeeBps_) external onlyOwner {
        _setFees(buyFeeBps_, sellFeeBps_);
    }

    /// @notice The $LAYER tap and share (0-5% of each fee after the opening curve; 0 turns it off). A tap must be a
    ///         contract, or address(0) with a 0 share.
    function setLayer(address tap, uint256 bps) external onlyOwner {
        _setLayer(tap, bps);
    }

    function _setLayer(address tap, uint256 bps) internal {
        if (bps > MAX_LAYER_BPS || (tap == address(0) ? bps != 0 : tap.code.length == 0)) revert OutOfBounds();
        layerTap = tap;
        layerBps = bps;
        emit LayerSet(tap, bps);
    }

    /// @dev Pays a fee: the $LAYER share to the tap once the opening curve is down to this side's ordinary fee, the rest
    ///      to the fee recipient.
    function _payFee(address sender, bool isBuy, uint256 fee) internal {
        uint256 share;
        if (layerBps != 0 && curveBps() <= (isBuy ? buyFeeBps : sellFeeBps)) share = fee * layerBps / BPS;
        poolManager.take(Currency.wrap(address(0)), feeRecipient, fee - share);
        if (share != 0) {
            poolManager.take(Currency.wrap(address(0)), layerTap, share);
            emit LayerShareTaken(share);
        }
        emit FeeTaken(sender, isBuy, fee);
    }

    function _setFees(uint256 b, uint256 s) internal {
        if (b > MAX_FEE_BPS || s > MAX_FEE_BPS) revert OutOfBounds();
        buyFeeBps = b;
        sellFeeBps = s;
        emit FeesSet(b, s);
    }

    /// @notice Fee a non-exempt sender pays now, in bps: the ordinary fee, or the opening curve while it is higher.
    function currentFeeBps(bool isBuy) public view returns (uint256) {
        uint256 base = isBuy ? buyFeeBps : sellFeeBps;
        uint256 curve = curveBps();
        return curve > base ? curve : base;
    }

    /// @notice The opening curve now, in bps: 69% at initialisation, 100 bps less a minute (pro rata per second), then
    ///         0. Before initialisation, 0.
    function curveBps() public view returns (uint256) {
        if (launchedAt == 0) return 0;
        uint256 drop = (block.timestamp - launchedAt) * LAUNCH_DECAY_BPS_PER_MINUTE / 60;
        return drop < LAUNCH_FEE_BPS ? LAUNCH_FEE_BPS - drop : 0;
    }

    /// @notice The opening curve for the site: the buy and sell fees now, and the seconds until both are back at the
    ///         ordinary fees (0 once they are).
    function openingFee() external view returns (uint256 buyBps, uint256 sellBps, uint256 secondsToBase) {
        buyBps = currentFeeBps(true);
        sellBps = currentFeeBps(false);
        uint256 base = buyFeeBps < sellFeeBps ? buyFeeBps : sellFeeBps;
        uint256 curve = curveBps();
        if (curve > base) secondsToBase = ((curve - base) * 60 + LAUNCH_DECAY_BPS_PER_MINUTE - 1) / LAUNCH_DECAY_BPS_PER_MINUTE;
    }

    /// @notice The pool price before the first swap of this block, and the price now (`sqrtPriceX96`, coin per ETH).
    function blockOpenPrice() external view returns (uint160 open, uint160 current) {
        (current,,,) = poolManager.getSlot0(poolId);
        open = _openBlock == block.number ? _openPrice : current;
    }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (sender != launcher) revert NotLauncher();
        if (launchedAt != 0) revert AlreadyInitialized();
        if (
            !key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != token || key.fee != 0
                || key.tickSpacing != TICK_SPACING
        ) revert WrongPool();
        launchedAt = uint64(block.timestamp);
        poolId = key.toId();
        return BaseHook.beforeInitialize.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (_openBlock != block.number) {
            (_openPrice,,,) = poolManager.getSlot0(poolId);
            _openBlock = uint64(block.number);
        }
        bool exactIn = params.amountSpecified < 0;
        if (!params.zeroForOne && !exactIn) revert ExactOutputSellUnsupported();
        uint256 feeBps = sender == exemptSender ? 0 : currentFeeBps(params.zeroForOne);
        if (feeBps > LAUNCH_FEE_BPS) feeBps = LAUNCH_FEE_BPS; // unreachable; defence in depth
        assembly ("memory-safe") {
            tstore(0, add(feeBps, 1))
        }
        if (!params.zeroForOne || !exactIn) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        // Buy with exact ETH input: the fee is part of the input; the rest is swapped.
        uint256 fee = uint256(-params.amountSpecified) * feeBps / BPS;
        if (fee != 0) _payFee(sender, true, fee);
        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    function _afterSwap(address sender, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        uint256 feeBps;
        assembly ("memory-safe") {
            feeBps := sub(tload(0), 1)
            tstore(0, 0)
        }
        bool exactIn = params.amountSpecified < 0;
        uint256 fee;
        if (params.zeroForOne && !exactIn) {
            // Buy with exact coin output: the fee is added to the ETH paid, `f` of the gross (net × f / (1 − f)), as
            // on an exact-input buy, so exact output cannot be used to pay less during the curve.
            fee = uint256(int256(-delta.amount0())) * feeBps / (BPS - feeBps);
        } else if (!params.zeroForOne && exactIn) {
            // Sell with exact coin input: the fee comes out of the ETH output.
            fee = uint256(int256(delta.amount0())) * feeBps / BPS;
        }
        if (fee != 0) _payFee(sender, params.zeroForOne, fee);
        // the coin side of this swap may now cross the PoolManager while the coin is restricted; the fee is
        // all ETH, so the coin delta is exactly what the trader settles (negative) or takes (positive)
        ISwapTransferGate(token).allowSwapTransfer(delta.amount1());
        return (BaseHook.afterSwap.selector, int128(int256(fee)));
    }
}
