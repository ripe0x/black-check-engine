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
import {Governed} from "../core/Governed.sol";
import {IBurnable} from "../interfaces/ICollectionGames.sol";

/// @title ProtocolLiquidity
/// @notice Opens the ETH / collection-coin Uniswap v4 pool and permanently holds its protocol-owned liquidity. There
///         is no function that removes liquidity, collects, or transfers anything out. The pool's LP fee is 0 (the
///         hook's ETH fee is its whole fee), so the positions earn nothing to collect.
/// @dev `launch()` (the owner, once) initialises the pool at `startTick` (coin per ETH, fixed at deployment) and adds every
///      coin held as one single-sided position over `[TICK_LOWER, startTick)`: as buyers pay ETH the price moves down
///      through it and the position becomes ETH-paired. No ETH is needed, and none is accepted: the pool never holds
///      more than the whole supply, so the price can never return above `startTick`, and ETH placed there could never
///      be reached by a seller nor removed. The depth buyers meet is set by the opening valuation alone
///      (sim/launch.py). The coin left over by liquidity rounding (a few wei) is burned so total supply equals what the pool holds plus
///      what holders hold. Provenance: ripe0x/draw-shapes PR #9 `ProtocolLiquidity` (MIT): settlement pattern kept;
///      the full-range two-sided seed and `addLiquidity` are replaced by single-sided seeding.
interface IFwaPoolOf {
    function pool() external view returns (address);
}

contract ProtocolLiquidity is IUnlockCallback, ReentrancyGuard, Governed {
    int24 public constant TICK_SPACING = 200;
    int24 public constant TICK_LOWER = -887_200;
    int24 public constant TICK_UPPER = 887_200;

    IPoolManager public immutable poolManager;
    address public immutable token;
    address public hook;
    /// @notice The game's pool owner: the market opens only once it has created the FWA pool (D91).
    address public poolOwner;
    bool public launched;
    /// @notice The opening price (coin per ETH), fixed at deployment: the owner chooses only when the market opens,
    ///         never the price, so no mistaken or hostile tick can sell the supply for nothing.
    int24 public immutable startTick;
    uint128 public coinLiquidity;

    event Launched(int24 startTick, uint256 coins, uint128 coinLiquidity);
    event HookSet(address hook);

    error AlreadyLaunched();
    error NotPoolManager();
    error BadTick();
    error NoFwaPool();

    constructor(address admin_, IPoolManager manager, address token_, int24 startTick_)
        Governed(admin_, true)
    {
        if (address(manager) == address(0) || token_ == address(0)) revert ZeroAddress();
        if (
            startTick_ % TICK_SPACING != 0 || startTick_ <= TICK_LOWER + TICK_SPACING
                || startTick_ >= TICK_UPPER - TICK_SPACING
        ) revert BadTick();
        poolManager = manager;
        token = token_;
        startTick = startTick_;
    }

    /// @notice One-shot wiring by the deployer: the hook (CREATE2-mined after this contract exists) and the game's
    ///         pool owner.
    function wire(address hook_, address poolOwner_) external onlyWiring {
        if (hook_ == address(0) || poolOwner_ == address(0)) revert ZeroAddress();
        hook = hook_;
        poolOwner = poolOwner_;
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

    /// @notice Opens the market at `startTick`. Owner, once, and only after the game's FWA pool exists. The tick sets
    ///         the opening price (coin per ETH) and with it the opening valuation: supply / (coins per ETH).
    function launch() external nonReentrant onlyOwner {
        if (launched) revert AlreadyLaunched();
        // the coin trades only once the game's FWA pool exists, the deployment's last step before it (D91)
        if (IFwaPoolOf(poolOwner).pool() == address(0)) revert NoFwaPool();
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
