// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The subset of Checks Originals (mainnet 0x036721e5A769Cc48B3189EFbb9ccE4471E8A48B1) this protocol uses.
///         Struct layouts are copied from the verified source in `external/checks-originals/contracts/interfaces/IChecks.sol`.
///         `divisorIndex` is the tier: 0 = 80 checks, 1 = 40, 2 = 20, 3 = 10, 4 = 5, 5 = 4, 6 = 1, 7 = Black.
interface IChecksOriginals {
    struct StoredCheck {
        uint16[6] composites;
        uint8[5] colorBands;
        uint8[5] gradients;
        uint8 divisorIndex;
        uint32 epoch;
        uint16 seed;
        uint24 day;
    }

    struct Check {
        StoredCheck stored;
        bool isRevealed;
        uint256 seed;
        uint8 checksCount;
        bool hasManyChecks;
        uint16 composite;
        bool isRoot;
        uint8 colorBand;
        uint8 gradient;
        uint8 direction;
        uint8 speed;
    }

    struct Epoch {
        uint128 randomness;
        uint64 revealBlock;
        bool committed;
        bool revealed;
    }

    /// @dev Burns approved Editions and mints Originals to `recipient` (via `_safeMint`: a contract recipient must
    ///      implement onERC721Received). The caller must own or be approved for each Edition, and the Checks contract
    ///      must be approved on the Edition contract to burn it.
    function mint(uint256[] calldata tokenIds, address recipient) external;
    /// @dev Keeps `tokenId`, burns `burnId`; both same tier <= 5 and owned/approved by the caller. `swap` swaps the
    ///      stored visuals first, so the surviving ID carries the burned token's art.
    function composite(uint256 tokenId, uint256 burnId, bool swap) external;
    function compositeMany(uint256[] calldata tokenIds, uint256[] calldata burnIds) external;
    /// @dev Exactly 64 single Checks (divisorIndex 6); tokenIds[0] becomes the Black Check, the other 63 burn.
    function infinity(uint256[] calldata tokenIds) external;
    function resolveEpochIfNecessary() external;

    function getCheck(uint256 tokenId) external view returns (Check memory);
    function simulateComposite(uint256 tokenId, uint256 burnId) external view returns (Check memory);
    function getEpoch() external view returns (uint256);
    function getEpochData(uint256 index) external view returns (Epoch memory);
    function editionChecks() external view returns (address);
    function totalSupply() external view returns (uint256);

    function ownerOf(uint256 tokenId) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
    function getApproved(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function approve(address to, uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

/// @notice Checks Editions (mainnet 0x34eEBEE6942d8Def3c125458D1a86e0A897fd6f9, an ERC721Drop proxy).
interface IChecksEdition {
    function ownerOf(uint256 tokenId) external view returns (address);
    function totalSupply() external view returns (uint256);
    function setApprovalForAll(address operator, bool approved) external;
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function transferFrom(address from, address to, uint256 tokenId) external;
}
