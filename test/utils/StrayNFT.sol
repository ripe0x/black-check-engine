// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "solady/tokens/ERC721.sol";

/// @notice An unrelated ERC-721, minted (unsafely) into a protocol contract as a mistaken transfer would leave it.
contract StrayNFT is ERC721 {
    function name() public pure override returns (string memory) {
        return "Stray";
    }

    function symbol() public pure override returns (string memory) {
        return "STRAY";
    }

    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
    }

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}
