// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SystemBase} from "./SystemBase.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {IController} from "../../src/interfaces/IController.sol";
import {Engine} from "../../src/core/Engine.sol";
import {FwaV2Controller} from "../../src/fwa/FwaV2Controller.sol";

interface IERC721T {
    function transferFrom(address from, address to, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @dev MOCK, test-only: a controller for a hypothetical next pool system with different internals (it simply holds
///      listed NFTs). It shows the engine depends only on IController, not on FWA V2's ABI. It is not evidence about
///      any real future FWA version.
contract NextGenControllerMock is IController {
    address public immutable engine;
    uint256 public nextId = 1;
    mapping(uint256 => address) public collectionOf;
    mapping(uint256 => uint256) public tokenOf;

    constructor(address engine_) {
        engine = engine_;
    }

    function open() external {}

    function list(address collection, uint256[] calldata tokenIds, uint256[] calldata)
        external
        returns (uint256[] memory listingIds)
    {
        require(msg.sender == engine);
        listingIds = new uint256[](tokenIds.length);
        for (uint256 i; i < tokenIds.length; ++i) {
            require(IERC721T(collection).ownerOf(tokenIds[i]) == address(this));
            collectionOf[nextId] = collection;
            tokenOf[nextId] = tokenIds[i];
            listingIds[i] = nextId++;
        }
    }

    function withdraw(uint256[] calldata listingIds) external {
        require(msg.sender == engine);
        for (uint256 i; i < listingIds.length; ++i) {
            IERC721T(collectionOf[listingIds[i]]).transferFrom(address(this), engine, tokenOf[listingIds[i]]);
        }
    }

    function reprice(uint256, uint256) external {}
    function setPurchases(bool) external {}

    function collect() external pure returns (uint256) {
        return 0;
    }

    function recover(uint256) external {}

    function isListed(uint256 listingId) external view returns (bool) {
        return collectionOf[listingId] != address(0)
            && IERC721T(collectionOf[listingId]).ownerOf(tokenOf[listingId]) == address(this);
    }

    function survived(uint256) external pure returns (uint256) {
        return 0;
    }

    function unsettled() external pure returns (uint256) {
        return 0;
    }
}

/// @notice Phase 2 migration: from one real FWA V2 pool to another through the timelock, with a draw pending at the
///         old pool, survival carried over, and the old pool's proceeds still collectable.
contract MigrationTest is SystemBase {
    uint256[] internal checkIds;
    uint256[] internal shapeIds;

    function setUp() public override {
        super.setUp();
        checkIds = _takeEighties(2);
        shapeIds = _mintShapes(3);
        engine.listChecks(checkIds);
        engine.listShapes(shapeIds);
        _drawSelecting(pool, _shapeListing(shapeIds[0]));
    }

    function test_migrateToNewFwaPoolKeepsEntitlementsAndSurvival() public {
        uint256 pending = _pullAt(pool);

        FwaV2Controller next = _newController(address(engine), "pool-2");
        _govern(address(engine), abi.encodeCall(Engine.setController, (IController(address(next)))));
        assertEq(address(engine.controller()), address(next));
        assertTrue(engine.isRetired(address(controller)));
        assertFalse(pool.localPurchasesEnabled(), "old pool stops taking draws");

        // The pending draw blocks migration of inventory; it cannot be cancelled or redirected.
        vm.expectRevert(Engine.QueueBusy.selector);
        engine.migrateChecks(address(controller), checkIds);
        vm.roll(vm.getBlockNumber() + 3);
        deliverWord(pending, _wordFor(pool, _shapeListing(shapeIds[1])));
        pool.processAcquisitions(10);
        assertEq(IERC721T(SHAPES).ownerOf(shapeIds[1]), player, "the pending player still wins");

        // Anyone migrates; survival is carried (2 allocating draws at the old pool).
        vm.prank(keeper);
        engine.migrateChecks(address(controller), checkIds);
        assertEq(CHECKS.ownerOf(checkIds[0]), address(engine));
        assertEq(engine.survivedDraws(checkIds[0]), 2);
        uint256[] memory leftover = new uint256[](1);
        leftover[0] = shapeIds[2];
        engine.migrateShapes(address(controller), leftover);

        // Old proceeds remain collectable into the engine.
        uint256 owed = pool.ownerProceeds();
        uint256 before = address(engine).balance;
        engine.collect(address(controller));
        assertEq(address(engine).balance - before, owed);

        // The new pool opens, relists, and survival keeps accumulating there.
        deal(FWA_TOKEN, address(next), FWA_FACTORY.poolCreationFee());
        engine.openPool();
        IFWAPool pool2 = next.pool();
        assertEq(pool2.owner(), address(next));
        engine.listChecks(checkIds);
        engine.listShapes(leftover);
        vm.prank(guardian);
        engine.resume();
        assertEq(engine.survivedDraws(checkIds[0]), 2);
        _drawSelecting(pool2, _shapeListing(shapeIds[2]));
        assertEq(engine.survivedDraws(checkIds[0]), 3);

        engine.compose(checkIds[0], checkIds[1], false);
        assertEq(CHECKS.getCheck(checkIds[0]).stored.divisorIndex, 1);
        assertEq(CHECKS.ownerOf(checkIds[0]), address(pool2));
    }

    function test_operatorCannotMigrateAndRetiredListingsStayPut() public {
        FwaV2Controller next = _newController(address(engine), "pool-2");
        vm.prank(operator);
        vm.expectRevert(Engine.NotTimelock.selector);
        engine.setController(IController(address(next)));
        vm.expectRevert(Engine.UnknownController.selector);
        engine.migrateChecks(address(controller), checkIds);
    }

    /// MOCK: the engine can move inventory to a controller for different pool code, once the timelock approves it.
    function test_engineMigratesToDifferentPoolCodeThroughTimelock() public {
        NextGenControllerMock mock = new NextGenControllerMock(address(engine));
        _govern(address(engine), abi.encodeCall(Engine.setController, (IController(address(mock)))));
        engine.migrateChecks(address(controller), checkIds);
        engine.listChecks(checkIds);
        assertEq(CHECKS.ownerOf(checkIds[0]), address(mock));
        assertEq(engine.survivedDraws(checkIds[0]), 1, "carried from the FWA V2 pool");
    }
}
