// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase, IERC721Lite} from "./ForkBase.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {CollectionPoolOwner} from "../../src/core/CollectionPoolOwner.sol";
import {CollectionBurner} from "../../src/treasury/CollectionBurner.sol";
import {Governed} from "../../src/core/Governed.sol";

/// @notice Checks prizes on the real FWA pool: every Check listed at its tier's schedule price (D003), survival counted
///         from FWA's own records (C010, D002), decay per survived draw to the floor (D005), schedule changes through
///         the council (D012), the exposure target with board growth on demand, wins early and late, returned
///         deliveries, the purchase gate, and milestone releases.
/// @dev Provenance: ripe0x/collection-games `test/fork/Collection.t.sol` (409ca75); the Ape decay tests are replaced by
///      survival and schedule tests, the rest ported to Checks prices.
contract CollectionForkTest is ForkBase {
    address alice = makeAddr("cg.player.alice");
    address bob = makeAddr("cg.player.bob");
    address carol = makeAddr("cg.player.carol");
    uint256 constant P = 0.25 ether; // the 80-Check schedule price at launch

    function setUp() public {
        deployChecks();
        launchGame(cfg.refPrice);
    }

    function _notional(uint256 id) internal view returns (uint256 n) {
        (, uint128 x,,,,) = sys.poolOwner.cListings(id);
        n = x;
    }

    function _tokenOf(uint256 listingId) internal view returns (uint256 tokenId) {
        (tokenId,,,,,) = sys.poolOwner.cListings(listingId);
    }

    function _processAt(uint256 turnover) internal {
        vm.prank(address(sys.game));
        sys.poolOwner.processCollection(turnover);
    }

    /// @dev A holder donates a Check (registered at the bid's reference price, waits in custody until listed).
    function _donate() internal returns (uint256 tokenId) {
        tokenId = nextCheckId();
        address holder = IERC721Lite(cfg.collection).ownerOf(tokenId);
        vm.startPrank(holder);
        IERC721Lite(cfg.collection).setApprovalForAll(address(sys.vault), true);
        sys.vault.contributeNFT(tokenId);
        vm.stopPrank();
    }

    /// @dev `n` real draws that each capture a Shape or Pack (never the Check), restocked as keepers would.
    function _shapeDraws(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            if (!canPull(alice)) {
                window();
                syncAll();
            }
            uint256 r = pull(alice);
            vm.roll(block.number + 3);
            deliverWord(r, wordFor(0));
            pool.processAcquisitions(10);
            if (i % 5 == 4) {
                window();
                syncAll();
            }
        }
        window();
        syncAll();
    }

    function _schedule(uint256 tier0) internal view returns (uint256[8] memory s) {
        s = sys.poolOwner.schedule();
        s[0] = tier0;
    }

    function test_checkOpensAtItsTierSchedule() public view {
        assertEq(sys.poolOwner.listedCount(), 1);
        uint256 id = sys.poolOwner.listedAt(0);
        (uint256 tokenId, uint128 n, uint128 term, uint64 entry, bool open,) = sys.poolOwner.cListings(id);
        assertTrue(open);
        assertEq(n, P, "the 80-Check tier's schedule price");
        assertEq(term, 1e18, "listed at its schedule: term 1");
        assertEq(entry, sys.poolOwner.allocated(), "its episode starts at the current allocation count");
        assertEq(sys.poolOwner.survived(id), 0);
        (uint128 ref, uint128 cash, uint8 tier,,) = sys.poolOwner.nfts(tokenId);
        assertEq(tier, 0, "an 80-Check Original");
        assertEq(ref, P);
        assertEq(cash, P);
        (,,,, uint256 weight,,,) = pool.listings(id);
        assertEq(weight, uint256(1e36) / P);
        assertEq(sys.poolOwner.exposureBps(), 196, "1 / 51 = 1.96%");
        assertEq(sys.poolOwner.rowsShort(), 0);
    }

    /// C010: survival comes from FWA's counts alone (listed - withdrawn - active) and matches the game's own booking of
    /// every settled draw.
    function test_survivalCountsEveryAllocatingDraw() public {
        uint256 id = sys.poolOwner.listedAt(0);
        uint256 before = sys.poolOwner.allocated();
        _shapeDraws(30);
        assertEq(sys.game.collectionWins(), 0);
        assertEq(sys.poolOwner.allocated() - before, 30, "one allocation per settled draw");
        assertEq(sys.poolOwner.survived(id), 30, "the Check survived each");
        assertEq(sys.poolOwner.allocated(), sys.game.pullsFulfilled(), "the game's ledger agrees");
        // a draw that is issued but not yet settled counts nothing
        uint256 r = pull(alice);
        assertEq(sys.poolOwner.survived(id), 30, "unsettled: no credit");
        vm.roll(block.number + 3);
        deliverWord(r, wordFor(0));
        pool.processAcquisitions(10);
        assertEq(sys.poolOwner.survived(id), 31);
        assertBooks();
    }

    /// D005: 0.2% of the schedule per survived draw, repriced at FWA on 5% moves, down to 85%.
    function test_decayPerSurvivedDrawToTheFloor() public {
        uint256 id = sys.poolOwner.listedAt(0);
        _shapeDraws(10);
        assertEq(sys.poolOwner.notionalOf(id), P - P * 20 * 10 / 10_000, "0.25 x (1 - 0.002 x 10)");
        assertEq(_notional(id), P, "a 2% drop waits for the 5% step");
        _shapeDraws(20);
        uint256 s = sys.poolOwner.survived(id);
        assertEq(sys.poolOwner.notionalOf(id), P - P * 20 * s / 10_000);
        uint256 published = _notional(id);
        assertLt(published, P, "repriced once it fell a step");
        assertLe(published - sys.poolOwner.notionalOf(id), published * 500 / 10_000, "within one step of the rule");
        (,,,,, uint256 price,,) = pool.listings(id);
        assertEq(price, published, "FWA listing repriced");
        _shapeDraws(50);
        assertEq(sys.poolOwner.notionalOf(id), P * 8_500 / 10_000, "the floor: 85%");
        assertEq(_notional(id), P * 8_500 / 10_000);
        assertBooks();
    }

    /// D003, D012: the council moves a tier's price; each listing follows at its next reprice, up or down, keeping its
    /// earned decay. Nobody else can.
    function test_scheduleIsTheCouncilsAndMovesNotionalsBothWays() public {
        uint256 id = sys.poolOwner.listedAt(0);
        _shapeDraws(10);
        uint256[8] memory s = _schedule(0.5 ether);
        vm.prank(owner);
        vm.expectRevert(Governed.NotCouncil.selector);
        sys.poolOwner.setSchedule(s);
        councilCall(address(sys.poolOwner), abi.encodeCall(CollectionPoolOwner.setSchedule, (s)));
        uint256 sv = sys.poolOwner.survived(id);
        assertEq(sys.poolOwner.notionalOf(id), 0.5 ether - 0.5 ether * 20 * sv / 10_000, "decay kept on the new price");
        window();
        syncAll();
        assertEq(_notional(id), sys.poolOwner.notionalOf(id), "raised at FWA");
        // and down again
        councilCall(address(sys.poolOwner), abi.encodeCall(CollectionPoolOwner.setSchedule, (_schedule(0.2 ether))));
        window();
        syncAll();
        assertEq(_notional(id), 0.2 ether - 0.2 ether * 20 * sys.poolOwner.survived(id) / 10_000);
        assertLe(sys.poolOwner.exposureBps(), 2_000);
        // bounds
        uint256[8] memory bad = _schedule(0.001 ether - 1);
        vm.prank(council);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.poolOwner.setSchedule(bad);
    }

    /// A tier without a schedule price is not listed: its Checks wait in custody.
    function test_unscheduledTierWaitsInCustody() public {
        councilCall(address(sys.poolOwner), abi.encodeCall(CollectionPoolOwner.setSchedule, (_schedule(0))));
        uint256 tokenId = _donate();
        window();
        syncAll();
        assertEq(sys.poolOwner.custodyCount(), 1, "waits");
        assertEq(sys.poolOwner.custodyAt(0), tokenId);
        // the Check already listed keeps its published notional
        assertEq(_notional(sys.poolOwner.listedAt(0)), P);
        councilCall(address(sys.poolOwner), abi.encodeCall(CollectionPoolOwner.setSchedule, (_schedule(P))));
        window();
        syncAll();
        assertEq(sys.poolOwner.custodyCount(), 0, "listed once its tier has a price");
    }

    function test_listingParamsAreTheCouncilsAndBounded() public {
        CollectionPoolOwner.ListingParams memory p = sys.poolOwner.listingParams();
        vm.prank(owner);
        vm.expectRevert(Governed.NotCouncil.selector);
        sys.poolOwner.setListingParams(p);
        p.floorBps = 0;
        vm.prank(council);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.poolOwner.setListingParams(p);
        p.floorBps = 8_500;
        p.targetBps = 5_001;
        vm.prank(council);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.poolOwner.setListingParams(p);
        p.targetBps = 2_000;
        p.decayBps = 10_001;
        vm.prank(council);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.poolOwner.setListingParams(p);
        // the in-flight bound stays the operator's (it only narrows admission)
        vm.prank(council);
        vm.expectRevert(Governed.NotOwner.selector);
        sys.poolOwner.setMaxInFlight(5);
        govern(address(sys.poolOwner), abi.encodeCall(CollectionPoolOwner.setMaxInFlight, (5)));
        assertEq(sys.poolOwner.maxInFlight(), 5);
    }

    /// D015 (collection-games D78): the decay clock is off at launch; switched on later it runs from then (never back
    /// to launch), adds to the survival decay, stops when switched off, and keeps the floor.
    function test_timeDecayStartsOffAndRunsFromSwitchOn() public {
        uint256 id = sys.poolOwner.listedAt(0);
        CollectionPoolOwner.ListingParams memory p = sys.poolOwner.listingParams();
        assertEq(p.dailyDecayBps, 0, "off at launch");
        vm.warp(block.timestamp + 30 days);
        assertEq(sys.poolOwner.decayClock(), 0);
        assertEq(sys.poolOwner.notionalOf(id), P, "idle: no time decay while off");
        p.dailyDecayBps = 100; // 1% of its price a day
        councilCall(address(sys.poolOwner), abi.encodeCall(CollectionPoolOwner.setListingParams, (p)));
        assertEq(sys.poolOwner.notionalOf(id), P, "the 30 idle days are not counted");
        vm.warp(block.timestamp + 10 days);
        assertEq(sys.poolOwner.notionalOf(id), P - P / 10, "1% a day for 10 days");
        _processAt(0);
        assertEq(_notional(id), P - P / 10, "repriced at FWA with no gameplay");
        p.dailyDecayBps = 0;
        councilCall(address(sys.poolOwner), abi.encodeCall(CollectionPoolOwner.setListingParams, (p)));
        vm.warp(block.timestamp + 10 days);
        assertEq(sys.poolOwner.notionalOf(id), P - P / 10, "stopped");
        p.dailyDecayBps = 10_000;
        councilCall(address(sys.poolOwner), abi.encodeCall(CollectionPoolOwner.setListingParams, (p)));
        vm.warp(block.timestamp + 1 days);
        assertEq(sys.poolOwner.notionalOf(id), P * 8_500 / 10_000, "the floor holds");
    }

    /// No limit on Checks: every Check held is listed, ten per maintenance call; those the target cannot hold yet wait
    /// in custody, the board grows by the rows they need once the vault can pay, and then they are listed too.
    function test_manyChecksAllListedAsTheBoardGrows() public {
        for (uint256 i; i < 25; ++i) {
            _donate();
        }
        assertEq(sys.poolOwner.custodyCount(), 25);
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
        assertLt(listed, 26);
        assertGt(sys.poolOwner.rowsShort(), 0, "the rest wait for rows");
        assertLe(sys.poolOwner.exposureBps(), 2_000);
        accrueFees(20 ether);
        for (uint256 i; i < 12 && sys.poolOwner.custodyCount() != 0; ++i) {
            window();
            syncAll();
        }
        assertEq(sys.poolOwner.custodyCount(), 0, "every Check in the draw");
        window();
        syncAll();
        assertEq(sys.poolOwner.listedCount(), 26);
        assertGt(sys.game.boardSize(), 50, "grew on demand");
        assertEq(sys.game.liveCount(), sys.game.boardSize());
        assertLe(sys.poolOwner.exposureBps(), 2_000);
        assertTrue(sys.poolOwner.canPurchase(alice));
        emit log_named_uint("board rows for 26 Checks at their price", sys.game.boardSize());
        assertBooks();
    }

    function _winCheck(address who) internal returns (uint256 listingId) {
        uint256 r = pull(who);
        vm.roll(block.number + 3);
        deliverWord(r, wordFor(type(uint256).max));
        pool.processAcquisitions(10);
        (,,, listingId,) = pool.acquisitions(r);
        assertTrue(sys.poolOwner.isCollectionListing(listingId));
    }

    function test_checkWonEarlyWithNoReplacementKeepsShapeDrawsOpen() public {
        playMany(bob, 40, 9);
        uint256 reserve = sys.burner.reserve();
        uint256 r = pull(alice);
        uint256 late = pull(bob);
        vm.roll(block.number + 3);
        deliverWord(r, wordFor(type(uint256).max));
        pool.processAcquisitions(1);
        (,,, uint256 listingId,) = pool.acquisitions(r);
        assertTrue(sys.poolOwner.isCollectionListing(listingId));
        assertEq(IERC721Lite(cfg.collection).ownerOf(_tokenOf(listingId)), alice, "the winner holds the Check");
        assertTrue(sys.poolOwner.canPurchase(alice));
        uint256 shapeOnly = pull(carol);
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
        assertEq(sys.poolOwner.wonCount(), 1);
        assertEq(sys.poolOwner.listedCount(), 0);
        assertTrue(pool.localPurchasesEnabled(), "open: Shapes and Packs only");
        assertFalse(sys.poolOwner.collectionAvailable());
        assertEq(sys.burner.milestoneIn() - releasedBefore, reserve * cfg.tiers.firstExitBps / 10_000, "a Check exit releases its tier");
        assertTrue(sys.burner.released(listingId));
        vm.expectRevert(CollectionBurner.AlreadyReleased.selector);
        sys.burner.release(listingId);
        assertTrue(sys.poolOwner.settleListing(listingId));
        assertEq(sys.poolOwner.wonCount(), 1);
        assertEq(sys.poolOwner.wonCashCost(0), P);
        assertBooks();
        accrueFees(5 ether);
        riseBidTo(cfg.refPrice);
        sellCheck(nextCheckId());
        window();
        vm.prank(keeper);
        sys.game.sync();
        assertTrue(sys.poolOwner.collectionAvailable(), "a Check is back in the draw");
        assertTrue(sys.poolOwner.canPurchase(alice));
    }

    /// A win removes one Check; the other keeps its notional and its survival.
    function test_winLeavesOtherChecksUnchanged() public {
        _donate();
        window();
        syncAll();
        assertEq(sys.poolOwner.listedCount(), 2);
        _shapeDraws(5);
        uint256 s0 = sys.poolOwner.survived(sys.poolOwner.listedAt(0));
        uint256 s1 = sys.poolOwner.survived(sys.poolOwner.listedAt(1));
        uint256 won = _winCheck(alice);
        uint256 other = sys.poolOwner.listedAt(0) == won ? sys.poolOwner.listedAt(1) : sys.poolOwner.listedAt(0);
        uint256 before = _notional(other);
        uint256 survivedBefore = sys.poolOwner.survived(other);
        assertEq(survivedBefore, (other == sys.poolOwner.listedAt(0) ? s0 : s1) + 1, "the winning draw counts for the other");
        vm.prank(keeper);
        sys.game.sync();
        assertEq(sys.poolOwner.listedCount(), 1);
        assertEq(_notional(other), before, "its published notional is unchanged");
        assertEq(sys.poolOwner.survived(other), survivedBefore, "booking changes nothing");
    }

    /// A small prize never releases milestone ETH; a big prize releases its tier when set (collection-games D64).
    function test_smallPrizeNeverReleasesBigPrizeReleasesItsTier() public {
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
        assertFalse(sys.poolOwner.settleListing(listingId), "not a Check listing");
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
        uint256 check = sys.poolOwner.listedAt(0);
        vm.expectRevert(CollectionBurner.NotQualifying.selector);
        sys.burner.release(check);
    }

    /// A refused delivery returns the Check to custody with a new episode (it was selected, D002): relisted at its
    /// schedule price with no survival.
    function test_failedDeliveryReturnsWithANewEpisode() public {
        _shapeDraws(30);
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
        assertTrue(pool.localPurchasesEnabled(), "Shape and Pack draws continue meanwhile");
        assertFalse(sys.burner.qualifies(listingId));
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(alice);
        pool.refundFailedDelivery(listingId);
        vm.prank(keeper);
        sys.game.sync();
        assertEq(sys.poolOwner.wonCount(), 0);
        assertFalse(sys.burner.released(listingId));
        window();
        syncAll();
        assertEq(sys.poolOwner.custodyCount(), 0);
        uint256 relisted = sys.poolOwner.listedAt(0);
        assertTrue(relisted != listingId);
        assertEq(_notional(relisted), P, "a new episode at the schedule price");
        assertEq(sys.poolOwner.survived(relisted), 0);
        assertEq(sys.game.collectionWins(), 0);
    }

    /// A target the listings already exceed defers decay (and asks for rows); it never closes the purchase gate.
    function test_lowerTargetDefersDecayGateStaysOpen() public {
        uint256 id = sys.poolOwner.listedAt(0);
        CollectionPoolOwner.ListingParams memory p = sys.poolOwner.listingParams();
        p.targetBps = 100;
        councilCall(address(sys.poolOwner), abi.encodeCall(CollectionPoolOwner.setListingParams, (p)));
        _shapeDraws(30);
        assertEq(_notional(id), P, "deferred: 1 / (51 - headroom) > 1%");
        assertGt(sys.poolOwner.rowsShort(), 0);
        assertTrue(sys.poolOwner.canPurchase(address(this)), "the gate's ceiling is 50%");
        assertTrue(pool.localPurchasesEnabled());
    }

    /// Audit (collection-games D66): a Check sold for 1 wei is recorded at `MIN_REF_COST` and listed at its schedule
    /// price like any other; its cash cost stays 1 wei.
    function test_tinySaleIsListedAtTheSchedule() public {
        accrueFees(10 ether);
        sys.vault.sweep();
        uint256 id = nextCheckId();
        sellCheckAt(id, 1);
        (uint128 ref, uint128 cash,,,) = sys.poolOwner.nfts(id);
        assertEq(ref, sys.poolOwner.MIN_REF_COST());
        assertEq(cash, 1);
        window();
        syncAll();
        assertEq(sys.poolOwner.custodyCount(), 0, "listed");
        for (uint256 i; i < sys.poolOwner.listedCount(); ++i) {
            assertEq(_notional(sys.poolOwner.listedAt(i)), P, "at the schedule, whatever it cost");
        }
        assertBooks();
    }

    /// Audit (collection-games D67): a Check listing "won" by the FWA pool itself releases nothing.
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

    function test_onlyGameAndDeskDriveThePoolOwner() public {
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
        uint256 id = sys.poolOwner.listedAt(0);
        // the desk's operations answer to the desk alone, the owner and council included
        address[3] memory callers = [owner, council, alice];
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(CollectionPoolOwner.NotDesk.selector);
            sys.poolOwner.deskRelease(id, callers[i]);
            vm.expectRevert(CollectionPoolOwner.NotDesk.selector);
            sys.poolOwner.deskCompose(id, id, false);
            vm.expectRevert(CollectionPoolOwner.NotDesk.selector);
            sys.poolOwner.deskFormBlack(new uint256[](64));
            vm.stopPrank();
        }
        vm.prank(makeAddr("anyone"));
        assertTrue(sys.poolOwner.settleListing(id));
        assertEq(sys.poolOwner.openCollection(), 1);
    }

    /// Checks Editions and the desk are refused as a draw's purchaser like every other system contract.
    function test_editionsAndDeskAreNotPurchasers() public view {
        assertFalse(sys.poolOwner.canPurchase(cfg.editions));
        assertFalse(sys.poolOwner.canPurchase(address(sys.desk)));
        assertFalse(sys.poolOwner.canPurchase(cfg.collection));
        assertTrue(sys.poolOwner.canPurchase(alice));
    }
}

/// @notice Board growth on demand: with a 3% target and a fast decay, real play reaches the target on the 50-row
///         board; decay waits, the game grows the board by the rows the pool owner asks for once the vault can pay,
///         and decay resumes.
contract CollectionGrowthForkTest is ForkBase {
    address alice = makeAddr("cg.player.alice");

    function setUp() public {
        setUpFork();
        cfg = _testChecksConfig();
        cfg.listing.targetBps = 300;
        cfg.listing.decayBps = 100; // 1% of the schedule per survived draw
        cfg.listing.floorBps = 1_000;
        cfg.settings.continuityShareBps = 0; // surplus to buybacks only, so the vault cannot fund growth until fees come
        cfg.openingAllowance = 0;
        _deploy();
        launchGame(cfg.refPrice);
    }

    function _notional(uint256 id) internal view returns (uint256 n) {
        (, uint128 x,,,,) = sys.poolOwner.cListings(id);
        n = x;
    }

    function test_targetDefersDecayAndGrowthResumesIt() public {
        uint256 id = sys.poolOwner.listedAt(0);
        playMany(alice, 120, 8);
        window();
        syncAll();
        assertEq(sys.game.collectionWins(), 0, "seeded so the Check survives");
        uint256 h = sys.poolOwner.gateHeadroom();
        // P / n <= 0.03 x (rows + 1 - h): decay stops within a step of that notional
        uint256 rows = sys.game.boardSize();
        uint256 stop = 0.25 ether * 10_000 / (300 * (rows + 1 - h));
        uint256 n = _notional(id);
        assertGe(n, stop);
        assertGt(sys.poolOwner.rowsShort(), 0, "rows asked for");
        uint256 rowsBefore = sys.game.boardSize();
        assertEq(sys.game.growthNeed(), sys.poolOwner.rowsShort() * sys.game.rowCost());
        accrueFees(10 ether);
        for (uint256 i; i < 6; ++i) {
            window();
            syncAll();
        }
        assertGt(sys.game.boardSize(), rowsBefore, "grown on demand");
        assertEq(sys.game.liveCount(), sys.game.boardSize());
        uint256 n2 = _notional(id);
        assertLt(n2, n, "decay resumed");
        assertLe(sys.poolOwner.exposureBps(), 300);
        (,,,, uint256 w,,,) = pool.listings(id);
        assertEq(w, uint256(1e36) / n2);
        assertBooks();
    }
}
