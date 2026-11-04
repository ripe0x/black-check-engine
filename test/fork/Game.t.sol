// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase, IPacksView} from "./ForkBase.sol";
import {IFWAPool, IFWAFactory} from "../../src/interfaces/IFWA.sol";
import {CollectionGame} from "../../src/game/CollectionGame.sol";

interface IShapesView {
    function ownerOf(uint256) external view returns (address);
    function backingOf(uint256) external view returns (uint256);
    function mintFee() external view returns (uint256);
    function admin() external view returns (address);
    function setMintFee(uint256 newFee) external;
}

/// @notice The ordinary game on the real FWA pool: booking, replenishment, expensive streaks, refunds, failed
///         deliveries, keeper interruption and FWA setting changes.
contract GameForkTest is ForkBase {
    address alice = makeAddr("cg.player.alice");
    address bob = makeAddr("cg.player.bob");

    function setUp() public {
        deployChecks();
        launchGame(0.25 ether);
    }

    /// The opening board (D45): 48 x 0.01 Shape, 32 x 0.02 Pack, 7 x 0.03 Pack, 1 x 0.04 Pack, 7 x 0.05 Shape,
    /// 1 x 0.06 Pack, 1 x 0.1 Shape, 1 x 0.15 Pack, 1 x 0.5 Shape, 1 x 1 ETH Shape. Each Pack is a real Draw Pack
    /// holding the fewest Shapes that add up to its backing (0.06 = 0.05 + 0.01, 0.15 = 0.1 + 0.05), carried at its
    /// backing plus every Shapes mint fee, and listed at 5% over that.
    function test_boardListedAtMarkupOverFullCost() public view {
        assertEq(sys.game.liveCount(), 50);
        uint256 total;
        uint256 totalCost;
        uint256 shapeCount;
        uint256[10] memory want = [uint256(24), 16, 3, 1, 3, 0, 1, 1, 1, 0];
        uint256[10] memory counts;
        for (uint256 i; i < 50; ++i) {
            (uint256 t, uint256 backing, uint256 cost, uint256 n) = _checkPrize(sys.game.liveAt(i));
            ++counts[t];
            shapeCount += n;
            total += backing;
            totalCost += cost;
        }
        for (uint256 k; k < 10; ++k) {
            assertEq(counts[k], want[k]);
        }
        assertEq(shapeCount, 76);
        assertEq(total, 1.59 ether, "1.59 ETH of backing");
        assertEq(totalCost, 1.666 ether, "plus 76 Shapes mint fees");
        assertEq(sys.game.inventoryCost(), 1.666 ether);
    }

    /// @dev Checks one listed prize and returns its tier, backing, cost and Shape count.
    function _checkPrize(uint256 id) internal view returns (uint256 t, uint256 backing, uint256 cost, uint256 n) {
        uint256[10] memory values = [
            uint256(0.01 ether), 0.02 ether, 0.03 ether, 0.04 ether, 0.05 ether, 0.06 ether, 0.1 ether, 0.15 ether,
            0.5 ether, 1 ether
        ];
        uint256[10] memory fewest = [uint256(1), 2, 3, 4, 1, 2, 1, 2, 1, 1];
        (uint48 tokenId, uint72 b, uint72 c,, uint16 markup,, bool isPack) = sys.game.items(id);
        (backing, cost) = (b, c);
        (address coll,,,,, uint256 price,,) = pool.listings(id);
        assertEq(price, cost * 11_000 / 10_000, "10% over full replacement cost");
        assertEq(markup, 1_000);
        t = 10;
        for (uint256 k; k < 10; ++k) {
            if (values[k] == backing) t = k;
        }
        assertLt(t, 10, "a board tier");
        n = fewest[t];
        assertEq(isPack, n > 1);
        assertEq(cost, backing + n * IShapesView(cfg.shapes).mintFee(), "every underlying mint fee carried");
        if (!isPack) {
            assertEq(coll, cfg.shapes);
            return (t, backing, cost, n);
        }
        assertEq(coll, sys.packs);
        assertEq(IPacksView(sys.packs).valueOf(tokenId), backing, "Pack value = its Shapes' backing");
        assertEq(IPacksView(sys.packs).ownerOf(tokenId), address(pool), "Pack held by FWA");
        uint256[] memory inside = IPacksView(sys.packs).contentsOf(tokenId);
        assertEq(inside.length, n, "the fewest Shapes");
        uint256 sum;
        for (uint256 k; k < inside.length; ++k) {
            sum += IShapesView(cfg.shapes).backingOf(inside[k]);
        }
        assertEq(sum, backing, "exact redeemable backing");
    }

    function test_captureBookedToTheWeiAndShapeDelivered() public {
        uint256 r = pull(alice);
        (,, uint256 paid,,) = pool.acquisitions(r);
        vm.roll(vm.getBlockNumber() + 3);
        uint256 w = wordFor(0.1 ether);
        deliverWord(r, w);
        pool.processAcquisitions(10);
        (,,, uint256 listingId, IFWAPool.AcquisitionStatus st) = pool.acquisitions(r);
        assertEq(uint8(st), uint8(IFWAPool.AcquisitionStatus.Fulfilled));
        (uint48 tokenId,,,,,,) = sys.game.items(listingId);
        assertEq(IShapesView(cfg.shapes).ownerOf(tokenId), alice, "player holds the Shape");
        assertEq(IShapesView(cfg.shapes).backingOf(tokenId), 0.1 ether, "redeemable backing");
        uint256 fwaProceeds = pool.ownerProceeds();
        vm.prank(keeper);
        sys.game.sync();
        assertEq(sys.game.revenue(), fwaProceeds, "booked to the wei: estimate, then trued up to FWA's split");
        assertEq(sys.game.turnover(), paid);
        assertEq(sys.game.prizeExpense(), 0.101 ether);
        assertEq(sys.game.replacementsOwed(), 0.101 ether, "row owed until the window");
        window();
        vm.prank(keeper);
        sys.game.sync();
        assertEq(sys.game.liveCount(), sys.game.boardSize(), "replaced");
        assertBooks();
    }

    function test_sustainedOrdinaryPlayReconciles() public {
        playMany(alice, 120, 7);
        assertGt(sys.game.pullsFulfilled(), 100);
        assertBooks();
        emit log_named_int("profit after 120 pulls (wei)", sys.game.profit());
        emit log_named_uint("distributed", sys.game.distributed());
        emit log_named_uint("refunded", sys.game.pullsRefunded());
        assertEq(sys.game.liveCount(), sys.game.boardSize(), "board full after windows");
    }

    /// Audit round 3 (D68): Shapes' own admin may change its mint fee, part of every prize's cost. What the game owes
    /// for won rows follows today's fee: each sync first recounts it when the fee has moved, so nothing is paid out
    /// against a stale debt, and a restock leaves neither a shortfall nor a phantom debt.
    function test_mintFeeChangeRecountsWhatTheGameOwes() public {
        IShapesView shapes = IShapesView(cfg.shapes);
        uint256 fee0 = shapes.mintFee();
        pullAndSettle(alice, wordFor(0.01 ether));
        pullAndSettle(alice, wordFor(0.01 ether));
        vm.prank(keeper);
        sys.game.sync(); // booked; no maintenance window yet, so the rows stay owed
        uint256 n = sys.game.owedCount();
        assertEq(n, 2);
        assertEq(sys.game.replacementsOwed(), n * (0.01 ether + fee0));
        // Shapes' admin raises the fee; the next sync with work (another win to book) recounts first, before anything
        // is booked or paid out, and the new row is owed at today's cost too
        vm.prank(shapes.admin());
        shapes.setMintFee(0.005 ether);
        pullAndSettle(alice, wordFor(0.01 ether));
        vm.prank(keeper);
        sys.game.sync();
        assertEq(sys.game.owedFee(), 0.005 ether);
        assertEq(sys.game.replacementsOwed(), sys.game.owedCount() * 0.015 ether, "owed at today's cost");
        restockAll();
        assertEq(sys.game.owedCount(), 0);
        assertEq(sys.game.replacementsOwed(), 0, "no phantom debt");
        // the fee falls to zero: a new win is owed at its backing alone, and restocking clears it exactly
        vm.prank(shapes.admin());
        shapes.setMintFee(0);
        pullAndSettle(alice, wordFor(0.01 ether));
        vm.prank(keeper);
        sys.game.sync();
        assertEq(sys.game.replacementsOwed(), sys.game.owedCount() * 0.01 ether);
        restockAll();
        assertEq(sys.game.replacementsOwed(), 0);
        assertBooks();
    }

    function test_consecutiveExpensiveWins() public {
        uint256 cashBefore = sys.game.cash();
        // the board's four most expensive prizes back to back: 0.5, 0.1, then two 0.05 ETH Shapes
        uint256[4] memory wants = [uint256(0.5 ether), 0.1 ether, 0.05 ether, 0.05 ether];
        for (uint256 i; i < 4; ++i) {
            uint256 r = pull(alice);
            vm.roll(vm.getBlockNumber() + 3);
            deliverWord(r, wordFor(wants[i]));
            pool.processAcquisitions(10);
        }
        vm.prank(keeper);
        sys.game.sync();
        assertLt(sys.game.profit(), 0, "a loss");
        assertEq(sys.game.distributed(), 0, "nothing distributed while a loss is carried");
        // four rows were waiting and nothing was in flight: the operating reserve paid the replacements at once
        assertEq(sys.game.replacementsOwed(), 0);
        assertEq(sys.game.liveCount(), sys.game.boardSize(), "replaced from the reserve");
        assertLt(sys.game.cash(), cashBefore, "reserve drawn down");
        assertGt(sys.game.capitalNeed(), 0, "the game now needs capital back up to its reserve");
        assertBooks();
        // trading fees top up the reserve, but never erase the carried loss
        int256 lossBefore = sys.game.profit();
        uint256 paidBefore = sys.game.keeperPaid();
        accrueFees(5 ether);
        vm.prank(keeper);
        sys.game.sync();
        // the only profit change is the keeper's pay for this call (an expense: the flat fee even at a zero gas price)
        assertEq(sys.game.profit(), lossBefore - int256(sys.game.keeperPaid() - paidBefore), "fee income is capital, not profit");
        // restored from fees, less the keeper's pay taken after the refill (dust the next refill covers, unpaid: D63)
        assertEq(sys.game.capitalNeed(), sys.game.keeperPaid() - paidBefore, "reserve restored from fees");
        assertEq(sys.game.distributed(), 0);
        assertBooks();
    }

    function test_inFlightBoundRefusesBeforeAnyFeeAndCapsDrift() public {
        // at K = 3 (D65's value), drift on one quote stays inside FWA's 10% slippage in the worst case
        govern(address(sys.poolOwner), abi.encodeWithSignature("setMaxInFlight(uint256)", 3));
        // maxInFlight requests on one quote are admitted; the next is refused by the purchase gate before paying
        uint256 k = sys.poolOwner.maxInFlight();
        uint256[] memory rs = new uint256[](k);
        for (uint256 i; i < k; ++i) {
            rs[i] = pull(alice);
        }
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        uint256 version = pool.inventoryVersion();
        vm.deal(bob, 1 ether);
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        vm.expectRevert(bytes4(0x24e6a72a)); // PurchaseNotAllowed
        pool.acquire{value: total}(bob, fee, 0, 10_000, version, vm.getBlockTimestamp() + 1);
        assertEq(bob.balance, bobBefore, "refused, not refunded: no VRF fee lost");
        // worst case for the admitted requests: every one takes the cheapest prize; drift stays inside FWA's 10%
        vm.roll(vm.getBlockNumber() + 3);
        for (uint256 i; i < k; ++i) {
            deliverWord(rs[i], wordFor(0.01 ether));
            pool.processAcquisitions(1);
            assertEq(uint8(statusOf(rs[i])), uint8(IFWAPool.AcquisitionStatus.Fulfilled), "no refund");
        }
        vm.prank(keeper);
        sys.game.sync();
        assertEq(sys.game.pullsRefunded(), 0);
        assertBooks();
    }

    /// D82: at the launch bound (K = 10, FWA's own limit) the same worst case (every request on one quote takes the
    /// cheapest prize) drifts past FWA's 10% slippage for the later requests, which FWA refunds. Measured, not a bound.
    function test_launchInFlightBoundWorstCaseDrift() public {
        uint256 k = sys.poolOwner.maxInFlight();
        assertEq(k, 10);
        uint256[] memory rs = new uint256[](k);
        for (uint256 i; i < k; ++i) {
            rs[i] = pull(alice);
        }
        vm.roll(vm.getBlockNumber() + 3);
        uint256 refunded;
        for (uint256 i; i < k; ++i) {
            deliverWord(rs[i], wordFor(0.01 ether));
            pool.processAcquisitions(1);
            if (statusOf(rs[i]) != IFWAPool.AcquisitionStatus.Fulfilled) ++refunded;
        }
        emit log_named_uint("worst-case requests refunded of 10", refunded);
        vm.prank(keeper);
        sys.game.sync();
        assertEq(sys.game.pullsRefunded(), refunded, "the game books every refund");
        assertBooks();
    }

    function _failDelivery(address who, uint256 want, address token) internal returns (uint256 r, uint256 listingId) {
        r = pull(who);
        vm.roll(vm.getBlockNumber() + 3);
        uint256 w = wordFor(want);
        vm.mockCallRevert(token, abi.encodeWithSignature("transferFrom(address,address,uint256)"), "");
        deliverWord(r, w);
        pool.processAcquisitions(10);
        vm.clearMockedCalls();
        assertEq(uint8(statusOf(r)), uint8(IFWAPool.AcquisitionStatus.DeliveryPending));
        (,,, listingId,) = pool.acquisitions(r);
    }

    function test_failedShapeDeliveryRecoveredAndBurned() public {
        (, uint256 listingId) = _failDelivery(alice, 0.05 ether, cfg.shapes);
        vm.prank(keeper);
        sys.game.sync();
        assertEq(sys.game.openCount(), 1, "pending delivery stays open, walk continues");
        for (uint256 i; i < sys.game.liveCount(); ++i) {
            assertTrue(sys.game.liveAt(i) != listingId, "off the board");
        }
        assertEq(sys.game.owedCount(), 1, "its row is owed");
        pullAndSettle(bob, 99);
        window();
        vm.prank(keeper);
        sys.game.sync();
        assertEq(sys.game.liveCount(), sys.game.boardSize(), "row replaced while the delivery is pending");
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        vm.prank(alice);
        pool.refundFailedDelivery(listingId);
        (uint48 tokenId, uint72 backing, uint72 cost,,,,) = sys.game.items(listingId);
        uint256 expense = sys.game.prizeExpense();
        vm.prank(keeper);
        sys.game.sync();
        assertEq(sys.game.openCount(), 0);
        assertEq(sys.game.prizeExpense() - expense, cost - backing, "only the mint fee written off");
        vm.expectRevert();
        IShapesView(cfg.shapes).ownerOf(tokenId);
        assertEq(sys.game.deliveriesRefunded(), 1);
        assertBooks();
    }

    function test_keeperInterruptionAndRecovery() public {
        // forty pulls with no keeper at all: FWA settles (the VRF callback and anyone's processAcquisitions)
        for (uint256 i; i < 40; ++i) {
            if (!canPull(alice)) break; // the live gate closes before the unattended board gets unsafe
            pullAndSettle(alice, uint256(keccak256(abi.encode("gap", i))));
        }
        uint256 issued = pool.lastIssuedSequence();
        assertEq(sys.game.seenSeq(), 1, "nothing booked yet");
        // a keeper returns days later; bounded batches make progress and nothing is double-booked
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.prank(keeper);
        sys.game.sync();
        uint256 k = sys.game.bookPerCall();
        assertEq(sys.game.seenSeq(), issued < k ? issued + 1 : k + 1);
        syncAll();
        window();
        syncAll();
        assertEq(sys.game.seenSeq(), issued + 1);
        assertEq(sys.game.pullsFulfilled() + sys.game.pullsRefunded() + sys.game.pullsExpired(), issued);
        assertEq(sys.game.liveCount(), sys.game.boardSize());
        // nothing to do: a keeper is refused and paid nothing
        vm.prank(keeper);
        vm.expectRevert(CollectionGame.NoWork.selector);
        sys.game.sync();
        assertBooks();
    }

    function test_expiredRequestBookedWithoutRevenue() public {
        uint256 r = pull(alice);
        vm.roll(vm.getBlockNumber() + 40); // past selectionTimeoutBlocks with no word
        pool.processAcquisitions(10);
        assertEq(uint8(statusOf(r)), uint8(IFWAPool.AcquisitionStatus.Expired));
        vm.prank(keeper);
        sys.game.sync();
        assertEq(sys.game.pullsExpired(), 1);
        assertEq(sys.game.revenue(), 0);
        assertGt(pool.acquisitionRefundCredit(alice), 0);
    }

    function test_fwaCooldownOrEdgeChangeClosesAdmissionSafely() public {
        IFWAFactory f = IFWAFactory(cfg.fwaFactory);
        address fwaOwner = f.owner();
        uint256 r = pull(alice); // in flight when the change lands
        // FWA raises its inventory cooldown: purchases stay open (D82: `maxCooldown` 30 days, above FWA's own 7-day
        // maximum; a slow relist is covered by the live-rows rule), settlement continues
        vm.prank(fwaOwner);
        (bool ok,) = cfg.fwaFactory.call(abi.encodeWithSignature("setInventoryChangeCooldown(uint32)", uint32(1 hours)));
        if (!ok) {
            vm.mockCall(cfg.fwaFactory, abi.encodeWithSignature("inventoryChangeCooldown()"), abi.encode(1 hours));
        }
        emit log_named_uint("real FWA setter used (1) or mocked (0)", ok ? 1 : 0);
        vm.prank(keeper);
        try sys.game.sync() {} catch {}
        assertTrue(pool.localPurchasesEnabled(), "a cooldown alone does not close purchases");
        vm.roll(vm.getBlockNumber() + 3);
        deliverWord(r, 5);
        pool.processAcquisitions(10);
        vm.prank(keeper);
        sys.game.sync();
        assertEq(sys.game.pullsFulfilled(), 1, "settlement continues while closed");
        vm.clearMockedCalls();
        if (ok) {
            vm.prank(fwaOwner);
            cfg.fwaFactory.call(abi.encodeWithSignature("setInventoryChangeCooldown(uint32)", uint32(0)));
        }
        window();
        vm.prank(keeper);
        try sys.game.sync() {} catch {}
        assertTrue(pool.localPurchasesEnabled(), "still open");
        // an edge above the supported 5% closes purchases
        vm.prank(fwaOwner);
        (bool okEdge,) = cfg.fwaFactory.call(abi.encodeWithSignature("setEdgeBps(uint16)", uint16(800)));
        assertTrue(okEdge, "real FWA edge setter");
        vm.prank(keeper);
        sys.game.sync();
        assertFalse(pool.localPurchasesEnabled());
        vm.clearMockedCalls();
        assertBooks();
    }

    function test_guardianPauseKeepsSettlementAndRefunds() public {
        uint256 r = pull(alice);
        vm.prank(owner);
        sys.game.setPaused(true);
        assertFalse(pool.localPurchasesEnabled());
        vm.roll(vm.getBlockNumber() + 3);
        deliverWord(r, 3);
        pool.processAcquisitions(10);
        vm.prank(keeper);
        sys.game.sync();
        assertEq(sys.game.pullsFulfilled(), 1);
        // the guardian can do nothing else
        vm.prank(owner);
        vm.expectRevert();
        sys.game.setSettings(CollectionGame.Settings(0, 0, 0, 0, 0, 0, 0, 0));
        vm.prank(owner);
        sys.game.setPaused(false);
        assertTrue(pool.localPurchasesEnabled());
    }

    /// Keepers are paid by the game (gas plus the margin) within the allowance captures earn (D63).
    function test_capturesFundKeepers() public {
        vm.txGasPrice(0.5 gwei); // keepers' transactions pay gas, so the game reimburses it
        playMany(alice, 60, 11);
        vm.txGasPrice(0);
        assertGt(sys.game.keeperAllowance(), cfg.openingAllowance);
        assertGt(sys.game.keeperPaid(), 0, "keepers were tipped");
        assertGt(keeper.balance, 0);
        assertBooks();
    }
}
