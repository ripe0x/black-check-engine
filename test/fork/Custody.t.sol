// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {SystemBase} from "./SystemBase.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {IController} from "../../src/interfaces/IController.sol";
import {IChecksOriginals} from "../../src/interfaces/IChecks.sol";
import {Engine, IShapesBacking, ICoinBurn} from "../../src/core/Engine.sol";
import {IChecksEdition} from "../../src/interfaces/IChecks.sol";
import {FwaV2Controller} from "../../src/fwa/FwaV2Controller.sol";

/// @dev Test-only malicious upgrade: what a council majority could install after the delay (residual trust A11).
contract DrainEngine is Engine {
    constructor(IChecksOriginals c, IChecksEdition e, IShapesBacking s, ICoinBurn k) Engine(c, e, s, k) {}

    function drain(address to, uint256 shapeId) external {
        shapes.transferFrom(address(this), to, shapeId);
    }
}

/// @notice Phase 2 custody and authority (docs/THREAT_MODEL.md A1-A6, A9, A11) on the real FWA pool.
contract CustodyTest is SystemBase {
    using stdStorage for StdStorage;

    uint256[] internal checkIds;
    uint256[] internal shapeIds;

    function setUp() public override {
        super.setUp();
        checkIds = _takeEighties(2);
        shapeIds = _mintShapes(3);
        engine.listChecks(checkIds);
        engine.listShapes(shapeIds);
    }

    /// A1, A2, A4, A5: the operator has no asset, upgrade, controller, price or role path.
    function test_A1_operatorCannotMoveAssetsUpgradeOrReconfigure() public {
        vm.startPrank(operator);
        vm.expectRevert(Engine.NotTimelock.selector);
        engine.upgradeToAndCall(address(0xdead), "");
        vm.expectRevert(Engine.NotTimelock.selector);
        engine.setController(IController(address(0xdead)));
        vm.expectRevert(Engine.NotTimelock.selector);
        engine.setSchedule(_tiers(), _thresholds(), _composeBurn(), _coinPrice());
        vm.expectRevert(Engine.NotTimelock.selector);
        engine.setOperator(operator);
        vm.expectRevert(Engine.NotTimelock.selector);
        engine.setGuardian(operator);

        // The controller acts only for the engine.
        uint256[] memory ids = new uint256[](1);
        ids[0] = _checkListing(checkIds[0]);
        vm.expectRevert(FwaV2Controller.NotEngine.selector);
        controller.withdraw(ids);
        vm.expectRevert(FwaV2Controller.NotEngine.selector);
        controller.reprice(ids[0], 1);
        vm.expectRevert(FwaV2Controller.NotEngine.selector);
        controller.setPurchases(true);
        vm.expectRevert(FwaV2Controller.NotEngine.selector);
        controller.collect();
        vm.expectRevert(FwaV2Controller.NotEngine.selector);
        controller.recover(ids[0]);
        vm.expectRevert(FwaV2Controller.NotEngine.selector);
        controller.list(address(CHECKS), ids, ids);
        vm.stopPrank();

        // FWA itself only answers its owner (the controller).
        vm.prank(operator);
        vm.expectRevert();
        pool.withdrawListingsTo(ids, operator);
    }

    /// A3: the operator cannot join the timelock, shorten the delay or schedule anything.
    function test_A3_operatorCannotCaptureTimelock() public {
        bytes32 proposer = timelock.PROPOSER_ROLE();
        bytes32 admin = timelock.DEFAULT_ADMIN_ROLE();
        assertFalse(timelock.hasRole(admin, address(this)), "deployer renounced");
        assertTrue(timelock.hasRole(admin, address(timelock)), "self-administered");

        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, admin));
        timelock.grantRole(proposer, operator);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnauthorizedCaller.selector, operator));
        timelock.updateDelay(0);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, proposer)
        );
        timelock.schedule(address(engine), 0, "", bytes32(0), bytes32(0), DELAY);
        vm.stopPrank();
    }

    /// A6: prices come from the timelocked schedule or the Shape's backing; no caller names one.
    function test_A6_listingPricesComeFromScheduleAndBacking() public view {
        (,,,,, uint256 price,,) = pool.listings(_checkListing(checkIds[0]));
        assertEq(price, _tiers()[0]);
        (,,,,, uint256 shapePrice,,) = pool.listings(_shapeListing(shapeIds[0]));
        assertEq(shapePrice, SHAPE_PRICE, "backing x (1 + timelocked markup)");
    }

    /// A9: the engine leaves no approvals behind; the controller approves only its own pool.
    function test_A9_noStandingApprovals() public view {
        assertFalse(CHECKS.isApprovedForAll(address(engine), address(controller)));
        assertFalse(CHECKS.isApprovedForAll(address(engine), operator));
        assertTrue(CHECKS.isApprovedForAll(address(controller), address(pool)));
        assertEq(CHECKS.ownerOf(checkIds[0]), address(pool), "listed NFTs sit in FWA, not the controller");
    }

    /// Halts: operator or guardian stops draws; only guardian or timelock reopens them.
    function test_haltResumeRoles() public {
        vm.prank(operator);
        engine.halt();
        assertFalse(pool.localPurchasesEnabled());
        vm.prank(operator);
        vm.expectRevert(Engine.NotAllowed.selector);
        engine.resume();
        vm.prank(keeper);
        vm.expectRevert(Engine.NotAllowed.selector);
        engine.halt();
        vm.prank(guardian);
        engine.resume();
        assertTrue(pool.localPurchasesEnabled());
    }

    /// Composition is permissionless once both Checks survived enough allocating draws, and needs an empty queue.
    function test_composeIsPermissionlessAndPlayGated() public {
        vm.prank(keeper);
        vm.expectRevert(Engine.NotEligible.selector);
        engine.compose(checkIds[0], checkIds[1], false);

        _drawSelecting(pool, _shapeListing(shapeIds[0]));
        _drawSelecting(pool, _shapeListing(shapeIds[1]));
        assertEq(engine.survivedDraws(checkIds[0]), 2);

        uint256 pending = _pullAt(pool);
        vm.prank(keeper);
        vm.expectRevert(Engine.QueueBusy.selector);
        engine.compose(checkIds[0], checkIds[1], false);
        vm.roll(vm.getBlockNumber() + 31);
        pool.processAcquisitions(10); // the pending draw expires; its player is refunded by FWA
        (,,,, IFWAPool.AcquisitionStatus st) = pool.acquisitions(pending);
        assertEq(uint8(st), uint8(IFWAPool.AcquisitionStatus.Expired));

        // Before the grace period, composing burns the tier's coin from whoever composes (a keeper here).
        coin.transfer(keeper, 100 ether);
        vm.prank(keeper);
        coin.approve(address(engine), 100 ether);
        vm.prank(keeper);
        engine.compose(checkIds[0], checkIds[1], false);
        assertEq(coin.balanceOf(keeper), 0, "burned exactly composeBurn[0]");
        assertEq(CHECKS.getCheck(checkIds[0]).stored.divisorIndex, 1);
        assertEq(CHECKS.ownerOf(checkIds[0]), address(pool), "survivor relisted");
        (,,,,, uint256 price,,) = pool.listings(_checkListing(checkIds[0]));
        assertEq(price, _tiers()[1]);
        assertEq(engine.survivedDraws(checkIds[0]), 0, "fresh episode");
        vm.expectRevert();
        CHECKS.ownerOf(checkIds[1]);
    }

    /// Review finding: a won Check sent back to the engine is relistable and starts a fresh survival history.
    function test_wonCheckReturnedIsRelistableWithFreshHistory() public {
        _drawSelecting(pool, _shapeListing(shapeIds[0]));
        _drawSelecting(pool, _checkListing(checkIds[0]));
        assertEq(CHECKS.ownerOf(checkIds[0]), player);
        assertFalse(engine.eligible(checkIds[0]));
        assertEq(engine.survivedDraws(checkIds[0]), 0);

        vm.prank(player);
        CHECKS.transferFrom(player, address(engine), checkIds[0]);
        uint256[] memory one = new uint256[](1);
        one[0] = checkIds[0];
        engine.listChecks(one);
        assertEq(CHECKS.ownerOf(checkIds[0]), address(pool));
        assertEq(engine.survivedDraws(checkIds[0]), 0);
        // A still-listed Check cannot be listed twice.
        vm.expectRevert(Engine.AlreadyListed.selector);
        engine.listChecks(one);
    }

    /// Review finding: for a won Check sold back, the view reports the price `listChecks` will use (fresh history).
    function test_currentNotionalOfAReturnedCheckMatchesItsRelisting() public {
        for (uint256 i; i < 3; ++i) _drawSelecting(pool, _shapeListing(shapeIds[i]));
        _drawSelecting(pool, _checkListing(checkIds[0]));
        vm.prank(player);
        CHECKS.transferFrom(player, address(engine), checkIds[0]);
        // Survival carried from an earlier pool (as after a migration), written directly: listChecks discards it.
        stdstore.target(address(engine)).sig("carriedDraws(uint256)").with_key(checkIds[0]).checked_write(uint256(50));
        assertEq(engine.survivedDraws(checkIds[0]), 50);
        uint256 shown = engine.currentNotional(checkIds[0]);
        uint256[] memory one = new uint256[](1);
        one[0] = checkIds[0];
        engine.listChecks(one);
        (,, uint128 listed) = engine.checkListing(checkIds[0]);
        assertEq(shown, listed);
    }

    /// Batches above FWA's 20-item inventory limit are split by the controller.
    function test_listsMoreThanTwentyInOneCall() public {
        uint256[] memory many = _mintShapes(25);
        engine.listShapes(many);
        assertEq(IShapesBacking(SHAPES).ownerOf(many[24]), address(pool));
    }

    /// Proceeds go only to the engine, whoever triggers collection.
    function test_collectSendsProceedsToEngine() public {
        _drawSelecting(pool, _shapeListing(shapeIds[0]));
        uint256 owed = pool.ownerProceeds();
        assertGt(owed, 0);
        uint256 before = address(engine).balance;
        vm.prank(keeper);
        engine.collect(address(controller));
        assertEq(address(engine).balance - before, owed);
        vm.expectRevert(Engine.UnknownController.selector);
        engine.collect(keeper);
    }

    /// A11: a council-scheduled upgrade waits 7 days, the guardian can cancel it, and if nobody cancels, a malicious
    ///      implementation could take custody assets. This is the disclosed residual trust.
    function test_A11_upgradeDelayCancelAndResidualPower() public {
        // Unlist one Check into custody first so there is something the drain can reach directly.
        _drawSelecting(pool, _shapeListing(shapeIds[0]));
        _drawSelecting(pool, _shapeListing(shapeIds[1]));
        engine.compose(checkIds[0], checkIds[1], false); // survivor relisted; withdraw path exercised
        address evil = address(new DrainEngine(CHECKS, EDITIONS, IShapesBacking(SHAPES), ICoinBurn(address(coin))));
        bytes memory data = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (evil, ""));

        vm.prank(council);
        timelock.schedule(address(engine), 0, data, bytes32(0), bytes32("evil"), DELAY);
        vm.warp(vm.getBlockTimestamp() + DELAY - 1);
        vm.expectRevert();
        timelock.execute(address(engine), 0, data, bytes32(0), bytes32("evil"));

        bytes32 id = timelock.hashOperation(address(engine), 0, data, bytes32(0), bytes32("evil"));
        vm.prank(guardian);
        timelock.cancel(id);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectRevert();
        timelock.execute(address(engine), 0, data, bytes32(0), bytes32("evil"));

        // Not cancelled: after the delay the upgrade lands. A drain is then possible for anything the engine holds.
        _govern(address(engine), data);
        uint256 shapeInCustody = _mintShapes(1)[0];
        address thief = makeAddr("thief");
        vm.prank(thief);
        DrainEngine(payable(address(engine))).drain(thief, shapeInCustody);
        assertEq(IShapesBacking(SHAPES).ownerOf(shapeInCustody), thief);
    }
}
