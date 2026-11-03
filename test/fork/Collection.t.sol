// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase, IERC721Lite} from "./ForkBase.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {CollectionPoolOwner} from "../../src/core/CollectionPoolOwner.sol";
import {CollectionBurner} from "../../src/treasury/CollectionBurner.sol";
import {Governed} from "../../src/core/Governed.sol";

/// @notice Collection prizes on the real FWA pool (D59): every Ape listed at its price, gameplay credited evenly to the
///         Apes in the draw, one decay rule, the exposure target with board growth on demand, many Apes in batches,
///         wins early and late, returned deliveries, the purchase gate, and milestone releases.
contract CollectionForkTest is ForkBase {
    address alice = makeAddr("cg.player.alice");
    address bob = makeAddr("cg.player.bob");
    address carol = makeAddr("cg.player.carol");

    function setUp() public {
        deployBayc();
        launchGame(6 ether);
    }

    function _notional(uint256 id) internal view returns (uint256 n) {
        (, uint128 x,,,) = sys.poolOwner.cListings(id);
        n = x;
    }

    function _tokenOf(uint256 listingId) internal view returns (uint256 tokenId) {
        (tokenId,,,,) = sys.poolOwner.cListings(listingId);
    }

    function _refOf(uint256 listingId) internal view returns (uint256 ref) {
        (uint128 r,,,,) = sys.poolOwner.nfts(_tokenOf(listingId));
        ref = r;
    }

    /// @dev Runs the pool owner's collection step at an arbitrary cumulative turnover, as the game's maintenance would.
    function _processAt(uint256 turnover) internal {
        vm.prank(address(sys.game));
        sys.poolOwner.processCollection(turnover);
    }

    /// @dev A holder donates an Ape (registered at the bid's reference price, waits in custody until listed).
    function _donate() internal returns (uint256 tokenId) {
        tokenId = nextApeId();
        address holder = IERC721Lite(cfg.collection).ownerOf(tokenId);
        vm.startPrank(holder);
        IERC721Lite(cfg.collection).setApprovalForAll(address(sys.vault), true);
        sys.vault.contributeNFT(tokenId);
        vm.stopPrank();
    }

    function test_apeOpensAtItsPrice() public view {
        assertEq(sys.poolOwner.listedCount(), 1);
        uint256 id = sys.poolOwner.listedAt(0);
        (uint256 tokenId, uint128 n, uint128 creditStart, bool open,) = sys.poolOwner.cListings(id);
        assertTrue(open);
        assertEq(n, 6 ether, "opens at 100% of the price paid");
        assertEq(creditStart, 0);
        (uint128 ref, uint128 cash,,,) = sys.poolOwner.nfts(tokenId);
        assertEq(ref, 6 ether);
        assertEq(cash, 6 ether);
        (,,,, uint256 weight,,,) = pool.listings(id);
        assertEq(weight, uint256(1e36) / 6 ether);
        assertEq(sys.poolOwner.exposureBps(), 196, "1 / 51 = 1.96%");
        assertEq(sys.poolOwner.rowsShort(), 0);
    }

    function test_decayFollowsCreditedGameplay() public {
        uint256 id = sys.poolOwner.listedAt(0);
        _processAt(12 ether);
        assertEq(sys.poolOwner.creditPerApe(), 12 ether, "one Ape: all of it");
        assertEq(_notional(id), 4.8 ether, "6 - 0.1 x 12");
        // a small further drop is not worth an inventory change
        _processAt(12.5 ether);
        assertEq(sys.poolOwner.notionalOf(id), 4.75 ether);
        assertEq(_notional(id), 4.8 ether, "below the 5% reprice step");
        _processAt(30 ether);
        assertEq(_notional(id), 3 ether);
        (,,,,, uint256 price,,) = pool.listings(id);
        assertEq(price, 3 ether, "FWA listing repriced");
        // the decay never runs backwards, and stops at the absolute floor (1 ETH, D82)
        _processAt(1 ether);
        assertEq(_notional(id), 3 ether);
        _processAt(1_000 ether);
        assertEq(_notional(id), 1 ether);
        assertEq(sys.poolOwner.exposureBps(), 1_176, "6 / 51");
    }

    /// Gameplay is divided among the Apes in the draw: three Apes decay three times slower than one.
    function test_gameplayIsSharedAmongListedApes() public {
        accrueFees(40 ether);
        riseBidTo(6 ether);
        sellApe(nextApeId());
        riseBidTo(6 ether);
        sellApe(nextApeId());
        syncAll();
        assertEq(sys.poolOwner.listedCount(), 3);
        assertEq(sys.poolOwner.openCollection(), 3);
        _processAt(30 ether);
        assertEq(sys.poolOwner.creditPerApe(), 10 ether, "30 ETH shared by three");
        for (uint256 i; i < 3; ++i) {
            uint256 id = sys.poolOwner.listedAt(i);
            assertEq(_notional(id), _refOf(id) * 10_000 / 10_000 - 1 ether, "each fell 0.1 x 10 ETH");
        }
        assertLe(sys.poolOwner.exposureBps(), 2_000);
        // the live bid's threshold followed the last clearing price
        assertEq(sys.vault.activationThreshold(), sys.vault.lastPrice() * 7_500 / 10_000);
    }

    function test_realPullsDriveDecay() public {
        uint256 id = sys.poolOwner.listedAt(0);
        playMany(alice, 250, 3);
        uint256 t = sys.game.turnover();
        assertGt(t, 3.5 ether, "enough gameplay for a 5% step");
        window();
        syncAll();
        assertEq(sys.poolOwner.creditPerApe(), t, "every settled ETH credited to the one Ape");
        uint256 n = _notional(id);
        uint256 due = 6 ether - t / 10;
        assertLt(n, 6 ether, "decayed");
        assertGe(n, due);
        assertLe(n - due, n * 500 / 10_000 + 1, "within one reprice step of the rule");
        assertBooks();
    }

    /// No limit on Apes: every Ape held is listed, ten per maintenance call; those the target cannot hold yet wait in
    /// custody, the board grows by the rows they need once the vault can pay, and then they are listed too.
    function test_manyApesAllListedAsTheBoardGrows() public {
        for (uint256 i; i < 25; ++i) {
            _donate();
        }
        assertEq(sys.poolOwner.custodyCount(), 25);
        // up to ten per maintenance window, while the 20% target allows (on the 50-row board it binds within two)
        window();
        syncAll();
        uint256 listed = sys.poolOwner.listedCount();
        assertGt(listed, 1, "listed in the first window");
        for (uint256 i; i < 3; ++i) {
            window();
            syncAll();
            if (sys.poolOwner.listedCount() == listed) break;
            listed = sys.poolOwner.listedCount();
        }
        window();
        syncAll();
        assertEq(sys.poolOwner.listedCount(), listed, "as many as the target allows");
        assertLt(listed, 26);
        assertGt(sys.poolOwner.rowsShort(), 0, "the rest wait for rows");
        assertGt(sys.game.growthNeed(), 0, "growth beyond what the vault can pay waits");
        assertEq(sys.vault.acquisitionBudget(), 0, "the vault keeps the growth before bidding again");
        assertLe(sys.poolOwner.exposureBps(), 2_000);
        // fees arrive: the board grows, its rows are listed, then the waiting Apes
        accrueFees(20 ether);
        for (uint256 i; i < 12 && sys.poolOwner.custodyCount() != 0; ++i) {
            window();
            syncAll();
        }
        assertEq(sys.poolOwner.custodyCount(), 0, "every Ape in the draw");
        window();
        syncAll();
        assertEq(sys.poolOwner.listedCount(), 26);
        assertGt(sys.game.boardSize(), 50, "grew on demand");
        assertEq(sys.game.liveCount(), sys.game.boardSize());
        assertLe(sys.poolOwner.exposureBps(), 2_000);
        assertTrue(sys.poolOwner.canPurchase(alice));
        assertTrue(pool.localPurchasesEnabled());
        emit log_named_uint("board rows for 26 Apes at their price", sys.game.boardSize());
        assertBooks();
    }

    function _winApe(address who) internal returns (uint256 listingId) {
        uint256 r = pull(who);
        vm.roll(block.number + 3);
        deliverWord(r, wordFor(type(uint256).max));
        pool.processAcquisitions(10);
        (,,, listingId,) = pool.acquisitions(r);
        assertTrue(sys.poolOwner.isCollectionListing(listingId));
    }

    function test_apeWonEarlyWithNoReplacementKeepsShapeDrawsOpen() public {
        // fund the milestone reserve first so the release is visible
        playMany(bob, 40, 9);
        uint256 reserve = sys.burner.reserve();
        // alice's request will win the Ape; bob's is accepted before that settles and settles after it
        uint256 r = pull(alice);
        uint256 late = pull(bob);
        vm.roll(block.number + 3);
        deliverWord(r, wordFor(type(uint256).max));
        pool.processAcquisitions(1);
        (,,, uint256 listingId,) = pool.acquisitions(r);
        assertTrue(sys.poolOwner.isCollectionListing(listingId));
        assertEq(IERC721Lite(cfg.collection).ownerOf(_tokenOf(listingId)), alice, "the winner holds the Ape");
        // draws stay open for Shapes and Packs (D53), direct FWA purchases included
        assertTrue(sys.poolOwner.canPurchase(alice));
        uint256 shapeOnly = pull(carol);
        // the outstanding requests settle; the keeper books them all and admission stays open
        vm.roll(block.number + 3);
        deliverWord(late, 77);
        deliverWord(shapeOnly, 78);
        pool.processAcquisitions(10);
        (,,, uint256 shapeListing,) = pool.acquisitions(shapeOnly);
        assertFalse(sys.poolOwner.isCollectionListing(shapeListing), "a Shape or a Pack");
        uint256 releasedBefore = sys.burner.milestoneIn();
        vm.prank(keeper);
        sys.game.sync();
        assertEq(sys.game.collectionWins(), 1);
        assertEq(sys.poolOwner.wonCount(), 1, "recorded when the game booked the win");
        assertEq(sys.poolOwner.listedCount(), 0);
        assertTrue(pool.localPurchasesEnabled(), "open: Shapes and Packs only");
        assertFalse(sys.poolOwner.collectionAvailable());
        assertEq(sys.burner.milestoneIn() - releasedBefore, reserve * cfg.tiers.firstExitBps / 10_000, "an Ape exit releases its tier (D74: all)");
        assertTrue(sys.burner.released(listingId));
        // the same win can never release again, nor be recorded twice
        vm.expectRevert(CollectionBurner.AlreadyReleased.selector);
        sys.burner.release(listingId);
        assertTrue(sys.poolOwner.settleListing(listingId));
        assertEq(sys.poolOwner.wonCount(), 1);
        // the cost was paid by fee capital: it is recorded by source and not charged to game profit
        assertEq(sys.poolOwner.wonCashCost(0), 6 ether);
        assertBooks();
        // a new Ape arrives: it joins the draw
        accrueFees(20 ether);
        riseBidTo(6 ether);
        sellApe(nextApeId());
        window();
        vm.prank(keeper);
        sys.game.sync();
        assertTrue(sys.poolOwner.collectionAvailable(), "an Ape is back in the draw");
        assertTrue(pool.localPurchasesEnabled());
        assertTrue(sys.poolOwner.canPurchase(alice));
    }

    /// A win removes one Ape; the others keep their notionals and share the gameplay from then on.
    function test_winLeavesOtherApesUnchanged() public {
        accrueFees(40 ether);
        riseBidTo(6 ether);
        sellApe(nextApeId());
        syncAll();
        assertEq(sys.poolOwner.listedCount(), 2);
        _processAt(20 ether); // 10 ETH each: 6 -> 5
        uint256 won = _winApe(alice);
        uint256 other = sys.poolOwner.listedAt(0) == won ? sys.poolOwner.listedAt(1) : sys.poolOwner.listedAt(0);
        uint256 before = _notional(other);
        vm.prank(keeper);
        sys.game.sync();
        assertEq(sys.poolOwner.listedCount(), 1);
        assertEq(_notional(other), before, "its published notional is unchanged");
        // from now on the remaining Ape receives all new gameplay (sync's own turnover first)
        uint256 credit = sys.poolOwner.creditPerApe();
        uint256 credited = sys.poolOwner.creditedTurnover();
        _processAt(credited + 10 ether);
        assertEq(sys.poolOwner.creditPerApe(), credit + 10 ether);
        assertTrue(pool.localPurchasesEnabled(), "still open");
    }

    /// A small prize never releases milestone ETH; a big prize (listed at 0.5 ETH or more: the 0.5 ETH Shape) releases
    /// 15% of the reserve when the game books it (D64).
    function test_smallPrizeNeverReleasesBigPrizeReleasesItsTier() public {
        // the launch releases nothing for a big prize (D74): this exercises the tier at an owner-set 15% (D64)
        govern(address(sys.burner), abi.encodeCall(CollectionBurner.setTiers, (CollectionBurner.Tiers(0.5 ether, 1_500, 6_000, 24 hours))));
        playMany(bob, 30, 2);
        uint256 r = pull(alice);
        vm.roll(block.number + 3);
        deliverWord(r, wordFor(0.05 ether));
        pool.processAcquisitions(10);
        (,,, uint256 listingId,) = pool.acquisitions(r);
        assertFalse(sys.burner.qualifies(listingId));
        vm.expectRevert(CollectionBurner.NotQualifying.selector);
        sys.burner.release(listingId);
        assertFalse(sys.poolOwner.settleListing(listingId), "not a collection listing");
        // the 0.5 ETH Shape
        uint256 r2 = pull(alice);
        vm.roll(block.number + 3);
        deliverWord(r2, wordFor(0.5 ether));
        pool.processAcquisitions(10);
        (,,, uint256 big,) = pool.acquisitions(r2);
        assertTrue(sys.burner.qualifies(big));
        assertEq(sys.burner.releaseBps(big), 1_500);
        uint256 reserve = sys.burner.reserve();
        uint256 in0 = sys.burner.milestoneIn();
        window();
        vm.prank(keeper);
        sys.game.sync();
        assertTrue(sys.burner.released(big), "released by the game at booking");
        assertEq(sys.burner.milestoneIn() - in0, reserve * 1_500 / 10_000, "15% of the reserve");
        assertEq(sys.burner.exitReleases(), 0);
        // nor does an unwon collection listing
        uint256 ape = sys.poolOwner.listedAt(0);
        vm.expectRevert(CollectionBurner.NotQualifying.selector);
        sys.burner.release(ape);
    }

    function test_failedApeDeliveryReturnsToCustodyWithoutRelease() public {
        playMany(bob, 30, 4);
        window();
        syncAll();
        uint256 published = _notional(sys.poolOwner.listedAt(0));
        uint256 r = pull(alice);
        vm.roll(block.number + 3);
        uint256 w = wordFor(type(uint256).max);
        vm.mockCallRevert(cfg.collection, abi.encodeWithSignature("transferFrom(address,address,uint256)"), "");
        deliverWord(r, w);
        pool.processAcquisitions(10);
        vm.clearMockedCalls();
        (,,, uint256 listingId,) = pool.acquisitions(r);
        assertEq(uint8(statusOf(r)), uint8(IFWAPool.AcquisitionStatus.DeliveryPending));
        vm.prank(keeper);
        sys.game.sync();
        assertFalse(sys.poolOwner.collectionAvailable(), "out of the draw while delivery is pending");
        assertEq(sys.poolOwner.exposureSum(), 0);
        assertTrue(pool.localPurchasesEnabled(), "Shape and Pack draws continue meanwhile (D53)");
        assertFalse(sys.burner.qualifies(listingId));
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(alice);
        pool.refundFailedDelivery(listingId);
        vm.prank(keeper);
        sys.game.sync();
        assertEq(sys.poolOwner.wonCount(), 0);
        assertFalse(sys.burner.released(listingId));
        // back in custody, relisted at its last notional (never higher), its decay resuming where it was
        window();
        syncAll();
        assertEq(sys.poolOwner.custodyCount(), 0);
        uint256 relisted = sys.poolOwner.listedAt(0);
        assertTrue(relisted != listingId);
        assertEq(_notional(relisted), published);
        assertEq(sys.poolOwner.notionalOf(relisted), published, "back-dated: no jump, no pause");
        assertTrue(pool.localPurchasesEnabled());
        assertEq(sys.game.collectionWins(), 0);
    }

    function test_listingParamsApplyForwardAndNeverRaise() public {
        uint256 id = sys.poolOwner.listedAt(0);
        _processAt(12 ether);
        assertEq(_notional(id), 4.8 ether);
        CollectionPoolOwner.ListingParams memory p = sys.poolOwner.listingParams();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Governed.NotOwner.selector);
        sys.poolOwner.setListingParams(p);
        // a higher opening never raises a published notional
        p.startBps = 20_000;
        govern(address(sys.poolOwner), abi.encodeCall(CollectionPoolOwner.setListingParams, (p)));
        assertEq(sys.poolOwner.notionalOf(id), 4.8 ether);
        _processAt(13 ether);
        assertEq(_notional(id), 4.8 ether);
        // a faster decay applies to every Ape from its next update
        p.startBps = 10_000;
        p.decayBps = 2_000;
        govern(address(sys.poolOwner), abi.encodeCall(CollectionPoolOwner.setListingParams, (p)));
        _processAt(14 ether);
        assertEq(_notional(id), 3.2 ether, "6 - 0.2 x 14");
        // bounds
        p.minNotionalWei = 0.01 ether - 1; // below the floor's lower bound
        vm.prank(owner);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.poolOwner.setListingParams(p);
        p.minNotionalWei = 1 ether;
        p.targetBps = 5_001;
        vm.prank(owner);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.poolOwner.setListingParams(p);
        p.targetBps = 1_500;
        p.minNotionalWei = 100 ether + 1; // above its upper bound
        vm.prank(owner);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.poolOwner.setListingParams(p);
    }

    /// D78: the decay clock is off at launch; switched on later it runs from then (never back to launch), adds to
    /// the gameplay decay, stops when switched off, and keeps the floor.
    function test_timeDecayStartsOffAndRunsFromSwitchOn() public {
        uint256 id = sys.poolOwner.listedAt(0);
        CollectionPoolOwner.ListingParams memory p = sys.poolOwner.listingParams();
        assertEq(p.dailyDecayBps, 0, "off at launch");
        vm.warp(block.timestamp + 30 days);
        assertEq(sys.poolOwner.decayClock(), 0);
        assertEq(sys.poolOwner.notionalOf(id), 6 ether, "idle: no time decay while off");
        p.dailyDecayBps = 100; // 1% of its price a day: 0.06 ETH
        govern(address(sys.poolOwner), abi.encodeCall(CollectionPoolOwner.setListingParams, (p)));
        assertEq(sys.poolOwner.notionalOf(id), 6 ether, "the 30 idle days are not counted");
        vm.warp(block.timestamp + 10 days);
        assertEq(sys.poolOwner.notionalOf(id), 5.4 ether, "6 - 0.06 x 10");
        _processAt(0);
        assertEq(_notional(id), 5.4 ether, "repriced at FWA with no gameplay");
        _processAt(12 ether);
        assertEq(_notional(id), 4.2 ether, "6 - 0.1 x 12 - 0.6");
        // switched off: the clock stops where it is
        p.dailyDecayBps = 0;
        govern(address(sys.poolOwner), abi.encodeCall(CollectionPoolOwner.setListingParams, (p)));
        vm.warp(block.timestamp + 10 days);
        assertEq(sys.poolOwner.notionalOf(id), 4.2 ether, "stopped");
        // the floor holds however fast it runs
        p.dailyDecayBps = 10_000;
        govern(address(sys.poolOwner), abi.encodeCall(CollectionPoolOwner.setListingParams, (p)));
        vm.warp(block.timestamp + 1 days);
        assertEq(sys.poolOwner.notionalOf(id), 1 ether, "the absolute floor");
        _processAt(12 ether);
        assertEq(_notional(id), 1 ether);
        p.dailyDecayBps = 10_001;
        vm.prank(owner);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.poolOwner.setListingParams(p);
    }

    /// @dev An Ape decays with the given rates, a pull of it fails delivery and is refunded, and it is relisted.
    function _relistWithRates(uint256 decayBps, uint256 dailyDecayBps) internal returns (uint256 published, uint256 relisted) {
        CollectionPoolOwner.ListingParams memory p = sys.poolOwner.listingParams();
        p.decayBps = decayBps;
        p.dailyDecayBps = dailyDecayBps;
        govern(address(sys.poolOwner), abi.encodeCall(CollectionPoolOwner.setListingParams, (p)));
        playMany(bob, 30, 4);
        vm.warp(block.timestamp + 10 days);
        window();
        syncAll();
        published = _notional(sys.poolOwner.listedAt(0));
        assertLt(published, 6 ether, "decayed before the pull");
        uint256 r = pull(alice);
        vm.roll(block.number + 3);
        uint256 w = wordFor(type(uint256).max);
        vm.mockCallRevert(cfg.collection, abi.encodeWithSignature("transferFrom(address,address,uint256)"), "");
        deliverWord(r, w);
        pool.processAcquisitions(10);
        vm.clearMockedCalls();
        (,,, uint256 listingId,) = pool.acquisitions(r);
        vm.prank(keeper);
        sys.game.sync();
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(alice);
        pool.refundFailedDelivery(listingId);
        vm.prank(keeper);
        sys.game.sync();
        window();
        syncAll();
        relisted = sys.poolOwner.listedAt(0);
        assertTrue(relisted != listingId);
        assertEq(_notional(relisted), published, "relisted at its last notional");
    }

    /// @dev The relisted Ape decays on from `published` at once (the relisting's maintenance ran minutes ago) and at
    ///      the full rate, 0.06 ETH a day.
    function _resumesAt(uint256 relisted, uint256 published) internal {
        uint256 now_ = sys.poolOwner.notionalOf(relisted);
        assertLe(now_, published, "no jump");
        assertGt(now_ + 0.001 ether, published, "no pause: only minutes of decay since the relisting");
        vm.warp(block.timestamp + 5 days);
        assertApproxEqAbs(sys.poolOwner.notionalOf(relisted), now_ - 0.3 ether, 1, "0.06 x 5");
    }

    /// D78: a relisted Ape's time decay resumes where its notional left it, with no pause.
    function test_relistedApeResumesTimeDecay() public {
        (uint256 published, uint256 relisted) = _relistWithRates(0, 100);
        _resumesAt(relisted, published);
    }

    /// D78: with both decays on, what the gameplay credit cannot back-date goes on the decay clock.
    function test_relistedApeResumesBothDecays() public {
        (uint256 published, uint256 relisted) = _relistWithRates(1_000, 100);
        assertGt(6 ether - published, sys.poolOwner.creditPerApe() / 10, "the drop exceeds what the credit covers");
        _resumesAt(relisted, published);
    }

    /// A target the listings already exceed defers decay (and asks for rows); it never closes the purchase gate.
    function test_lowerTargetDefersDecayGateStaysOpen() public {
        uint256 id = sys.poolOwner.listedAt(0);
        CollectionPoolOwner.ListingParams memory p = sys.poolOwner.listingParams();
        p.targetBps = 100;
        govern(address(sys.poolOwner), abi.encodeCall(CollectionPoolOwner.setListingParams, (p)));
        _processAt(30 ether);
        assertEq(_notional(id), 6 ether, "deferred: 1 / (51 - 8) > 1%");
        assertGt(sys.poolOwner.rowsShort(), 0);
        assertTrue(sys.poolOwner.canPurchase(address(this)), "the gate's ceiling is 50%");
        assertTrue(pool.localPurchasesEnabled());
    }

    /// Audit (D66, D82): an NFT sold to the vault for 1 wei is valued at `MIN_REF_COST` for exposure (no division by a
    /// dust reference) and listed at the absolute floor, never below it; its cash cost stays 1 wei.
    function test_tinyReferenceIsFlooredAndMaintenanceKeepsWorking() public {
        accrueFees(10 ether);
        sys.vault.sweep();
        uint256 id = nextApeId();
        sellApeAt(id, 1);
        (uint128 ref, uint128 cash,,,) = sys.poolOwner.nfts(id);
        assertEq(ref, sys.poolOwner.MIN_REF_COST());
        assertEq(cash, 1);
        window();
        syncAll();
        assertEq(sys.poolOwner.custodyCount(), 0, "listed");
        // play credits gameplay to both Apes; neither falls below the absolute floor
        playMany(alice, 60, 21);
        window();
        syncAll();
        uint256 turnover = sys.game.turnover();
        vm.prank(address(sys.game));
        sys.poolOwner.processCollection(turnover); // the call that used to divide by zero
        for (uint256 i; i < sys.poolOwner.listedCount(); ++i) {
            uint256 lid = sys.poolOwner.listedAt(i);
            assertGe(sys.poolOwner.notionalOf(lid), sys.poolOwner.listingParams().minNotionalWei);
        }
        assertBooks();
    }

    /// Audit (D67): a collection listing "won" by the FWA pool itself (the NFT never moves) releases nothing from the
    /// milestone reserve; the same listing won by a player releases the first-exit share.
    function test_poolSelfWinReleasesNothing() public {
        uint256 id = sys.poolOwner.listedAt(0);
        (address coll, address dep,, uint256 tokenId, uint256 w, uint256 price, uint256 slot,) = pool.listings(id);
        vm.mockCall(address(pool), abi.encodeWithSelector(IFWAPool.listings.selector, id),
            abi.encode(coll, dep, address(pool), tokenId, w, price, slot, IFWAPool.ListingStatus.Settled));
        assertEq(sys.burner.releaseBps(id), 0, "the pool's own win");
        vm.mockCall(address(pool), abi.encodeWithSelector(IFWAPool.listings.selector, id),
            abi.encode(coll, dep, alice, tokenId, w, price, slot, IFWAPool.ListingStatus.Settled));
        assertEq(sys.burner.releaseBps(id), cfg.tiers.firstExitBps, "a player's win: the first exit");
        vm.clearMockedCalls();
    }

    function test_onlyGameDrivesThePoolOwner() public {
        vm.expectRevert(CollectionPoolOwner.NotGame.selector);
        sys.poolOwner.processCollection(1);
        vm.expectRevert(CollectionPoolOwner.NotGame.selector);
        sys.poolOwner.setAcquisitions(true);
        vm.expectRevert(CollectionPoolOwner.NotGame.selector);
        sys.poolOwner.withdrawCollection();
        vm.expectRevert(CollectionPoolOwner.NotVault.selector);
        sys.poolOwner.register(1, 1, 1, 0);
        vm.prank(owner);
        vm.expectRevert(CollectionPoolOwner.NotGame.selector);
        sys.poolOwner.retirePool();
        // recording an outcome is anyone's: it only follows FWA (an Active listing records nothing)
        uint256 id = sys.poolOwner.listedAt(0);
        vm.prank(makeAddr("anyone"));
        assertTrue(sys.poolOwner.settleListing(id));
        assertEq(sys.poolOwner.openCollection(), 1);
    }
}

/// @notice Board growth on demand: with a 3% target and a fast decay, real play reaches the target on the 50-row
///         board; decay waits, the game grows the board by the rows the pool owner asks for once the vault can pay,
///         and decay resumes.
contract CollectionGrowthForkTest is ForkBase {
    address alice = makeAddr("cg.player.alice");

    function setUp() public {
        setUpFork();
        cfg = _baycConfig(owner);
        cfg.listing.targetBps = 300;
        cfg.listing.decayBps = 10_000; // 1 ETH per ETH of gameplay
        cfg.settings.continuityShareBps = 0; // surplus to buybacks only, so the vault cannot fund growth until fees come
        cfg.openingAllowance = 0; // (unspent at a zero test gas price, it would stay in the vault and fund growth)
        _deploy();
        launchGame(6 ether);
    }

    function _notional(uint256 id) internal view returns (uint256 n) {
        (, uint128 x,,,) = sys.poolOwner.cListings(id);
        n = x;
    }

    function test_targetDefersDecayAndGrowthResumesIt() public {
        uint256 id = sys.poolOwner.listedAt(0);
        playMany(alice, 300, 8);
        window();
        syncAll();
        assertEq(sys.game.collectionWins(), 0);
        uint256 h = sys.poolOwner.gateHeadroom();
        // 6 / n <= 0.03 x (rows + 1 - h): on 50 rows with K = 3, n >= 6 / (0.03 x 44) = 4.55 ETH; decay steps a
        // window at a time, so it stops within one window's decay (about 0.2 ETH of credited play here) above that
        uint256 rows = sys.game.boardSize();
        uint256 stop = 6 ether * 10_000 / (300 * (rows + 1 - h));
        uint256 n = _notional(id);
        assertGe(n, stop);
        assertLt(n, stop * 11_000 / 10_000, "within a window's decay of where the target stops it");
        assertGt(sys.poolOwner.rowsShort(), 0, "rows asked for");
        assertEq(sys.game.boardSize(), 50, "no growth until the vault can fund it");
        assertEq(sys.game.growthNeed(), sys.poolOwner.rowsShort() * sys.game.rowCost());
        // fee funding arrives: the board grows by the rows asked for, they are listed, decay resumes
        accrueFees(10 ether);
        for (uint256 i; i < 6; ++i) {
            window();
            syncAll();
        }
        assertGt(sys.game.boardSize(), 50, "grown on demand");
        assertEq(sys.game.liveCount(), sys.game.boardSize());
        uint256 n2 = _notional(id);
        assertLt(n2, n, "decay resumed");
        assertLe(sys.poolOwner.exposureBps(), 300);
        (,,,, uint256 w,,,) = pool.listings(id);
        assertEq(w, uint256(1e36) / n2);
        assertBooks();
    }
}
