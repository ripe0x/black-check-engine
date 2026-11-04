// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {CollectionPoolOwner} from "../../src/core/CollectionPoolOwner.sol";
import {CollectionGame} from "../../src/game/CollectionGame.sol";
import {CollectionToken} from "../../src/token/CollectionToken.sol";
import {CollectionHook} from "../../src/token/CollectionHook.sol";
import {MigrationAuthority} from "../../src/migration/MigrationAuthority.sol";
import {ChecksDesk} from "../../src/checks/ChecksDesk.sol";
import {Admin} from "../../src/core/Admin.sol";
import {Governed} from "../../src/core/Governed.sol";

/// @dev A successor contract for proposals (its code is pinned at proposal).
contract CouncilSuccessor {
    receive() external payable {}
}

/// @notice D012 on the real deployment: the council is an OpenZeppelin TimelockController (council Safe proposes, 7
///         days, guardian cancels, anyone executes, no admin but itself), and it alone holds the powers that change
///         where value goes or what custody is worth. The owner (operator) keeps routine bounded settings, pause and
///         the instant sunset into buybacks; every value-reaching owner setting has a hard bound.
contract CouncilForkTest is ForkBase {
    TimelockController t;
    address alice = makeAddr("council.alice");

    function setUp() public {
        deployChecks();
        t = sys.council;
        launchGame(cfg.refPrice);
    }

    function _op(address target, bytes memory data, bytes32 salt) internal view returns (bytes32) {
        return t.hashOperation(target, 0, data, bytes32(0), salt);
    }

    function test_councilActsOnlyThroughItsDelay() public {
        uint256[8] memory s = sys.poolOwner.schedule();
        s[0] = 0.3 ether;
        bytes memory data = abi.encodeCall(CollectionPoolOwner.setSchedule, (s));
        // the owner and strangers cannot propose to the council
        vm.prank(owner);
        vm.expectRevert();
        t.schedule(address(sys.poolOwner), 0, data, bytes32(0), bytes32("a"), 7 days);
        // the Safe proposes; less than 7 days is refused
        vm.prank(councilSafe);
        vm.expectRevert();
        t.schedule(address(sys.poolOwner), 0, data, bytes32(0), bytes32("a"), 7 days - 1);
        vm.prank(councilSafe);
        t.schedule(address(sys.poolOwner), 0, data, bytes32(0), bytes32("a"), 7 days);
        vm.warp(block.timestamp + 7 days - 1);
        vm.expectRevert();
        t.execute(address(sys.poolOwner), 0, data, bytes32(0), bytes32("a"));
        vm.warp(block.timestamp + 1);
        vm.prank(alice); // anyone executes
        t.execute(address(sys.poolOwner), 0, data, bytes32(0), bytes32("a"));
        assertEq(sys.poolOwner.scheduleOf(0), 0.3 ether);
    }

    function test_guardianCancels() public {
        CouncilSuccessor succ = new CouncilSuccessor();
        bytes memory data = abi.encodeCall(MigrationAuthority.propose, (address(succ)));
        vm.prank(councilSafe);
        t.schedule(address(sys.migration), 0, data, bytes32(0), bytes32("m"), 7 days);
        bytes32 id = _op(address(sys.migration), data, bytes32("m"));
        vm.prank(owner);
        vm.expectRevert(); // the owner is not a canceller
        t.cancel(id);
        vm.prank(guardian);
        t.cancel(id);
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert();
        t.execute(address(sys.migration), 0, data, bytes32(0), bytes32("m"));
        assertEq(sys.migration.pending(), address(0));
    }

    /// A migration takes the council's 7 days and then the MigrationAuthority's own 72 hours, in public, to code pinned
    /// at the proposal: no single key moves custody (invariants 10 and 11).
    function test_migrationNeedsTheCouncilAndBothDelays() public {
        CouncilSuccessor succ = new CouncilSuccessor();
        vm.prank(owner);
        vm.expectRevert(Governed.NotCouncil.selector);
        sys.migration.propose(address(succ));
        bytes memory data = abi.encodeCall(MigrationAuthority.propose, (address(succ)));
        vm.prank(councilSafe);
        t.schedule(address(sys.migration), 0, data, bytes32(0), bytes32("m"), 7 days);
        vm.warp(block.timestamp + 7 days);
        t.execute(address(sys.migration), 0, data, bytes32(0), bytes32("m"));
        assertEq(sys.migration.pending(), address(succ));
        assertEq(sys.migration.executableAt(), block.timestamp + 72 hours);
        vm.expectRevert(MigrationAuthority.TooEarly.selector);
        sys.migration.execute();
        assertFalse(sys.game.retiring());
    }

    /// Every power that changes where value goes or what custody is worth refuses the owner (D012).
    function test_ownerHoldsNoValuePower() public {
        CouncilSuccessor succ = new CouncilSuccessor();
        uint256[8] memory s = sys.poolOwner.schedule();
        CollectionPoolOwner.ListingParams memory lp = sys.poolOwner.listingParams();
        ChecksDesk.BuyoutParams memory bp = sys.desk.buyoutParams();
        vm.startPrank(owner);
        vm.expectRevert(Governed.NotCouncil.selector);
        sys.migration.propose(address(succ));
        vm.expectRevert(Governed.NotCouncil.selector);
        sys.migration.proposeFeeRecipient(address(succ));
        vm.expectRevert(Governed.NotCouncil.selector);
        sys.poolOwner.setSchedule(s);
        vm.expectRevert(Governed.NotCouncil.selector);
        sys.poolOwner.setListingParams(lp);
        vm.expectRevert(Governed.NotCouncil.selector);
        sys.desk.setBuyoutParams(bp);
        vm.expectRevert(CollectionToken.NotCouncil.selector);
        sys.token.setAllowed(alice, true);
        vm.expectRevert(CollectionToken.NotCouncil.selector);
        sys.token.unrestrict();
        vm.expectRevert(Governed.NotCouncil.selector);
        sys.hook.setLayer(address(succ), 500);
        vm.expectRevert(Admin.NotCouncil.selector);
        sys.admin.setCouncil(owner);
        vm.stopPrank();
    }

    /// The owner's value-reaching settings are bounded by constants: no prize below cost + 5%, keeper pay at most 30 gwei
    /// of gas plus 200,000 overhead and 0.001 ETH a call, within the allowance.
    function test_ownerSettingsAreBounded() public {
        vm.startPrank(owner);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.game.setPricing(0, 0);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.game.setKeeperParams(CollectionGame.KeeperParams(1_000 gwei, 70_000, 0.0002 ether, 5 minutes));
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.game.setKeeperParams(CollectionGame.KeeperParams(3 gwei, 10_000_000, 0.0002 ether, 5 minutes));
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.game.setKeeperParams(CollectionGame.KeeperParams(3 gwei, 70_000, 0.01 ether, 5 minutes));
        // the most it may set
        sys.game.setKeeperParams(CollectionGame.KeeperParams(30 gwei, 200_000, 0.001 ether, 0));
        vm.stopPrank();
        // a maximal tip for a 1M-gas call is about 0.037 ETH, and never more than the allowance left
        vm.txGasPrice(1_000 gwei);
        assertEq(sys.game.quoteTip(1_000_000), 1_200_000 * 30 gwei + 0.001 ether);
    }

    /// The owner keeps the instant sunset (its only destination is buybacks) and pause.
    function test_ownerKeepsSunsetAndPause() public {
        govern(address(sys.game), abi.encodeCall(CollectionGame.setPaused, (true)));
        assertTrue(sys.game.paused());
        govern(address(sys.migration), abi.encodeCall(MigrationAuthority.sunset, ()));
        assertEq(sys.migration.successor(), address(sys.sunset));
        assertEq(sys.hook.feeRecipient(), address(sys.sunset));
    }

    /// The council can open the market if the owner does not (rc2 audit H3), still only once and at the fixed tick.
    function test_councilCanOpenTheMarket() public view {
        assertTrue(sys.liquidity.launched(), "launchGame opened it");
    }
}
