// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice What the engine needs from the controller of one draw pool. One implementation per FWA version; each
///         controller permanently owns exactly one pool and acts only for the engine. A new FWA version means a new
///         controller approved through the timelock.
interface IController {
    /// @notice Creates the pool this controller owns. Fails if the pool already exists.
    function open() external;
    /// @notice Lists NFTs the engine has just transferred to this controller and starts their survival episodes.
    ///         Reverts unless the pool's queue is empty, so every listing is live at once.
    function list(address collection, uint256[] calldata tokenIds, uint256[] calldata prices)
        external
        returns (uint256[] memory listingIds);
    /// @notice Returns listed NFTs to the engine. Reverts while any draw is unsettled.
    function withdraw(uint256[] calldata listingIds) external;
    function reprice(uint256 listingId, uint256 price) external;
    function setPurchases(bool enabled) external;
    /// @notice Sends the pool's owner proceeds to the engine.
    function collect() external returns (uint256 amount);
    /// @notice Returns an NFT whose FWA delivery was refunded to its winner back to the engine.
    function recover(uint256 listingId) external;

    /// @notice Draws that allocated a prize while `listingId` stayed listed (zero once it is no longer listed).
    function survived(uint256 listingId) external view returns (uint256);
    /// @notice Draws not yet settled at the pool; maintenance needs zero.
    function unsettled() external view returns (uint256);
    function advance(uint256 maxCount) external returns (uint256 counted);
    /// @notice True when every processed draw has been counted.
    function caughtUp() external view returns (bool);
}
