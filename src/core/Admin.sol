// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Admin
/// @notice The one administrator of every Ape Draw contract. Each governed contract reads `owner()` from here, so a
///         single two-step transfer (or a renounce) moves or ends administration of the whole system at once.
///         It also records the protocol's own NFT collections (the collection, Shapes, Draw Packs), which no governed
///         contract's `sweepNFT` may move.
contract Admin {
    address public owner;
    address public pendingOwner;
    /// @notice The deployer, until it records the protected collections (one shot).
    address public deployer;
    /// @notice The protocol's own NFT collections: they leave the protocol only by the game's rules, never by a sweep.
    mapping(address token => bool) public isProtected;

    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ProtectedSet(address[] tokens);

    error NotOwner();
    error NotPendingOwner();
    error NotDeployer();
    error ZeroAddress();

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        deployer = msg.sender;
        emit OwnershipTransferred(address(0), owner_);
    }

    /// @notice Records the protocol's own NFT collections. The deployer only, once.
    function protect(address[] calldata tokens) external {
        if (msg.sender != deployer || msg.sender == address(0)) revert NotDeployer();
        deployer = address(0);
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == address(0)) revert ZeroAddress();
            isProtected[tokens[i]] = true;
        }
        emit ProtectedSet(tokens);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Step one: names the next owner, who must accept. Naming address(0) cancels a pending transfer.
    function transferOwnership(address next) external onlyOwner {
        pendingOwner = next;
        emit OwnershipTransferStarted(owner, next);
    }

    /// @notice Step two: the named owner accepts.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /// @notice Gives up administration for good: every owner-only function of every contract becomes uncallable.
    ///         Allowed while the coin is restricted (owner's choice, D82): the restriction then stands forever, so the
    ///         coin moves only through swaps in its canonical pool.
    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
        pendingOwner = address(0);
    }
}
