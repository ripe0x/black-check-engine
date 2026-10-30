// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IChecks {
    struct StoredCheck {
        uint16[6] composites;  // The tokenIds that were composited into this one
        uint8[5] colorBands;  // The length of the used color band in percent
        uint8[5] gradients;  // Gradient settings for each generation
        uint8 divisorIndex; // Easy access to next / previous divisor
        uint32 epoch;      // Each check is revealed in an epoch
        uint16 seed;      // A unique identifyer to enable swapping
        uint24 day;      // The days since token was created
    }

    struct Check {
        StoredCheck stored;    // We carry over the check from storage
        bool isRevealed;      // Whether the check is revealed
        uint256 seed;        // The instantiated seed for pseudo-randomisation

        uint8 checksCount;    // How many checks this token has
        bool hasManyChecks;  // Whether the check has many checks
        uint16 composite;   // The parent tokenId that was composited into this one
        bool isRoot;       // Whether it has no parents (80 checks)

        uint8 colorBand;    // 100%, 50%, 25%, 12.5%, 6.25%, 5%, 1.25%
        uint8 gradient;    // Linearly through the colorBand [1, 2, 3]
        uint8 direction;  // Animation direction
        uint8 speed;     // Animation speed
    }

    error NotAllowed();
    error InvalidTokenCount();
    error BlackCheck__InvalidCheck();

    function getCheck(uint256 tokenId) external view returns (
        Check memory check
    );

    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    function approve(address to, uint256 tokenId) external;

    function setApprovalForAll(address operator, bool approved) external;

    function getApproved(uint256 tokenId) external view returns (address);

    function isApprovedForAll(address owner, address operator) external view returns (bool);

    function composite(uint256 tokenId, uint256 burnId, bool swap) external;

    function infinity(uint256[] calldata tokenIds) external;

    function ownerOf(uint256 tokenId) external view returns (address);

    function tokenURI(uint256 tokenId) external view returns (string memory);
}
