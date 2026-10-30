// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

interface IBurnable {
    function burn(uint256 amount) external;
}

/// @title VenueLiquidity
/// @notice Opens the ETH / coin Uniswap v4 pool and permanently holds its protocol-owned liquidity. There is no
///         function that removes liquidity, collects or transfers anything out, and no owner: once launched the whole
///         coin supply is locked in the pool forever. The pool's LP fee is 0 (VenueHook's ETH fee is the only fee), so
///         the position earns nothing to collect.
/// @dev `launch()` (the deployer, once) initialises the pool at `startTick` (coin per ETH) and adds every coin
///      this contract holds as one single-sided position over `[TICK_LOWER, startTick)`: as buyers pay ETH the price
///      moves down through it and the position becomes ETH-paired. No ETH is needed and none is accepted (not payable),
///      so the price can never return above `startTick` and no ETH is ever placed where a seller or a withdrawal could
///      reach it. The coin left over by liquidity rounding (a few wei) is burned so total supply equals what the pool
///      holds plus what holders hold. Provenance: collection-games `ProtocolLiquidity` (MIT), without Governed: launch
///      is one-shot and gated to the immutable deployer, there is no owner and no sweep.
contract VenueLiquidity is IUnlockCallback, ReentrancyGuard {
    int24 public constant TICK_SPACING = 200;
    int24 public constant TICK_LOWER = -887_200;
    int24 public constant TICK_UPPER = 887_200;

    IPoolManager public immutable poolManager;
    address public immutable token;
    /// @notice The one address that wires the hook and opens the market. Set at construction, never changed; it cannot
    ///         withdraw liquidity or fees because no such function exists.
    address public immutable deployer;

    address public hook;
    bool public launched;
    /// @notice The opening price (coin per ETH), fixed at construction so the deployer chooses only when to open.
    int24 public immutable startTick;
    uint128 public coinLiquidity;

    event Launched(int24 startTick, uint256 coins, uint128 coinLiquidity);
    event HookSet(address hook);

    error AlreadyLaunched();
    error NotDeployer();
    error NotPoolManager();
    error ZeroAddress();
    error AlreadyWired();
    error NotWired();
    error BadTick();

    constructor(IPoolManager manager, address token_, int24 startTick_) {
        if (address(manager) == address(0) || token_ == address(0)) revert ZeroAddress();
        if (
            startTick_ % TICK_SPACING != 0 || startTick_ <= TICK_LOWER + TICK_SPACING
                || startTick_ >= TICK_UPPER - TICK_SPACING
        ) revert BadTick();
        poolManager = manager;
        token = token_;
        startTick = startTick_;
        deployer = msg.sender;
    }

    /// @notice One-shot wiring by the deployer: the hook, CREATE2-mined after this contract exists.
    function wire(address hook_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (hook != address(0)) revert AlreadyWired();
        if (hook_ == address(0)) revert ZeroAddress();
        hook = hook_;
        emit HookSet(hook_);
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

    /// @notice Opens the market at the constructor's `startTick`. Deployer, once. The opening valuation is
    ///         supply / (coins per ETH at `startTick`). Not payable: no ETH is seeded.
    function launch() external nonReentrant {
        if (msg.sender != deployer) revert NotDeployer();
        if (hook == address(0)) revert NotWired();
        if (launched) revert AlreadyLaunched();
        launched = true;
        uint160 price = TickMath.getSqrtPriceAtTick(startTick);
        poolManager.initialize(poolKey(), price);
        uint256 coins = SafeTransferLib.balanceOf(token, address(this));
        coinLiquidity = LiquidityAmounts.getLiquidityForAmount1(TickMath.getSqrtPriceAtTick(TICK_LOWER), price, coins);
        poolManager.unlock("");
        uint256 dust = SafeTransferLib.balanceOf(token, address(this));
        if (dust != 0) IBurnable(token).burn(dust);
        emit Launched(startTick, coins - dust, coinLiquidity);
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        PoolKey memory key = poolKey();
        (BalanceDelta d,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: startTick,
                liquidityDelta: int256(uint256(coinLiquidity)),
                salt: 0
            }),
            ""
        );
        // a position entirely below the current price holds only coins
        int256 tok = d.amount1();
        if (tok < 0) {
            poolManager.sync(key.currency1);
            SafeTransferLib.safeTransfer(token, address(poolManager), uint256(-tok));
            poolManager.settle();
        }
        return "";
    }
}
