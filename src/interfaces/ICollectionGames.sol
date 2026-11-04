// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Interfaces between the Collection Games contracts.

interface IFundingVault {
    function receiveSurplus() external payable;
    function receiveReturn() external payable;
    function shortfall() external view returns (uint256);
    function generalBalance() external view returns (uint256);
    function fundGame() external returns (uint256 amount);
}

interface ICollectionGame {
    function receiveCapital() external payable;
    function capitalNeed() external view returns (uint256);
    function growthNeed() external view returns (uint256);
    function activated() external view returns (bool);
    function retired() external view returns (bool);
    function retiring() external view returns (bool);
    function turnover() external view returns (uint256);
    function quoteTip(uint256 gasUsed) external view returns (uint256 amount);
}

interface ICollectionPoolOwner {
    function register(uint256 tokenId, uint256 refCost, uint256 cashCost, uint8 source) external;
    function heldCount() external view returns (uint256);
    function collection() external view returns (address);
    function isCollectionListing(uint256 listingId) external view returns (bool);
    function minNotionalWei() external view returns (uint256);
    function scheduleOf(uint8 tier) external view returns (uint256);
}

interface IBurner {
    function release(uint256 listingId) external returns (uint256 amount);
    function bigPrizeWei() external view returns (uint256);
}

interface IBurnable {
    function burn(uint256 amount) external;
}

interface IHookPrice {
    function blockOpenPrice() external view returns (uint160 open, uint160 current);
}

/// @notice The marketplace adapter for acquisitions. Receives ETH from the vault, must deliver `tokenId` of `collection`
///         to `recipient` and return all unspent ETH to the vault in the same call. The vault checks custody after.
interface IAcquisitionAdapter {
    function execute(address collection, uint256 tokenId, address recipient, bytes calldata data)
        external
        payable
        returns (uint256 spent);
}
