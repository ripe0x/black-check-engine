// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {IFWAPool, IFWAFactory} from "../../src/interfaces/IFWA.sol";
import {CollectionGame} from "../../src/game/CollectionGame.sol";

/// @notice Safety when nobody runs `sync`, and recovery afterwards. Every purchase here goes straight to FWA's own
///         `acquire` / `acquireBatch`, as the official FWA frontend does; the only thing standing between players and an
///         unattended pool is the purchase gate (CollectionPoolOwner.canPurchase), which reads live FWA state.
contract OutageForkTest is ForkBase {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    address alice = makeAddr("cg.player.alice");
    address bob = makeAddr("cg.player.bob");

    error PurchaseNotAllowed();

    function setUp() public {
        deployChecks();
        launchGame(0.25 ether);
    }

    function _batch(address who, uint256 count) internal returns (uint256[] memory ids) {
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(count);
        uint256 version = pool.inventoryVersion();
        vm.deal(who, who.balance + total);
        vm.prank(who);
        ids = pool.acquireBatch{value: total}(who, count, fee, 0, 10_000, version, vm.getBlockTimestamp() + 1 hours);
    }

    /// @dev What the gate promises at every point of an outage: collection exposure at the live listing count is
    ///      within the gate's 50% ceiling, and at least half the board's Shapes are still in the draw.
    function _assertSafe() internal view {
        uint256 n = pool.activeListingCount();
        uint256 u = pool.unsettledAcquisitionCount();
        uint256 cap = sys.poolOwner.MAX_EXPOSURE_BPS();
        assertLe(sys.poolOwner.exposureSum() * BPS, cap * (n - u) * WAD, "exposure within the ceiling after in-flight settle");
        assertGe(n - sys.poolOwner.openCollection() - u, sys.game.boardSize() / 2, "Shape floor");
    }

    /// A long keeper outage with only direct FWA draws: the gate closes on its own before the unattended board is
    /// unsafe; FWA keeps settling; a returning keeper books everything exactly once and the game reopens.
    function test_outageSingleDrawsGateClosesThenRecovers() public {
        uint256 bought;
        for (uint256 i; i < 200; ++i) {
            if (!canPull(alice)) break;
            pullAndSettle(alice, uint256(keccak256(abi.encode("outage", i))));
            ++bought;
            _assertSafe();
        }
        emit log_named_uint("draws admitted before the gate closed", bought);
        assertLt(bought, 200, "the gate closed by itself");
        assertGt(bought, 10);
        assertTrue(pool.localPurchasesEnabled(), "FWA purchases still enabled: only the live gate stopped them");
        assertEq(sys.game.seenSeq(), 1, "no keeper ran");
        // a direct FWA purchase now reverts in FWA before any fee is taken
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        uint256 version = pool.inventoryVersion();
        vm.deal(bob, total);
        vm.prank(bob);
        vm.expectRevert(PurchaseNotAllowed.selector);
        pool.acquire{value: total}(bob, fee, 0, 10_000, version, vm.getBlockTimestamp() + 1 hours);
        // days later a keeper returns
        vm.warp(vm.getBlockTimestamp() + 5 days);
        syncAll();
        window();
        syncAll();
        assertEq(sys.game.seenSeq(), pool.lastIssuedSequence() + 1, "every request booked");
        assertEq(sys.game.pullsFulfilled() + sys.game.pullsRefunded() + sys.game.pullsExpired(), bought);
        // reopened whether or not an Ape is still in the draw (D53)
        assertEq(sys.game.liveCount(), sys.game.boardSize(), "board restocked");
        assertTrue(canPull(bob), "reopened");
        playMany(bob, 20, 77);
        assertBooks();
        assertEq(sys.game.revenue(), sys.game.proceedsCollected(), "revenue is exactly what FWA paid");
    }

    /// FWA asks the gate once per transaction, without the count: with two singles in flight a five-draw batch is
    /// admitted, so maxInFlight - 1 + 5 requests can be unsettled. The gate's headroom and the decay bound account for exactly that.
    function test_batchAfterSinglesAndBatchLimit() public {
        assertEq(sys.poolOwner.maxBatch(), 5, "read from FWA at pool creation");
        uint256 k = sys.poolOwner.maxInFlight();
        assertEq(sys.poolOwner.gateHeadroom(), k - 1 + 5);
        uint256[] memory singles = new uint256[](k - 1);
        for (uint256 i; i < k - 1; ++i) {
            singles[i] = pull(alice);
        }
        assertTrue(sys.poolOwner.canPurchase(bob), "k - 1 unsettled: still admitted");
        vm.roll(vm.getBlockNumber() + 3);
        if (k - 1 + 5 > 10) {
            // FWA's VRF layer allows 10 requests awaiting a word per pool: the batch reverts there, before any fee
            (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(5);
            uint256 version = pool.inventoryVersion();
            vm.deal(bob, total);
            vm.prank(bob);
            vm.expectRevert(bytes4(0x970730d4)); // PerPoolRequestLimitExceeded
            pool.acquireBatch{value: total}(bob, 5, fee, 0, 10_000, version, vm.getBlockTimestamp() + 1 hours);
            assertEq(bob.balance, total, "nothing paid");
        }
        // the first single's word is late: FWA settles in order, so the others' words arrive but they stay
        // unsettled, no longer awaiting VRF
        for (uint256 i = 1; i < singles.length; ++i) {
            deliverWord(singles[i], uint256(keccak256(abi.encode("single", i))));
        }
        uint256[] memory ids = _batch(bob, 5);
        assertEq(pool.unsettledAcquisitionCount(), k - 1 + 5, "the bound is maxInFlight - 1 + one batch");
        assertFalse(sys.poolOwner.canPurchase(bob), "closed while they are in flight");
        _assertSafe();
        vm.roll(vm.getBlockNumber() + 3);
        deliverWord(singles[0], uint256(keccak256(abi.encode("single", uint256(0)))));
        for (uint256 i; i < ids.length; ++i) {
            deliverWord(ids[i], uint256(keccak256(abi.encode("batch", i))));
        }
        pool.processAcquisitions(20);
        assertEq(pool.unsettledAcquisitionCount(), 0);
        uint256 refunded;
        for (uint256 i; i < ids.length; ++i) {
            if (statusOf(ids[i]) == IFWAPool.AcquisitionStatus.Refunded) ++refunded;
        }
        emit log_named_uint("batch requests refunded for drift", refunded);
        syncAll();
        assertEq(sys.game.pullsFulfilled() + sys.game.pullsRefunded(), k - 1 + 5);
        assertBooks();
        // a batch alone, from idle, is admitted and settles normally
        window();
        syncAll();
        uint256[] memory ids2 = _batch(alice, 5);
        vm.roll(vm.getBlockNumber() + 3);
        for (uint256 i; i < ids2.length; ++i) {
            deliverWord(ids2[i], uint256(keccak256(abi.encode("batch2", i))));
        }
        pool.processAcquisitions(10);
        syncAll();
        assertEq(sys.game.pullsFulfilled() + sys.game.pullsRefunded(), k - 1 + 10);
        assertBooks();
    }

    /// Requests whose VRF word is late or never arrives during an outage: nothing decays or lists over them, they
    /// expire into refund credits, and recovery books them without revenue.
    function test_delayedVrfDuringOutage() public {
        uint256 a = pull(alice);
        uint256 b = pull(alice);
        vm.roll(vm.getBlockNumber() + 20);
        deliverWord(a, uint256(keccak256("late")));
        vm.roll(vm.getBlockNumber() + 40); // b's word never comes
        pool.processAcquisitions(10);
        assertEq(uint8(statusOf(b)), uint8(IFWAPool.AcquisitionStatus.Expired));
        vm.warp(vm.getBlockTimestamp() + 2 days);
        syncAll();
        assertEq(sys.game.pullsExpired(), 1);
        assertGt(pool.acquisitionRefundCredit(alice), 0);
        assertTrue(canPull(alice));
        assertBooks();
    }

    /// Official FWA flows during an outage: single and batch purchases, a failed delivery that the player later
    /// refunds, and refund credits withdrawn, all without a keeper; recovery books every one exactly.
    function test_fwaFrontendFlowsWithoutKeeper() public {
        pullAndSettle(alice, uint256(keccak256("one")));
        uint256[] memory ids = _batch(bob, 5);
        vm.roll(vm.getBlockNumber() + 3);
        for (uint256 i; i < ids.length; ++i) {
            deliverWord(ids[i], uint256(keccak256(abi.encode("fe", i))));
        }
        pool.processAcquisitions(10);
        // a Shape delivery that fails (receiver cannot take it) and is refunded by the player after FWA's window
        uint256 r = pull(alice);
        vm.roll(vm.getBlockNumber() + 3);
        uint256 w = wordFor(0.05 ether);
        vm.mockCallRevert(cfg.shapes, abi.encodeWithSignature("transferFrom(address,address,uint256)"), "");
        deliverWord(r, w);
        pool.processAcquisitions(10);
        vm.clearMockedCalls();
        assertEq(uint8(statusOf(r)), uint8(IFWAPool.AcquisitionStatus.DeliveryPending));
        (,,, uint256 listingId,) = pool.acquisitions(r);
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        vm.prank(alice);
        pool.refundFailedDelivery(listingId);
        // keeper returns
        syncAll();
        window();
        syncAll();
        assertEq(sys.game.deliveriesRefunded(), 1);
        assertEq(sys.game.pullsFulfilled() + sys.game.pullsRefunded() + sys.game.deliveriesRefunded(), 7);
        assertEq(sys.game.openCount(), 0);
        assertBooks();
        assertEq(sys.game.revenue(), sys.game.proceedsCollected());
    }

    /// Shapes and Draw Packs both refusing to mint (an outage of the prize contracts).
    function _breakMinting() internal {
        vm.mockCallRevert(cfg.shapes, abi.encodeWithSignature("mintTo(uint256,address)"), bytes("broken"));
        vm.mockCallRevert(
            sys.packs, abi.encodeWithSignature("createPackTo(uint256[],uint32[],address)"), bytes("broken")
        );
    }

    /// Prize minting reverting: booking and distributions continue, maintenance fails on its own (`StepFailed`), the
    /// board runs down and the gate, which depends on no maintenance step, closes before it is unsafe; retirement then
    /// completes and returns every asset.
    function test_brokenMintingBlocksNothingEssential() public {
        // fifteen draws that win 0.01 Shapes (a profit to distribute, whatever the board's odds)
        for (uint256 i; i < 15; ++i) {
            uint256 r0 = pull(alice);
            vm.roll(vm.getBlockNumber() + 3);
            deliverWord(r0, wordFor(0.01 ether));
            pool.processAcquisitions(10);
        }
        window();
        syncAll();
        _breakMinting();
        uint256 fulfilled = sys.game.pullsFulfilled();
        uint256 dist = sys.game.distributed();
        uint256 n;
        for (uint256 i; i < 60 && canPull(alice); ++i) {
            uint256 r = pull(alice);
            vm.roll(vm.getBlockNumber() + 3);
            deliverWord(r, wordFor(0.01 ether)); // Shapes only, so the Ape stays in the draw
            pool.processAcquisitions(10);
            vm.prank(keeper);
            sys.game.sync();
            _assertSafe();
            ++n;
        }
        emit log_named_uint("draws with minting broken", n);
        assertFalse(canPull(alice), "closed before the board is unsafe");
        assertTrue(sys.poolOwner.collectionAvailable(), "the Ape is still in the draw: the fill rule and the Shape floor closed it");
        assertEq(sys.game.pullsFulfilled(), fulfilled + n, "booking works");
        assertGt(sys.game.distributed(), dist, "distributions work");
        assertBooks();
        // retirement (a migration's execution, or the sunset) with minting still broken
        vm.prank(address(sys.migration));
        sys.game.retire();
        for (uint256 i; i < 20 && !sys.game.retired(); ++i) {
            vm.prank(keeper);
            try sys.game.retireStep() {} catch {}
        }
        assertTrue(sys.game.retired(), "retired with minting broken");
        assertEq(address(sys.game).balance, 0);
        assertEq(sys.game.liveCount(), 0, "every Shape withdrawn and burned");
        assertEq(sys.poolOwner.custodyCount(), 1, "the Ape back in custody for the successor");
        vm.clearMockedCalls();
    }

    /// A collection win while minting is broken is still booked by the ledger and recorded by the pool owner, and the
    /// milestone reserve is released.
    function test_collectionWinWithMintingBroken() public {
        playMany(alice, 30, 4);
        uint256 reserveBefore = sys.burner.reserve();
        _breakMinting();
        uint256 r = pull(alice);
        vm.roll(vm.getBlockNumber() + 3);
        deliverWord(r, wordFor(type(uint256).max));
        pool.processAcquisitions(10);
        vm.prank(keeper);
        sys.game.sync();
        assertEq(sys.game.collectionWins(), 1, "win booked");
        assertEq(sys.poolOwner.wonCount(), 1, "win recorded by the pool owner");
        (,,, uint256 wonListing,) = pool.acquisitions(r);
        assertTrue(sys.burner.released(wonListing), "milestone tier released");
        assertGe(sys.burner.milestoneIn(), reserveBefore * cfg.tiers.firstExitBps / 10_000, "an Ape exit's tier of the reserve at booking");
        assertFalse(sys.poolOwner.collectionAvailable(), "no collection NFT in the draw");
        assertBooks();
        vm.clearMockedCalls();
    }

    /// Parameters that change between listing, request and booking cannot move the books: the keeper allowance rate is
    /// frozen per listing; revenue is booked at the highest admissible edge (a lower bound) and trued up to the ETH
    /// FWA actually paid; an edge above the supported maximum closes the gate at once, with no keeper.
    function test_bookingIgnoresChangesBetweenRequestAndBooking() public {
        IFWAFactory f = IFWAFactory(cfg.fwaFactory);
        address fwaOwner = f.owner();
        // FWA lowers its edge: purchases continue at a lower fee
        vm.prank(fwaOwner);
        (bool ok,) = cfg.fwaFactory.call(abi.encodeWithSignature("setEdgeBps(uint16)", uint16(300)));
        assertTrue(ok);
        uint256 r = pull(alice);
        // governance changes markup and the keeper allowance rate while the request is in flight
        govern(address(sys.game), abi.encodeCall(CollectionGame.setPricing, (500, 100)));
        vm.roll(vm.getBlockNumber() + 3);
        deliverWord(r, wordFor(0.1 ether));
        pool.processAcquisitions(10);
        (,,, uint256 listingId,) = pool.acquisitions(r);
        (,, uint72 cost,,, uint16 opsBps,) = sys.game.items(listingId);
        assertEq(opsBps, cfg.opsBps, "frozen at listing");
        uint256 opsBefore = sys.game.keeperAllowance();
        vm.prank(keeper);
        sys.game.sync();
        assertEq(sys.game.keeperAllowance() - opsBefore, uint256(cost) * cfg.opsBps / BPS, "the listing's own rate, not the new one");
        assertEq(sys.game.revenue(), sys.game.proceedsCollected(), "trued up to what FWA paid");
        assertGt(sys.game.proceedsCollected(), 0);
        assertBooks();
        // FWA raises its edge above the supported 5%: the gate closes immediately, before any keeper acts
        vm.prank(fwaOwner);
        (ok,) = cfg.fwaFactory.call(abi.encodeWithSignature("setEdgeBps(uint16)", uint16(600)));
        assertTrue(ok);
        assertTrue(pool.localPurchasesEnabled());
        assertFalse(sys.poolOwner.canPurchase(alice), "live edge check");
    }
}
