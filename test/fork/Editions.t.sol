// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {ForkBase} from "./ForkBase.sol";
import {Lab} from "./Lab.sol";
import {IChecksOriginals, IChecksEdition} from "../../src/interfaces/IChecks.sol";

/// @notice E7: a real Checks Edition migrated by a contract vault, and the epoch reveal that fixes its art.
///         The Edition's holder is impersonated only to move it into the vault.
contract EditionsTest is ForkBase {
    Lab internal lab;

    function setUp() public override {
        super.setUp();
        lab = new Lab();
    }

    function _takeEdition() internal returns (uint256 id) {
        for (id = 1; id <= 16_031; ++id) {
            try EDITIONS.ownerOf(id) returns (address holder) {
                vm.prank(holder);
                EDITIONS.transferFrom(holder, address(lab), id);
                return id;
            } catch {}
        }
        revert("no edition");
    }

    function test_E7_migrateEditionThenReveal() public {
        uint256 id = _takeEdition();
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        // Checks burns the Edition itself, so the vault must approve the Checks contract on Editions.
        vm.expectRevert();
        lab.exec(address(CHECKS), abi.encodeCall(IChecksOriginals.mint, (ids, address(lab))));
        lab.exec(address(EDITIONS), abi.encodeCall(IChecksEdition.setApprovalForAll, (address(CHECKS), true)));

        uint256 epoch = CHECKS.getEpoch();
        uint256 g = gasleft();
        lab.exec(address(CHECKS), abi.encodeCall(IChecksOriginals.mint, (ids, address(lab))));
        console2.log("mint(1 edition) gas", g - gasleft());

        assertEq(CHECKS.ownerOf(id), address(lab));
        vm.expectRevert();
        EDITIONS.ownerOf(id);
        IChecksOriginals.Check memory c = CHECKS.getCheck(id);
        assertEq(c.stored.divisorIndex, 0);
        uint256 mintedEpoch = c.stored.epoch;
        assertGe(mintedEpoch, epoch);
        assertFalse(c.isRevealed, "art is not fixed at mint");

        IChecksOriginals.Epoch memory e = CHECKS.getEpochData(mintedEpoch);
        assertTrue(e.committed);
        vm.roll(e.revealBlock + 1);
        CHECKS.resolveEpochIfNecessary();
        assertTrue(CHECKS.getEpochData(mintedEpoch).revealed);
        assertTrue(CHECKS.getCheck(id).isRevealed, "revealed once its epoch resolves");
        console2.log("blocks from mint to reveal", e.revealBlock + 1 - FORK_BLOCK);
    }
}
