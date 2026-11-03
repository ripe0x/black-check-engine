// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

interface ILayerRouter {
    function layerToken() external view returns (address);
}

/// @title LayerTap
/// @notice Collects the $LAYER share the CollectionHook takes from each trading fee (D90) and forwards it to artcoins'
///         $LAYER burn router, which can only buy and burn $LAYER: by itself, in the swap that brings it to the router's
///         0.01 ETH minimum (with a fixed gas stipend, ignoring failure), or when anyone calls `flush`. The router is
///         fixed here, so a swap never depends on it: if it ever refuses ETH, the ETH waits here and trading goes on.
///         No owner, no other way out.
contract LayerTap {
    /// @notice artcoins' $LAYER burn router.
    address public immutable router;
    /// @notice The $LAYER token the router reported at deployment.
    address public immutable layerToken;

    /// @notice The router's own minimum before it buys and burns: forwarding less would only wait there.
    uint256 public constant FORWARD_AT = 0.01 ether;
    /// @notice Gas the automatic forward may use inside a swap (the router's `receive` uses about 2,000).
    uint256 public constant FORWARD_GAS = 30_000;

    event Flushed(uint256 amount);

    error NotARouter();
    error NothingToFlush();

    constructor(address router_) {
        if (router_.code.length == 0) revert NotARouter();
        address t = ILayerRouter(router_).layerToken();
        if (t == address(0)) revert NotARouter();
        router = router_;
        layerToken = t;
    }

    /// @dev The PoolManager pays the share here in the middle of swaps (anything else sent here goes the same way). Once
    ///      the tap holds the router's minimum it forwards everything; a refusal or running out of the stipend is
    ///      ignored, so the swap goes on and the ETH waits for the next forward or `flush`.
    receive() external payable {
        uint256 held = address(this).balance;
        if (held >= FORWARD_AT && SafeTransferLib.trySafeTransferETH(router, held, FORWARD_GAS)) emit Flushed(held);
    }

    /// @notice Sends everything held to the router. Anyone.
    function flush() external returns (uint256 amount) {
        amount = address(this).balance;
        if (amount == 0) revert NothingToFlush();
        emit Flushed(amount);
        SafeTransferLib.safeTransferETH(router, amount);
    }
}
