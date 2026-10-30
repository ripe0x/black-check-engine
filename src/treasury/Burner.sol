// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

interface IVenue {
    function poolKey() external view returns (PoolKey memory);
    function poolManager() external view returns (IPoolManager);
    function launched() external view returns (bool);
    function coinLiquidity() external view returns (uint128);
    function startTick() external view returns (int24);
}

interface IFeeHook {
    function feeBps() external view returns (uint256);
}

interface IBurnableCoin {
    function burn(uint256 amount) external;
    function balanceOf(address) external view returns (uint256);
}

/// @notice Turns game surplus into permanently burned coin. Holds ETH the engine releases; anyone may call `burn` at
///         most once per `interval`, which buys coin on the venue with at most `maxPerBurn` ETH and burns all of it.
/// @dev No owner and no exits other than the swap: the coin it buys is burned in the same call, and ETH only leaves
///      into the PoolManager. Without a trusted price there is no minimum output. Instead the chunk is bounded so a
///      sandwich cannot pay: the attacker pays the venue's ETH fee on both legs and gains only the price move this
///      chunk causes, which stays below that fee while the chunk is at most half the fee's share of the pool's
///      virtual ETH depth. The pool is shallowest at its opening price (the price can never return above it) and
///      other liquidity only deepens it, so the bound holds in every pool state (audit H1, D010). A nonzero interval
///      allows at most one burn per block. The pool manager and key are read from the venue contract at
///      construction, so a burner cannot be built against another pool; the council checks `venue` when it
///      approves `Engine.setBurner`.
contract Burner is IUnlockCallback {
    IPoolManager public immutable poolManager;
    address public immutable venue;
    IBurnableCoin public immutable coin;
    uint256 public immutable maxPerBurn;
    uint256 public immutable interval;
    PoolKey internal key;

    uint256 public lastBurnAt;
    uint256 public totalEthSpent;
    uint256 public totalBurned;

    event Burned(address indexed by, uint256 ethIn, uint256 coinBurned);

    error TooSoon();
    error Nothing();
    error NotPoolManager();
    error NotLaunched();
    error ChunkTooLarge();

    constructor(IVenue venue_, uint256 maxPerBurn_, uint256 interval_) {
        // Before launch the venue's key has no hook and no pool exists; ETH sent here could then never leave.
        if (!venue_.launched()) revert NotLaunched();
        if (maxPerBurn_ == 0) revert Nothing(); // `burn` could never spend, stranding all ETH sent here
        venue = address(venue_);
        poolManager = venue_.poolManager();
        key = venue_.poolKey();
        uint256 depth = FullMath.mulDiv(
            venue_.coinLiquidity(), FixedPoint96.Q96, TickMath.getSqrtPriceAtTick(venue_.startTick())
        ); // virtual ETH reserve at the opening price
        if (interval_ == 0 || maxPerBurn_ > depth * IFeeHook(address(key.hooks)).feeBps() / 20_000) {
            revert ChunkTooLarge();
        }
        coin = IBurnableCoin(Currency.unwrap(key.currency1));
        maxPerBurn = maxPerBurn_;
        interval = interval_;
    }

    function burn() external returns (uint256 ethIn, uint256 burned) {
        if (block.timestamp < lastBurnAt + interval) revert TooSoon();
        ethIn = address(this).balance < maxPerBurn ? address(this).balance : maxPerBurn;
        if (ethIn == 0) revert Nothing();
        lastBurnAt = block.timestamp;
        poolManager.unlock(abi.encode(ethIn));
        burned = coin.balanceOf(address(this));
        coin.burn(burned);
        totalEthSpent += ethIn;
        totalBurned += burned;
        emit Burned(msg.sender, ethIn, burned);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        uint256 ethIn = abi.decode(data, (uint256));
        BalanceDelta d = poolManager.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
        poolManager.settle{value: uint256(int256(-d.amount0()))}();
        poolManager.take(key.currency1, address(this), uint256(int256(d.amount1())));
        return "";
    }

    receive() external payable {}
}
