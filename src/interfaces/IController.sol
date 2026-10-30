// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice What the engine needs from the controller of one draw pool. One implementation per FWA version; each
///         controller permanently owns exactly one pool and acts only for the engine. A new FWA version means a new
///         controller approved through the timelock, and the council's review of its code is the security boundary:
///         the engine hands it the NFTs it lists. Survival correctness also rests on the controller: every listing it
///         reports must be live at once (never staged), and `survived` must count only prize allocations made while
///         the listing stayed listed (FwaV2Controller: listed - withdrawn - activeListingCount, C010).
interface IController {
    /// @notice Creates the pool this controller owns. Fails if the pool already exists.
    function open() external;
    /// @notice Lists NFTs the engine has just transferred to this controller (any count; batched internally) and
    ///         starts their survival episodes. Reverts unless the pool's queue is empty, so every listing is live.
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

    /// @notice True while `listingId` was listed by this controller and is still in the draw.
    function isListed(uint256 listingId) external view returns (bool);
    /// @notice Draws that allocated a prize while `listingId` stayed listed (zero once it is no longer listed).
    function survived(uint256 listingId) external view returns (uint256);
    /// @notice Draws not yet settled at the pool; maintenance needs zero.
    function unsettled() external view returns (uint256);
}
