// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface IFWAToken {
    function increaseTransferAllowance(uint256 amount) external;
    /// @notice True only while the token's `launch()` is executing — gates pool init + seed liquidity.
    function launching() external view returns (bool);
}

interface ITokenBuyer {
    function isBuying() external view returns (bool);
}

/// @title FWATokenHook - Uniswap V4 hook for the ETH/FWAToken pool
/// @notice Simplified single-token port of the team's TTTHook. Charges a flat 1% fee in BOTH
///         directions, routed to an owner-set fee wallet (buys: fee taken in FWAToken, swapped to ETH;
///         sells: fee taken in ETH). Pool init + seed-liquidity are gated on the FWAToken token's
///         transient `launching()` flag, so only the token's one-shot `launch()` can open the pool.
///         SELLS are always allowed. BUYS are gated: until the owner flips `externalBuysEnabled`,
///         only registered protocol buyers (`isPool`, normally `FWARewards`) may buy — so during
///         bootstrap FWAToken's price is driven purely by purchaser acquisitions, with no
///         external/speculative buy-ins.
contract FWATokenHook is BaseHook, Ownable {
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using SafeCast for uint256;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint128 private constant TOTAL_BIPS = 10_000;
    uint128 private constant FEE_BIPS = 100; // flat 1% both directions
    uint160 private constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Block the pool was initialized. 0 == not yet launched.
    uint64 public deploymentBlock;
    /// @notice The canonical FWAToken token this hook gates. Set once (before launch) so pool init binds
    ///         to the intended token: a foreign token reporting `launching()` can't squat the latch.
    address public token;
    /// @notice Owner-set destination for the 1% fee.
    address public feeAddress;
    /// @notice While false, only registered pools (`isPool`) may BUY (sells are always open). Flip on
    ///         to open the market to external/organic buyers once a acquisition-driven floor exists.
    bool public externalBuysEnabled;
    /// @notice Protocol reward modules allowed to buy FWAToken even while external buys are gated.
    ///         A mapping (not a single pointer) lets old and replacement modules coexist during a
    ///         migration: stragglers keep claiming through the old one while the new one trades.
    mapping(address => bool) public isPool;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event TokenSet(address token);
    event FeeAddressSet(address feeAddress);
    event ExternalBuysEnabledSet(bool enabled);
    event PoolSet(address pool, bool allowed);
    event PoolLaunched(bytes32 indexed poolId, uint256 deploymentBlock);
    event HookFee(bytes32 indexed id, address indexed sender, uint128 feeAmount0, uint128 feeAmount1);

    /// @notice Emitted on every external swap so indexers can track price and volume from the hook
    ///         alone, without also subscribing to the PoolManager's `Swap` event. `sqrtPriceX96` is
    ///         the pool price AFTER the swap; `ethAmount`/`tokenAmount` are the swap's currency0/
    ///         currency1 deltas (swapper's perspective: negative = paid in, positive = received out).
    event Trade(uint160 sqrtPriceX96, int128 ethAmount, int128 tokenAmount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error PoolAlreadyInitialized();
    error NotLaunching();
    error TokenAlreadySet();
    error ExactOutputNotAllowed();
    error ExternalBuysDisabled();
    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IPoolManager _poolManager, address _owner) BaseHook(_poolManager) {
        _initializeOwner(_owner);
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Bind this hook to its canonical FWAToken token. One-shot: settable only while unset, before
    ///         launch. Until it is set, `_beforeInitialize` rejects every pool, so the launch latch
    ///         can't be squatted by a foreign token that merely reports `launching()`.
    function setToken(address _token) external onlyOwner {
        if (_token == address(0)) revert ZeroAddress();
        if (token != address(0)) revert TokenAlreadySet();
        token = _token;
        emit TokenSet(_token);
    }

    function setFeeAddress(address fee) external onlyOwner {
        if (fee == address(0)) revert ZeroAddress();
        feeAddress = fee;
        emit FeeAddressSet(fee);
    }

    /// @notice Open the market to external/organic buyers. Until then only registered pools may buy.
    function setExternalBuysEnabled(bool enabled) external onlyOwner {
        externalBuysEnabled = enabled;
        emit ExternalBuysEnabledSet(enabled);
    }

    /// @notice Register/deregister a protocol buyer allowed while external buys are gated.
    ///         Registered pools must call `PoolManager.swap` directly (the gate checks the swap's
    ///         `sender`), which the rewards module does from its own `unlockCallback`.
    function setPool(address _pool, bool allowed) external onlyOwner {
        isPool[_pool] = allowed;
        emit PoolSet(_pool, allowed);
    }

    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                            HOOK PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /*//////////////////////////////////////////////////////////////
                            _beforeInitialize
    //////////////////////////////////////////////////////////////*/

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        require(key.currency0.isAddressZero(), "Only ETH/token pools are supported");
        // Bind the launch latch to the intended FWAToken token. A foreign token reporting `launching()`
        // can't consume `deploymentBlock`, and before `setToken` (`token == 0`) every init reverts.
        if (Currency.unwrap(key.currency1) != token) revert NotLaunching();
        if (!IFWAToken(token).launching()) revert NotLaunching();
        if (deploymentBlock != 0) revert PoolAlreadyInitialized();
        deploymentBlock = uint64(block.number);
        emit PoolLaunched(PoolId.unwrap(key.toId()), block.number);
        return BaseHook.beforeInitialize.selector;
    }

    /*//////////////////////////////////////////////////////////////
                           _afterAddLiquidity
    //////////////////////////////////////////////////////////////*/

    /// @notice Bumps the token's transient transfer allowance for what the LP just deposited so the
    ///         pool can pull FWAToken from the LPer through the transfer guard. Gated on the token's
    ///         `launching()` flag, so only the one-shot `launch()` seed can add FWAToken liquidity.
    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        if (!IFWAToken(Currency.unwrap(key.currency1)).launching()) revert NotLaunching();
        int128 amt1 = delta.amount1();
        if (amt1 < 0) {
            IFWAToken(Currency.unwrap(key.currency1)).increaseTransferAllowance(uint256(int256(-amt1)));
        }
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /*//////////////////////////////////////////////////////////////
                               _afterSwap
    //////////////////////////////////////////////////////////////*/

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        address tok = Currency.unwrap(key.currency1);
        // Skip fees on the hook's own internal token->ETH swap, or the token's own buyback.
        if (sender == address(this) || sender == tok) {
            return (BaseHook.afterSwap.selector, 0);
        }
        if (params.amountSpecified > 0) revert ExactOutputNotAllowed();

        // zeroForOne == true => ETH in / FWAToken out == BUY. false => SELL (always allowed). Buys are
        // gated until external buys are opened: while gated, only a registered FWA may buy, identified
        // by `sender` (FWA calls PoolManager.swap directly from its own unlockCallback, so sender is
        // the registered buyer itself). Its `isBuying` flag (set only across its own swap) is kept as
        // a handshake so a registered-but-idle module can never be ridden; the PoolManager lock makes
        // that window exclusive to the module's swap.
        if (params.zeroForOne && !externalBuysEnabled) {
            if (!isPool[sender] || !ITokenBuyer(sender).isBuying()) revert ExternalBuysDisabled();
        }

        bool specifiedTokenIs0 = (params.amountSpecified < 0 == params.zeroForOne);
        int128 swapAmount = specifiedTokenIs0 ? delta.amount1() : delta.amount0();
        if (swapAmount < 0) swapAmount = -swapAmount;

        int128 feeDelta;
        uint256 allowanceForRouter;
        if (params.zeroForOne) {
            feeDelta = _handleBuy(key, uint128(swapAmount), sender, tok);
            allowanceForRouter = uint256(uint128(swapAmount)) - uint256(uint128(feeDelta));
        } else {
            feeDelta = _handleSell(key, uint128(swapAmount), sender, tok);
            // Bump allowance so the pool can take FWAToken from the user as the swap input.
            allowanceForRouter = uint256(int256(-delta.amount1()));
        }

        if (allowanceForRouter > 0) IFWAToken(tok).increaseTransferAllowance(allowanceForRouter);

        // Self-contained price+volume feed for indexers (so listening to PoolManager is unnecessary).
        emit Trade(_getCurrentPrice(key), delta.amount0(), delta.amount1());

        return (BaseHook.afterSwap.selector, feeDelta);
    }

    /*//////////////////////////////////////////////////////////////
                            BUY / SELL HANDLERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Buy: take 1% of the FWAToken output as the fee, swap it to ETH, route all of it to feeAddress.
    function _handleBuy(PoolKey calldata key, uint128 swapAmount, address sender, address tok)
        internal
        returns (int128)
    {
        uint256 totalFee = uint256(swapAmount) * FEE_BIPS / TOTAL_BIPS;
        if (totalFee == 0) return 0;

        // Pool -> hook token fee take.
        IFWAToken(tok).increaseTransferAllowance(totalFee);
        poolManager.take(key.currency1, address(this), totalFee);
        emit HookFee(PoolId.unwrap(key.toId()), sender, 0, uint128(totalFee));

        uint256 ethReceived = _swapTokenToEth(key, totalFee);
        if (ethReceived > 0) SafeTransferLib.forceSafeTransferETH(feeAddress, ethReceived);

        return totalFee.toInt128();
    }

    /// @dev Sell: take 1% of the ETH proceeds as the fee, in ETH, routed to feeAddress.
    function _handleSell(PoolKey calldata key, uint128 swapAmount, address sender, address) internal returns (int128) {
        uint256 totalFee = uint256(swapAmount) * FEE_BIPS / TOTAL_BIPS;
        if (totalFee == 0) return 0;

        poolManager.take(key.currency0, address(this), totalFee);
        emit HookFee(PoolId.unwrap(key.toId()), sender, uint128(totalFee), 0);

        SafeTransferLib.forceSafeTransferETH(feeAddress, totalFee);
        return totalFee.toInt128();
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL SWAP
    //////////////////////////////////////////////////////////////*/

    /// @notice Swaps FWAToken held by the hook into ETH via the pool. Returns ETH received.
    function _swapTokenToEth(PoolKey memory key, uint256 amount) internal returns (uint256) {
        uint256 ethBefore = address(this).balance;
        BalanceDelta d = poolManager.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            ""
        );
        uint256 toSettle = uint256(int256(-d.amount1()));
        if (toSettle > 0) {
            IFWAToken(Currency.unwrap(key.currency1)).increaseTransferAllowance(toSettle);
        }
        key.currency1.settle(poolManager, address(this), toSettle, false);
        key.currency0.take(poolManager, address(this), uint256(int256(d.amount0())), false);
        return address(this).balance - ethBefore;
    }

    /// @notice Current pool price (post-swap when called from `_afterSwap`), read straight from
    ///         PoolManager state. Used to stamp the `Trade` event.
    function _getCurrentPrice(PoolKey calldata key) internal view returns (uint160) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        return sqrtPriceX96;
    }
}
