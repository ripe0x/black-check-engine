// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {Governed} from "../../src/core/Governed.sol";
import {CollectionGame} from "../../src/game/CollectionGame.sol";

/// @notice Changing the board's pattern after deployment (`CollectionGame.setPattern`, the owner; D63): nothing listed
///         moves; each row takes the new backing the next time it is listed (after its prize is won, or when it is
///         new). No withdrawal, no rebinding; the books stay exact throughout.
contract PatternForkTest is ForkBase {
    address alice = makeAddr("cg.player.alice");

    function setUp() public {
        deployBayc();
        launchGame(6 ether);
    }

    function _setPattern(uint256[] memory pattern) internal {
        govern(address(sys.game), abi.encodeCall(CollectionGame.setPattern, (pattern)));
    }

    function _single(uint256 backing) internal pure returns (uint256[] memory p) {
        p = new uint256[](1);
        p[0] = backing;
    }

    /// A new pattern changes nothing listed: FWA's inventory is untouched.
    function test_newPatternLeavesListedPrizesAlone() public {
        uint256 version = pool.inventoryVersion();
        uint256 live = sys.game.liveCount();
        _setPattern(_single(0.05 ether));
        assertEq(pool.inventoryVersion(), version, "no listing changed");
        assertEq(sys.game.liveCount(), live);
        assertEq(sys.game.replacementsOwed(), 0, "nothing owed");
        assertEq(sys.game.rowAt(0), 0.05 ether);
        assertBooks();
    }

    /// Rows whose prize is won are relisted at the new backing; the rest keep theirs until they are won.
    function test_wonRowsRelistAtTheNewBacking() public {
        _setPattern(_single(0.05 ether));
        playMany(alice, 40, 11);
        // a costlier board outruns the 0.5 ETH reserve (D79): the rows wait for the vault, which trading refills
        buyCoin(makeAddr("trader"), 20 ether);
        restockAll();
        uint256 n = sys.game.liveCount();
        assertEq(n, sys.game.boardSize(), "every row listed");
        uint256 changed;
        for (uint256 i; i < n; ++i) {
            (, uint72 backing,,,,,) = sys.game.items(sys.game.liveAt(i));
            if (backing == 0.05 ether) ++changed;
        }
        assertGe(changed, 30, "won rows took the new backing");
        assertLt(changed, n, "unwon rows kept theirs");
        assertBooks();
    }

    /// Rows already owed when the pattern changes are costed at the new backing.
    function test_owedRowsAreRecostedOnAPatternChange() public {
        // fewer wins than `listBatch` (3): the rows wait for the window
        for (uint256 i; i < 2; ++i) {
            pullAndSettle(alice, uint256(keccak256(abi.encode("owed", i))));
        }
        vm.prank(keeper);
        sys.game.sync();
        uint256 owed = sys.game.owedCount();
        assertGt(owed, 0);
        _setPattern(_single(0.05 ether));
        (uint256 c,) = sys.poolOwner.prizeCost(0.05 ether);
        assertEq(sys.game.replacementsOwed(), owed * c, "owed rows at the new cost");
        restockAll();
        assertEq(sys.game.replacementsOwed(), 0);
        assertBooks();
    }

    function test_patternIsTheOwners() public {
        vm.prank(alice);
        vm.expectRevert(Governed.NotOwner.selector);
        sys.game.setPattern(_single(0.05 ether));
        vm.prank(owner);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.game.setPattern(new uint256[](0));
    }
}
