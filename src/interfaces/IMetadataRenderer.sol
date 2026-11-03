// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice A coin's metadata renderer (as artcoins' `IMetadataRenderer`): builds the coin's ERC-7572 contract URI.
interface IMetadataRenderer {
    /// @notice Contract-level metadata for `token` per ERC-7572: a data URI with JSON, or an HTTPS URL.
    function contractURI(address token) external view returns (string memory);
}
