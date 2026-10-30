// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface IFundAcquisitions {
    function fundAcquisitions() external payable;
}

/// @title VenueHook
/// @notice Uniswap v4 hook of the ETH / coin pool. Every swap pays a flat fee in ETH (`feeBps`, fixed at construction),
///         taken to this hook; `forward()` (anyone) sends the collected ETH to the Engine's `fundAcquisitions`, which
///         credits its `acquisitionBudget`. The fee rate and the Engine are immutable: no owner, no setter, nobody can
///         change the rate or redirect the fees. The hook holds no coins and the pool's own LP fee is 0.
/// @dev Fees, all in ETH (currency0):
///      - buy, exact input: `beforeSwap` takes the fee out of the ETH input;
///      - buy, exact output: `afterSwap` adds the fee to the ETH paid, `net x f / (1 - f)`, so it is `f` of the gross
///        ETH paid, the same share an exact-input buy pays;
///      - sell, exact input: `afterSwap` takes the fee out of the ETH output;
///      - sell, exact output: reverts `ExactOutputSellUnsupported` (the fee could not be charged in ETH without
///        breaking the exact output).
///      Provenance: collection-games `CollectionHook` (MIT): fee placement kept; Governed, the migrator/fee-recipient
///      setter, the exempt sender, the per-side governed fees, the block-open price and the opening curve are all
///      dropped. The single curve-free fee makes transient storage unnecessary: `afterSwap` reads the immutable rate.
contract VenueHook is BaseHook {
    uint256 internal constant BPS = 10_000;
    /// @notice The fee rate ceiling; `feeBps` is bounded by it at construction. A hard upper limit, not a knob.
    uint256 public constant MAX_FEE_BPS = 1_000;
    int24 public constant TICK_SPACING = 200;

    address public immutable token;
    /// @notice The only address allowed to initialise the pool (VenueLiquidity), so nobody can open it at a bad price.
    address public immutable launcher;
    /// @notice Where collected ETH is forwarded; immutable, crediting the acquisition budget.
    IFundAcquisitions public immutable engine;
    /// @notice The flat fee charged on every swap, each way, in bps. Immutable.
    uint256 public immutable feeBps;

    event FeeTaken(address indexed sender, bool buy, uint256 fee);
    event Forwarded(uint256 amount);

    error ZeroAddress();
    error FeeTooHigh();
    error NotLauncher();
    error WrongPool();
    error ExactOutputSellUnsupported();
    error NothingToForward();

    constructor(IPoolManager manager, address token_, address launcher_, IFundAcquisitions engine_, uint256 feeBps_)
        BaseHook(manager)
    {
        if (token_ == address(0) || launcher_ == address(0) || address(engine_) == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        token = token_;
        launcher = launcher_;
        engine = engine_;
        feeBps = feeBps_;
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

    /// @notice Sends every ETH the hook holds to the Engine's `fundAcquisitions`, crediting the acquisition budget.
    ///         Permissionless: the recipient is immutable, so there is nothing to misdirect.
    function forward() external {
        uint256 bal = address(this).balance;
        if (bal == 0) revert NothingToForward();
        engine.fundAcquisitions{value: bal}();
        emit Forwarded(bal);
    }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        if (sender != launcher) revert NotLauncher();
        if (
            !key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != token || key.fee != 0
                || key.tickSpacing != TICK_SPACING
        ) revert WrongPool();
        return BaseHook.beforeInitialize.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool exactIn = params.amountSpecified < 0;
        if (!params.zeroForOne && !exactIn) revert ExactOutputSellUnsupported();
        if (!params.zeroForOne || !exactIn) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        // Buy with exact ETH input: the fee is part of the input; the rest is swapped.
        uint256 fee = uint256(-params.amountSpecified) * feeBps / BPS;
        if (fee != 0) {
            poolManager.take(Currency.wrap(address(0)), address(this), fee);
            emit FeeTaken(sender, true, fee);
        }
        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    function _afterSwap(address sender, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        bool exactIn = params.amountSpecified < 0;
        uint256 fee;
        if (params.zeroForOne && !exactIn) {
            // Buy with exact coin output: the fee is added to the ETH paid, `f` of the gross (net x f / (1 - f)), the
            // same share an exact-input buy pays, so exact output cannot be used to pay less.
            fee = uint256(int256(-delta.amount0())) * feeBps / (BPS - feeBps);
        } else if (!params.zeroForOne && exactIn) {
            // Sell with exact coin input: the fee comes out of the ETH output.
            fee = uint256(int256(delta.amount0())) * feeBps / BPS;
        }
        if (fee != 0) {
            poolManager.take(Currency.wrap(address(0)), address(this), fee);
            emit FeeTaken(sender, params.zeroForOne, fee);
        }
        return (BaseHook.afterSwap.selector, int128(int256(fee)));
    }

    receive() external payable {}
}
