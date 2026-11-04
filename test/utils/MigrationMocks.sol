// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IERC721Balance {
    function balanceOf(address owner) external view returns (uint256);
}

/// @notice A stand-in successor for the migration tests and rehearsal: holds the NFTs it receives and counts the ETH
///         by sender (V1 vault capital, PoolManager trading fees, anything else). Not a game; it only proves the
///         hand-over. A real successor is a separately built pool system.
contract MockSuccessor {
    address public immutable collection;
    address public immutable v1Vault;
    address public immutable poolManager;
    uint256 public capitalReceived;
    uint256 public feesReceived;
    uint256 public otherReceived;

    constructor(address collection_, address v1Vault_, address poolManager_) {
        collection = collection_;
        v1Vault = v1Vault_;
        poolManager = poolManager_;
    }

    receive() external payable {
        if (msg.sender == v1Vault) capitalReceived += msg.value;
        else if (msg.sender == poolManager) feesReceived += msg.value;
        else otherReceived += msg.value;
    }

    function apeCount() external view returns (uint256) {
        return IERC721Balance(collection).balanceOf(address(this));
    }
}

/// @notice A contract that refuses ETH: the migration's capital transfer still lands (forced), and a fee recipient
///         like this makes swaps revert until another recipient is executed after its notice.
contract RejectingReceiver {
    receive() external payable {
        revert("no");
    }
}
