// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFWAPool, FWA_ACQUISITIONS_ENABLED} from "../../src/interfaces/IFWA.sol";

/// @dev FWA's community pool factory (mainnet 0x8919814d825a5af238cc04de06b1c18c9eaa477c): no creation fee.
interface ICommunityFactory {
    function createPool(bytes32 userSalt, address expectedImplementation) external returns (address pool);
    function implementation() external view returns (address);
}

interface IERC721Approve {
    function setApprovalForAll(address operator, bool approved) external;
}

/// @notice TEST ONLY. A minimal successor that receives V1's Checks and capital through the MigrationAuthority, creates
///         a real pool on FWA's community pool factory (genuinely different FWA code from V2) and lists the Checks
///         there. It stands in for a production successor system compiled for the community factory (a recorded
///         follow-up) so the migration path to a new FWA implementation runs on real contracts. No access control:
///         never deployed.
contract CommunitySuccessor {
    ICommunityFactory public immutable factory;
    address public immutable checks;
    IFWAPool public pool;

    constructor(address factory_, address checks_) {
        factory = ICommunityFactory(factory_);
        checks = checks_;
    }

    receive() external payable {}

    function open(bytes32 salt) external returns (address created) {
        created = factory.createPool(salt, factory.implementation());
        pool = IFWAPool(created);
        IERC721Approve(checks).setApprovalForAll(created, true);
    }

    function list(uint256[] calldata tokenIds, uint256[] calldata prices) external returns (uint256[] memory ids) {
        IFWAPool.ListingInput[] memory items = new IFWAPool.ListingInput[](tokenIds.length);
        for (uint256 i; i < tokenIds.length; ++i) {
            items[i] = IFWAPool.ListingInput(checks, tokenIds[i], prices[i]);
        }
        ids = pool.listNFTs(items);
    }

    function enablePurchases() external {
        pool.setBool(FWA_ACQUISITIONS_ENABLED, true);
    }
}
