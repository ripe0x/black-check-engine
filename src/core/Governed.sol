// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IAdmin {
    function owner() external view returns (address);
    function isProtected(address token) external view returns (bool);
}

interface IERC721Sweep {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

/// @title Governed
/// @notice Administration for every Ape Draw contract: the owner recorded in the shared `Admin` contract (two-step
///         transfer, renounce), plus the deployer's one-shot wiring window.
/// @dev Provenance: generalises `src/Governed.sol` of ripe0x/draw-shapes PR #9 (commit 0020bea, MIT), which had a
///      timelock and the same one-shot `wire` window. Roles and timelocks are collapsed into one owner.
abstract contract Governed {
    IAdmin public immutable admin;
    address public deployer;

    error NotOwner();
    error NotDeployer();
    error ZeroAddress();
    error OutOfBounds();
    error ProtectedNFT();

    event Wired();

    constructor(address admin_, bool needsWiring) {
        if (admin_ == address(0)) revert ZeroAddress();
        admin = IAdmin(admin_);
        if (needsWiring) deployer = msg.sender;
    }

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    modifier onlyWiring() {
        if (msg.sender != deployer || msg.sender == address(0)) revert NotDeployer();
        _;
        deployer = address(0);
        emit Wired();
    }

    /// @notice The current administrator (address(0) once renounced).
    function owner() public view returns (address) {
        return admin.owner();
    }

    /// @dev One shared check (not inlined into every governed function: CollectionGame is at the size limit).
    function _checkOwner() internal view {
        if (msg.sender != admin.owner() || msg.sender == address(0)) revert NotOwner();
    }

    function wired() public view returns (bool) {
        return deployer == address(0);
    }

    /// @notice Sends out an NFT this contract holds by mistake. Owner only. Never one of the protocol's own
    ///         collections (`Admin.isProtected`: the collection, Shapes, Draw Packs), whatever the token: those leave
    ///         only by the game's rules. ERC-721 `safeTransferFrom`, so it cannot move ERC-20 balances.
    function sweepNFT(address token, uint256 tokenId, address to) external {
        _checkOwner();
        if (admin.isProtected(token)) revert ProtectedNFT();
        IERC721Sweep(token).safeTransferFrom(address(this), to, tokenId); // the token's Transfer event records it
    }
}
