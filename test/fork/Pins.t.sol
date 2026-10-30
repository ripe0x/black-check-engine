// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";

/// @notice Phase 0: the deployed code and live settings every later test assumes. A failure here means the
///         environment moved and every dependent conclusion must be re-checked.
contract PinsTest is ForkBase {
    function test_chainAndCode() public view {
        assertEq(block.chainid, 1);
        assertEq(block.number, FORK_BLOCK);
        // keccak256 of runtime code at FORK_BLOCK.
        assertEq(address(CHECKS).codehash, 0x96712bc55889f54257b6fe0e6c6e9b777c730bbc4a0a524945864a5367f44176);
        assertEq(address(EDITIONS).codehash, 0x27a58e421dd745d35d42a4d9a56dc984f1169eb7720e0640a42161cb1b471105);
        assertEq(EDITIONS_IMPL.codehash, 0x7b8fa036e825ca7b96d6c4a81550fc6df4d0fe3bb49bfc7574619ca74ac89d9e);
        assertEq(SHAPES.codehash, 0x5128789aebafbd129f209fc3d84928373b7c9fa07d1721fbc71ee92a412387d7);
        assertEq(address(FWA_FACTORY).codehash, 0x7defffa3d081aef4ac1739a0dde22f38f191e89c6db225d9589b54c07cd29c3d);
        assertEq(FWA_IMPL.codehash, 0x84dee03dd3af8ee9fb96df379991b881988526db09cb7e294c136fedf9a011c5);
        assertEq(FWA_VRF_SERVICE.codehash, 0x51d1973733bdbe417bdbedccbb25965ae67e2256e58ff234213e1719f8deb5d6);
        assertEq(BLKCHK.codehash, 0xd1686da17beb2e2d39816e00e9fc01719bd161cfddd338c4bb5a65b538a055ef);
        // The Editions proxy points at the pinned ERC721Drop implementation (EIP-1967 slot).
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        assertEq(address(uint160(uint256(vm.load(address(EDITIONS), implSlot)))), EDITIONS_IMPL);
    }

    function test_fwaFactorySettings() public view {
        assertEq(FWA_FACTORY.implementation(), FWA_IMPL);
        assertTrue(FWA_FACTORY.poolCreationEnabled());
        assertFalse(FWA_FACTORY.betaAccess());
        assertEq(FWA_FACTORY.maxPoolsPerWallet(), 1);
        assertEq(FWA_FACTORY.poolCreationFee(), 50_000 ether);
        assertEq(FWA_FACTORY.fwaToken(), FWA_TOKEN);
        assertEq(FWA_FACTORY.edgeBps(), 500);
        assertEq(FWA_FACTORY.inventoryChangeCooldown(), 0);
        assertTrue(FWA_FACTORY.globalPurchasesEnabled());
        assertFalse(FWA_FACTORY.globalWithdrawOnly());
        assertFalse(FWA_FACTORY.vrfRequestsPaused());
        assertEq(FWA_FACTORY.maxAcquisitionsPerTx(), 5);
        assertEq(FWA_FACTORY.selectionTimeoutBlocks(), 30);
        assertEq(FWA_FACTORY.maxOutstandingRequestsPerPool(), 10);
        assertEq(FWA_FACTORY.owner(), 0x019817aD02a31B990433542097bE29D97613E8Cb);
    }

    function test_checksState() public view {
        assertEq(CHECKS.editionChecks(), address(EDITIONS));
        assertEq(CHECKS.totalSupply(), 5325);
        assertEq(CHECKS.getEpoch(), 3203);
        assertEq(CHECKS.balanceOf(BLKCHK), 4);
    }
}
