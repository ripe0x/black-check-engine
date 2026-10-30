// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {ForkBase} from "./ForkBase.sol";
import {Lab} from "./Lab.sol";
import {IChecksOriginals} from "../../src/interfaces/IChecks.sol";

/// @notice E5 and E6: canonical Checks composition on real tokens. Real holders are impersonated only to move their
///         tokens into the test vault (setup, not a protocol path).
contract BlackCheckTest is ForkBase {
    Lab internal lab;

    /// @dev Token IDs that reached the single tier before FORK_BLOCK (docs/receipts/single-check-ids.txt).
    uint16[85] internal SINGLES = [
        1, 9, 13, 14, 21, 22, 32, 35, 36, 38, 42, 48, 54, 57, 62, 65, 70, 73, 77, 84, 88, 105, 109, 111, 123, 136, 139,
        149, 190, 200, 235, 240, 256, 262, 303, 325, 366, 449, 500, 555, 622, 658, 661, 669, 686, 749, 765, 917, 1077,
        1189, 1222, 1237, 1337, 1538, 1776, 1992, 2023, 2212, 2446, 2580, 3675, 4079, 4242, 4455, 4466, 5005, 5050,
        5660, 5678, 6400, 6404, 6661, 7007, 7321, 7379, 7878, 8215, 8888, 9999, 10600, 11662, 12001, 16000, 16007, 16031
    ];

    function setUp() public override {
        super.setUp();
        lab = new Lab();
    }

    function _tier(uint256 id) internal view returns (uint8) {
        return CHECKS.getCheck(id).stored.divisorIndex;
    }

    function _alive(uint256 id) internal view returns (bool) {
        try CHECKS.ownerOf(id) returns (address) {
            return true;
        } catch {
            return false;
        }
    }

    function _take(uint256 id) internal {
        address holder = CHECKS.ownerOf(id);
        vm.prank(holder);
        CHECKS.transferFrom(holder, address(lab), id);
    }

    function _livingSingles() internal view returns (uint256[] memory ids, uint256 n) {
        ids = new uint256[](SINGLES.length);
        for (uint256 i; i < SINGLES.length; ++i) {
            uint256 id = SINGLES[i];
            if (_alive(id) && _tier(id) == 6) ids[n++] = id;
        }
    }

    /// E5: 64 real singles form a Black Check in one call from a contract vault.
    function test_E5_infinityOnRealSingles() public {
        (uint256[] memory found, uint256 n) = _livingSingles();
        console2.log("living singles at fork block", n);
        assertGe(n, 64, "fewer than 64 singles exist");

        uint256[] memory ids = new uint256[](64);
        for (uint256 i; i < 64; ++i) {
            ids[i] = found[i];
            _take(ids[i]);
        }
        uint256 supplyBefore = CHECKS.totalSupply();

        uint256 g = gasleft();
        lab.exec(address(CHECKS), abi.encodeCall(IChecksOriginals.infinity, (ids)));
        uint256 used = g - gasleft();
        console2.log("infinity(64) gas, execution only", used);

        assertEq(_tier(ids[0]), 7, "survivor is Black");
        assertEq(CHECKS.ownerOf(ids[0]), address(lab));
        for (uint256 i = 1; i < 64; ++i) assertFalse(_alive(ids[i]));
        assertEq(CHECKS.totalSupply(), supplyBefore - 63);
        // EIP-7825 caps a transaction at 2^24 gas; the block limit is far above it.
        assertLt(used, 1 << 24);
    }

    /// E5 negative: 63 singles plus one 4-Check, or a wrong count, revert.
    function test_E5_infinityRejectsWrongInputs() public {
        (uint256[] memory found,) = _livingSingles();
        uint256[] memory ids = new uint256[](63);
        for (uint256 i; i < 63; ++i) {
            ids[i] = found[i];
            _take(ids[i]);
        }
        vm.expectRevert(bytes4(keccak256("InvalidTokenCount()")));
        lab.exec(address(CHECKS), abi.encodeCall(IChecksOriginals.infinity, (ids)));
    }

    /// E6: build one single from 64 real 80-Checks by pairwise `composite`, recording gas per tier.
    function test_E6_compositeLadderFrom80s() public {
        uint256[] memory pool = new uint256[](64);
        uint256 n;
        for (uint256 id = 1; n < 64 && id <= 16_031; ++id) {
            if (!_alive(id) || _tier(id) != 0) continue;
            pool[n++] = id;
        }
        assertEq(n, 64, "not enough 80s scanned");
        for (uint256 i; i < 64; ++i) _take(pool[i]);

        uint256 width = 64;
        for (uint8 tier; tier < 6; ++tier) {
            uint256 total;
            for (uint256 i; i < width / 2; ++i) {
                uint256 keep = pool[2 * i];
                uint256 burn = pool[2 * i + 1];
                uint256 g = gasleft();
                lab.exec(address(CHECKS), abi.encodeCall(IChecksOriginals.composite, (keep, burn, false)));
                total += g - gasleft();
                pool[i] = keep;
            }
            width /= 2;
            assertEq(_tier(pool[0]), tier + 1);
            console2.log("tier", tier, "-> next, avg composite gas", total / width);
        }
        assertEq(_tier(pool[0]), 6, "a single Check");
        assertEq(CHECKS.ownerOf(pool[0]), address(lab));
    }
}
