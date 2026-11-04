// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {Governed} from "../../src/core/Governed.sol";
import {CollectionBurner} from "../../src/treasury/CollectionBurner.sol";
import {Admin} from "../../src/core/Admin.sol";
import {CollectionGame} from "../../src/game/CollectionGame.sol";
import {FundingVault} from "../../src/core/FundingVault.sol";
import {CollectionPoolOwner} from "../../src/core/CollectionPoolOwner.sol";
import {CollectionHook} from "../../src/token/CollectionHook.sol";
import {StrayNFT} from "../utils/StrayNFT.sol";

/// @notice Administration (D57): one owner, read from the `Admin` contract by every governed contract, acting at once
///         within broad bounds; two-step transfer and renounce; nobody else has any power; custody functions belong to
///         the game, the vault and the migration path, never to an administrative call.
contract GovernanceForkTest is ForkBase {
    address alice = makeAddr("cg.player.alice");
    address stranger = makeAddr("cg.stranger");

    function setUp() public {
        deployChecks();
        launchGame(0.25 ether);
    }

    function test_ownerChangesPricingAtOnce() public {
        vm.prank(stranger);
        vm.expectRevert(Governed.NotOwner.selector);
        sys.game.setPricing(1_000, 300);
        govern(address(sys.game), abi.encodeCall(CollectionGame.setPricing, (1_000, 300)));
        assertEq(sys.game.markupBps(), 1_000, "effective in the same transaction");
        // existing listings keep their prices
        uint256 id = sys.game.liveAt(0);
        (,,,, uint16 markup,,) = sys.game.items(id);
        assertEq(markup, cfg.markupBps);
        playMany(alice, 20, 1);
        assertBooks();
    }

    /// The markup and the keeper allowance rate are the owner's choice, 0-100%: replacements list at whatever is set.
    /// D012: the markup can go no lower than 5% (no prize priced at a loss to the protocol); the rest stays broad.
    function test_markupHasAFloorOpsAreBroad() public {
        vm.prank(owner);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.game.setPricing(499, 0);
        govern(address(sys.game), abi.encodeCall(CollectionGame.setPricing, (500, 0)));
        playMany(alice, 30, 2); // replacements list under the new pricing
        uint256 n = sys.game.liveCount();
        uint256 floor;
        for (uint256 i; i < n; ++i) {
            (,,,, uint16 markup, uint16 ops,) = sys.game.items(sys.game.liveAt(i));
            if (markup == 500 && ops == 0) ++floor;
        }
        assertGt(floor, 0, "prizes listed at the floor markup");
        govern(address(sys.game), abi.encodeCall(CollectionGame.setPricing, (10_000, 10_000)));
        vm.prank(owner);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.game.setPricing(10_001, 0);
        assertBooks();
    }

    /// A new pattern must be mintable and its largest prize covered by the reserve; board parameters stay within the gas cap.
    function test_patternAndBoardParamsBounds() public {
        uint256[] memory pattern = new uint256[](1);
        pattern[0] = 5 ether; // the 3 ETH reserve could not pay a 5 ETH prize
        vm.prank(owner);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.game.setPattern(pattern);
        pattern[0] = 0.07 ether; // a Pack of 0.05 + 0.01 + 0.01: mintable
        govern(address(sys.game), abi.encodeCall(CollectionGame.setPattern, (pattern)));
        assertEq(sys.game.rowAt(37), 0.07 ether);
        assertEq(sys.game.maxBacking(), 0.07 ether);
        pattern[0] = 0.015 ether; // not a multiple of the Shapes unit: no prize can be minted
        vm.prank(owner);
        vm.expectRevert();
        sys.game.setPattern(pattern);
        vm.startPrank(owner);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.game.setBoardParams(3, 11, 20); // above the 10 a call may list
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.game.setBoardParams(0, 8, 20);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.game.setBoardParams(3, 8, 0);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.game.setBoardParams(3, 8, 21); // above the 20 a call may book (D85)
        sys.game.setBoardParams(5, 10, 20);
        vm.stopPrank();
        assertEq(sys.game.listBatch(), 5);
        assertEq(sys.game.maxPerCall(), 10);
        assertEq(sys.game.bookPerCall(), 20);
    }

    /// D85: no Draw Pack prize may hold more than four Shapes (the heaviest measured under the gas cap): a pattern
    /// with a five-Shape Pack (0.09 ETH: 0.05 + four 0.01) is refused, a four-Shape one (0.04 ETH) accepted.
    function test_packOfMoreThanFourShapesIsRefused() public {
        (, uint256 n) = sys.poolOwner.makeup(0.09 ether);
        assertEq(n, 5);
        uint256[] memory pattern = new uint256[](1);
        pattern[0] = 0.09 ether;
        vm.prank(owner);
        vm.expectRevert();
        sys.game.setPattern(pattern);
        pattern[0] = 0.04 ether;
        govern(address(sys.game), abi.encodeCall(CollectionGame.setPattern, (pattern)));
        assertEq(sys.game.rowAt(0), 0.04 ether);
    }

    /// Bounds are broad; what remains protects solvency or the code's own limits.
    function test_remainingBounds() public {
        CollectionGame.Settings memory s;
        (
            s.reserveTarget,
            s.maintenanceInterval,
            s.minLiveBps,
            s.maxOutstanding,
            s.maxEdgeBps,
            s.maxCooldown,
            s.minDistribution,
            s.continuityShareBps
        ) = sys.game.settings();
        vm.startPrank(owner);
        s.reserveTarget = 0.4 ether; // below the largest prize (0.5 ETH): the reserve could not pay it once
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.game.setSettings(s);
        s.reserveTarget = 3 ether;
        s.minLiveBps = 0;
        s.maxOutstanding = 5_000;
        s.maxCooldown = 7 days;
        sys.game.setSettings(s); // broad settings are accepted
        s.continuityShareBps = 10_001;
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.game.setSettings(s);
        s.continuityShareBps = 6_000;
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.hook.setFees(1_001, 300); // trading fee above 10%
        sys.hook.setFees(1_000, 0);
        CollectionPoolOwner.ListingParams memory lp = sys.poolOwner.listingParams();
        lp.targetBps = 5_001; // above the purchase gate's 50% ceiling
        vm.expectRevert(Governed.NotCouncil.selector); // the listing rule is the council's (D012)
        sys.poolOwner.setListingParams(lp);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.poolOwner.setMaxInFlight(51);
        CollectionBurner.Cadence memory c = sys.burner.cadence();
        c.maxSliceWei = 1 ether;
        c.maxImpactBps = 500; // buyback limits up to the hard bounds
        sys.burner.setCadence(c);
        c.maxImpactBps = 501;
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.burner.setCadence(c);
        vm.stopPrank();
    }

    function test_strangersHaveNoPowerAndPauseIsImmediate() public {
        CollectionPoolOwner.ListingParams memory lp = sys.poolOwner.listingParams();
        uint256 rows = sys.game.boardSize();
        vm.startPrank(stranger);
        vm.expectRevert(Governed.NotOwner.selector);
        sys.game.setPaused(true);
        vm.expectRevert(Governed.NotOwner.selector);
        sys.game.retire();
        vm.expectRevert(Governed.NotOwner.selector);
        sys.game.setBoardSize(rows + 1);
        vm.expectRevert(Governed.NotCouncil.selector);
        sys.poolOwner.setListingParams(lp);
        vm.expectRevert(CollectionHook.NotMigrator.selector);
        sys.hook.setFeeRecipient(stranger);
        vm.expectRevert(Governed.NotCouncil.selector);
        sys.migration.propose(stranger);
        vm.expectRevert(Governed.NotCouncil.selector);
        sys.migration.proposeFeeRecipient(stranger);
        vm.expectRevert(Governed.NotOwner.selector);
        sys.migration.sunset();
        vm.stopPrank();
        vm.prank(owner);
        sys.game.setPaused(true);
        assertFalse(pool.localPurchasesEnabled(), "paused at once");
        vm.prank(owner);
        sys.game.setPaused(false);
        assertTrue(pool.localPurchasesEnabled(), "resumed at once");
    }

    function test_deployerHasNoPowerAfterWiring() public {
        vm.expectRevert(Governed.NotDeployer.selector);
        sys.vault.wire(address(sys.game), address(sys.poolOwner), address(0));
        vm.expectRevert(Governed.NotDeployer.selector);
        sys.poolOwner.wire(address(this), address(this), new address[](0));
        vm.expectRevert(Governed.NotDeployer.selector);
        sys.burner.wire(address(1), address(sys.game), address(sys.poolOwner));
        vm.expectRevert(Governed.NotDeployer.selector);
        sys.migration.wire(address(1), address(1), address(1), address(1), address(sys.sunset));
    }

    /// One two-step transfer moves administration of every contract; renouncing ends it for good.
    function test_ownershipTransfersInTwoStepsAndRenounces() public {
        address next = makeAddr("cg.next.owner");
        vm.prank(owner);
        sys.admin.transferOwnership(next);
        vm.prank(next);
        vm.expectRevert(Governed.NotOwner.selector);
        sys.game.setPaused(true); // not yet
        vm.prank(next);
        sys.admin.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(Governed.NotOwner.selector);
        sys.game.setPaused(true);
        vm.prank(next);
        sys.game.setPaused(true);
        vm.prank(next);
        sys.game.setPaused(false);
        assertEq(sys.vault.owner(), next);
        assertEq(sys.hook.owner(), next);
        // renouncing while the coin is restricted is allowed (D82): the restriction then stands for good
        vm.prank(next);
        sys.admin.renounceOwnership();
        assertTrue(sys.token.restricted(), "restriction stands");
        vm.prank(next);
        vm.expectRevert();
        sys.token.unrestrict();
        vm.prank(next);
        vm.expectRevert(Governed.NotOwner.selector);
        sys.game.setPaused(true);
        // the game keeps running with nobody administering it
        playMany(alice, 10, 3);
        assertBooks();
    }

    /// The board grows by the owner's call (never shrinks), at most 50 rows a call and only when the vault can fund the
    /// rows on top of the game's needs; the new rows are listed like replacements.
    function test_ownerGrowsTheBoard() public {
        uint256 size = sys.game.boardSize();
        vm.prank(owner);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.game.setBoardSize(size); // never shrinks or stays
        vm.prank(owner);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.game.setBoardSize(size + 51);
        accrueFees(5 ether);
        govern(address(sys.game), abi.encodeCall(CollectionGame.setBoardSize, (size + 20)));
        assertEq(sys.game.boardSize(), size + 20);
        assertEq(sys.game.owedCount(), 20, "the new rows wait for listing");
        restockAll();
        assertEq(sys.game.liveCount(), size + 20, "listed like replacements");
        assertBooks();
    }

    /// Custody and capital move only through the game, the vault's acquisition and funding paths and the
    /// MigrationAuthority (a migration after its notice, or the sunset): no administrative call reaches them.
    function test_custodyIsNotAnAdministrativeFunction() public {
        vm.startPrank(owner);
        vm.expectRevert(CollectionPoolOwner.NotGame.selector);
        sys.poolOwner.withdrawCollection();
        vm.expectRevert(CollectionPoolOwner.NotGame.selector);
        sys.poolOwner.collectProceeds();
        vm.expectRevert(CollectionPoolOwner.NotVault.selector);
        sys.poolOwner.register(1, 1, 1, 0);
        vm.expectRevert(CollectionPoolOwner.NotMigrator.selector);
        sys.poolOwner.migrateApe(owner);
        vm.expectRevert(FundingVault.NotGame.selector);
        sys.vault.receiveReturn{value: 0}();
        vm.expectRevert(FundingVault.NotGame.selector);
        sys.vault.receiveSurplus{value: 0}();
        vm.expectRevert(FundingVault.NotMigrator.selector);
        sys.vault.migrateCapital(owner);
        vm.stopPrank();
    }

    /// The owner sends out an unrelated NFT that any contract holds by mistake (D62); the collection, Shapes and Draw
    /// Packs are never swept, whatever the token id; strangers cannot sweep; the protected list is closed at deploy.
    function test_ownerSweepsStrayNFTsOnly() public {
        StrayNFT stray = new StrayNFT();
        address[5] memory holders = [
            address(sys.game), address(sys.vault), address(sys.poolOwner), address(sys.hook), address(sys.burner)
        ];
        for (uint256 i; i < holders.length; ++i) {
            stray.mint(holders[i], i);
            vm.prank(stranger);
            vm.expectRevert(Governed.NotOwner.selector);
            Governed(holders[i]).sweepNFT(address(stray), i, stranger);
            vm.prank(owner);
            Governed(holders[i]).sweepNFT(address(stray), i, owner);
            assertEq(stray.ownerOf(i), owner, "swept to the owner's chosen address");
        }
        assertTrue(sys.admin.isProtected(cfg.collection) && sys.admin.isProtected(cfg.shapes));
        assertTrue(sys.admin.isProtected(sys.packs));
        // an Ape on the board (held by the FWA pool) and the vault's own Ape: never by a sweep
        uint256 listed = sys.poolOwner.listedAt(0);
        address[3] memory own = [cfg.collection, cfg.shapes, sys.packs];
        vm.startPrank(owner);
        for (uint256 i; i < own.length; ++i) {
            vm.expectRevert(Governed.ProtectedNFT.selector);
            sys.poolOwner.sweepNFT(own[i], listed, owner);
            vm.expectRevert(Governed.ProtectedNFT.selector);
            sys.vault.sweepNFT(own[i], listed, owner);
        }
        vm.stopPrank();
        // nobody can add or remove a protected collection after deployment
        address[] memory more = new address[](1);
        more[0] = address(stray);
        vm.prank(owner);
        vm.expectRevert(Admin.NotDeployer.selector);
        sys.admin.protect(more);
        vm.expectRevert(Admin.NotDeployer.selector);
        sys.admin.protect(more);
        assertEq(sys.admin.deployer(), address(0));
        assertBooks();
    }

    function test_adminRejectsZeroOwnerAtDeploy() public {
        vm.expectRevert(Admin.ZeroAddress.selector);
        new Admin(address(0), address(1));
    }
}
