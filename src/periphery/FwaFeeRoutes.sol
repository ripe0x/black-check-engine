// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

interface IFwaPoolKey {
    function poolKey() external view returns (PoolKey memory);
}

/// @title FwaFeeRelay
/// @notice Deploy helper that delivers the owner's existing FWA to the pool owner contract, which must pay FWA's
///         50,000 FWA pool creation fee itself. FWA is transfer-locked between wallets (`FWAToken._afterTokenTransfer`
///         allows only mints, burns, the FWA owner, registered distributors, and the v4 PoolManager under a transient
///         allowance the FWA hook grants during a swap), so a plain transfer from the owner's wallet reverts.
/// @dev Route, inside one PoolManager unlock on FWA's own ETH/FWA pool (LP fee 0, hook fee 1% each way, exact input
///      only): sell `fwaIn` FWA for ETH, buy FWA with exactly that ETH, then pay `fwaIn` from the caller into the
///      PoolManager and take the bought FWA straight to `recipient`. The ETH legs net to zero; the cost is the two 1%
///      hook fees plus the round-trip price impact (about 2% in total), paid in FWA. Each swap bumps the hook's
///      transient allowance by exactly the amount its transfer needs. Stateless; holds nothing; the caller must
///      `approve` this contract for `fwaIn` (approval is not a transfer and is allowed).
contract FwaFeeRelay is IUnlockCallback {
    IPoolManager public immutable poolManager;
    address public immutable fwa;

    error NotPoolManager();
    error InsufficientOutput(uint256 out, uint256 minOut);

    constructor(IPoolManager manager, address fwa_) {
        poolManager = manager;
        fwa = fwa_;
    }

    /// @notice Converts `fwaIn` of the caller's FWA into FWA held by `recipient`; reverts unless `minOut` arrives.
    function relay(uint256 fwaIn, address recipient, uint256 minOut) external returns (uint256 out) {
        uint256 before = SafeTransferLib.balanceOf(fwa, recipient);
        poolManager.unlock(abi.encode(msg.sender, fwaIn, recipient));
        out = SafeTransferLib.balanceOf(fwa, recipient) - before;
        if (out < minOut) revert InsufficientOutput(out, minOut);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (address payer, uint256 fwaIn, address recipient) = abi.decode(data, (address, uint256, address));
        PoolKey memory key = IFwaPoolKey(fwa).poolKey();
        BalanceDelta sell = poolManager.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -int256(fwaIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            ""
        );
        uint256 eth = uint256(int256(sell.amount0()));
        BalanceDelta buy = poolManager.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(eth), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
        uint256 out = uint256(int256(buy.amount1()));
        poolManager.sync(key.currency1);
        SafeTransferLib.safeTransferFrom(fwa, payer, address(poolManager), fwaIn);
        poolManager.settle();
        poolManager.take(key.currency1, recipient, out);
        // Any ETH rounding residue (the buy may leave a wei of the sell's ETH unspent) goes to the payer.
        int256 ethLeft = int256(sell.amount0()) + int256(buy.amount0());
        if (ethLeft > 0) poolManager.take(key.currency0, payer, uint256(ethLeft));
        return "";
    }
}

/// @title FwaFeeBuyer
/// @notice Alternative deploy helper: buys FWA with ETH on FWA's own pool and delivers it straight to `recipient`
///         (PoolManager → recipient is allowed under the hook's allowance). Use when the owner prefers to pay the
///         creation fee in ETH. Stateless. Provenance: ripe0x/draw-shapes PR #9 `src/periphery/FwaFeeBuyer.sol` (MIT).
contract FwaFeeBuyer is IUnlockCallback {
    IPoolManager public immutable poolManager;
    address public immutable fwa;

    error NotPoolManager();
    error InsufficientOutput(uint256 out, uint256 minOut);

    constructor(IPoolManager manager, address fwa_) {
        poolManager = manager;
        fwa = fwa_;
    }

    function buyTo(address recipient, uint256 minOut) external payable returns (uint256 out) {
        uint256 before = SafeTransferLib.balanceOf(fwa, recipient);
        poolManager.unlock(abi.encode(recipient, msg.value));
        out = SafeTransferLib.balanceOf(fwa, recipient) - before;
        if (out < minOut) revert InsufficientOutput(out, minOut);
        uint256 left = address(this).balance;
        if (left != 0) SafeTransferLib.forceSafeTransferETH(msg.sender, left);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (address recipient, uint256 ethIn) = abi.decode(data, (address, uint256));
        PoolKey memory key = IFwaPoolKey(fwa).poolKey();
        BalanceDelta d = poolManager.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
        poolManager.settle{value: uint256(int256(-d.amount0()))}();
        poolManager.take(key.currency1, recipient, uint256(int256(d.amount1())));
        return "";
    }

    receive() external payable {}
}
