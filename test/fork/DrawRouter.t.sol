// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase, IERC721Lite} from "./ForkBase.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {CollectionGame} from "../../src/game/CollectionGame.sol";
import {DrawRouter, IGameSync} from "../../src/periphery/DrawRouter.sol";

/// @notice The player entry point: a draw that first settles the draws already waiting in FWA's queue, so a backlog
///         nobody settled cannot keep the game closed, and then (optionally) runs the game's upkeep within a gas
///         budget, for which the player is paid like a keeper. Heavy upkeep never breaks the draw (D60).
contract DrawRouterForkTest is ForkBase {
    address alice = makeAddr("cg.player.alice");
    address bob = makeAddr("cg.player.bob");

    function setUp() public {
        deployBayc();
        launchGame(6 ether);
    }

    function _routerDraw(address who, uint256 settle, uint256 count) internal returns (uint256[] memory, uint256, uint256) {
        return _routerDraw(who, settle, 0, count);
    }

    uint256 internal _syncCount;
    uint256 internal _upkeepGas = 5_000_000;

    function _routerDraw(address who, uint256 settle, uint256 syncCount, uint256 count)
        internal
        returns (uint256[] memory ids, uint256 spent, uint256 quoted)
    {
        _syncCount = syncCount;
        // the site's quote: simulated after the settlement the draw will make
        uint256 snap = vm.snapshotState();
        (uint256 fee,, uint256 total) = sys.drawRouter.quote(pool, settle, count);
        vm.revertToState(snap);
        vm.deal(who, who.balance + total + 1 ether);
        uint256 before = who.balance;
        ids = _send(who, settle, count, fee, total);
        spent = before - who.balance;
        quoted = total;
    }

    /// @dev One extra ETH attached: the router must return all of it.
    function _send(address who, uint256 settle, uint256 count, uint256 fee, uint256 total)
        internal
        returns (uint256[] memory ids)
    {
        uint256 version = pool.inventoryVersion();
        vm.prank(who);
        uint256 g = gasleft();
        ids = sys.drawRouter.draw{value: total + 1 ether}(
            pool,
            IGameSync(address(sys.game)),
            settle,
            _syncCount,
            _syncCount == 0 ? 0 : _upkeepGas,
            count,
            fee,
            0,
            1_000,
            version,
            block.timestamp + 1 hours
        );
        emit log_named_uint("router draw gas", g - gasleft());
    }

    /// Randomness arriving out of order leaves draws Ready but unsettled (the callback settles only the head of the
    /// queue). Ten of them close the in-flight gate for everyone; a direct FWA purchase reverts. A router draw settles
    /// them and buys in the same transaction.
    function test_backlogClosesGateAndRouterDrawReopensIt() public {
        uint256 k = sys.poolOwner.maxInFlight(); // 4 at launch
        uint256[] memory r = new uint256[](k);
        for (uint256 i; i < k; ++i) {
            r[i] = pull(bob);
        }
        vm.roll(block.number + 3);
        for (uint256 i = k - 1; i >= 1; --i) {
            deliverWord(r[i], uint256(keccak256(abi.encode(i)))); // not the head: cached, not settled
        }
        deliverWord(r[0], 1); // the head: the callback settles it, and only it
        assertEq(pool.unsettledAcquisitionCount(), k - 1, "the rest Ready, unsettled");
        uint256 late = pull(alice); // the gate still admits one more
        vm.roll(block.number + 3);
        deliverWord(late, 2); // not the head
        assertEq(pool.unsettledAcquisitionCount(), k);
        assertFalse(sys.poolOwner.canPurchase(alice), "in-flight limit reached");
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        uint256 version = pool.inventoryVersion();
        vm.deal(alice, alice.balance + total);
        vm.prank(alice);
        vm.expectRevert();
        pool.acquire{value: total}(alice, fee, 0, 10_000, version, block.timestamp + 1 hours);

        uint256 tipsBefore = sys.game.keeperPaid();
        (uint256[] memory ids, uint256 spent, uint256 quoted) = _routerDraw(alice, 10, 1);
        assertEq(pool.unsettledAcquisitionCount(), 1, "backlog settled; the new draw is in flight");
        (address purchaser,,,, IFWAPool.AcquisitionStatus st) = pool.acquisitions(ids[0]);
        assertEq(purchaser, alice, "bought for the caller");
        assertEq(uint8(st), uint8(IFWAPool.AcquisitionStatus.Pending));
        assertEq(spent, quoted, "the caller paid the post-settlement quote, nothing more");
        assertGt(quoted, total, "settling moved the ticket: quoting before settlement would have reverted");
        assertEq(address(sys.drawRouter).balance, 0, "the router keeps nothing");
        // the earlier draws were delivered to their own purchasers, not to the router's caller
        for (uint256 i = 1; i < k; ++i) {
            (address p,,,,) = pool.acquisitions(r[i]);
            assertEq(p, bob);
        }
        // the settlement paid no tip to anyone: the keeper fund is untouched
        assertEq(sys.game.keeperPaid(), tipsBefore);
    }

    /// With nothing to settle the router is an ordinary purchase: same price, NFT and refund rights to the caller.
    function test_plainDrawAndBatch() public {
        (uint256[] memory one,,) = _routerDraw(alice, 10, 1);
        assertEq(one.length, 1);
        (uint256[] memory two, uint256 spent, uint256 quoted) = _routerDraw(alice, 0, 2);
        assertEq(two.length, 2);
        assertEq(spent, quoted);
        vm.roll(block.number + 3);
        deliverWord(one[0], wordFor(0.01 ether));
        deliverWord(two[0], wordFor(0.01 ether));
        deliverWord(two[1], wordFor(0.01 ether));
        pool.processAcquisitions(10);
        for (uint256 i; i < 2; ++i) {
            (,,, uint256 listingId,) = pool.acquisitions(two[i]);
            (,, address purchaser,,,,, IFWAPool.ListingStatus st) = pool.listings(listingId);
            assertEq(purchaser, alice);
            assertEq(uint8(st), uint8(IFWAPool.ListingStatus.Settled));
        }
    }

    /// With `syncCount` the player's draw also books settled draws, replaces won prizes and sweeps the live bid, at the
    /// player's cost and unpaid: the game's `upkeep` pays nobody, so no keeper allowance is spent (D77), and the
    /// vault's sweep reward goes back to the vault (D76).
    function test_drawRunsUpkeepUnpaid() public {
        // draws settled by FWA but not yet booked by the game (no keeper around)
        for (uint256 i; i < 6; ++i) {
            pullAndSettle(bob, uint256(keccak256(abi.encode("upkeep", i))));
        }
        uint256 seenBefore = sys.game.seenSeq();
        uint256 tipsBefore = sys.game.keeperPaid();
        accrueFees(3 ether); // fees waiting to enter the live bid
        uint256 rewardsBefore = sys.vault.sweepRewards();
        uint256 contributedBefore = sys.vault.contributions();
        uint256 bidBefore = sys.vault.bidBalance();
        vm.warp(block.timestamp + 1 hours);
        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei);
        (, uint256 spent, uint256 quoted) = _routerDraw(alice, 10, 10, 1);
        assertGt(sys.game.seenSeq(), seenBefore, "the player's draw booked the settled draws");
        uint256 reward = sys.vault.sweepRewards() - rewardsBefore;
        assertEq(sys.game.keeperPaid(), tipsBefore, "the game paid nobody for the upkeep");
        assertGt(reward, 0, "the vault rewarded the sweep");
        assertGt(sys.vault.bidBalance(), bidBefore, "the draw swept fees into the live bid");
        assertEq(spent, quoted, "the player pays the draw and is not paid for the upkeep");
        assertEq(sys.vault.contributions() - contributedBefore, reward, "the reward went back to the vault");
        assertEq(address(sys.drawRouter).balance, 0, "the router keeps nothing");
        // upkeep only (count 0): no draw, attached ETH returned
        vm.deal(alice, 1 ether);
        uint256 before = alice.balance;
        vm.prank(alice);
        uint256[] memory none =
            sys.drawRouter.draw{value: 1 ether}(pool, IGameSync(address(sys.game)), 10, 10, 5_000_000, 0, 0, 0, 0, 0, block.timestamp);
        assertEq(none.length, 0);
        assertGe(alice.balance, before, "nothing kept");
    }

    /// D82: right after a player's draw did the upkeep, a keeper's light `sync` does the work but is not paid; once
    /// players have been quiet for `payDelay`, the keeper is paid as before.
    function test_lightSyncLeftToPlayersAfterTheirUpkeep() public {
        for (uint256 i; i < 3; ++i) {
            pullAndSettle(bob, uint256(keccak256(abi.encode("left", i))));
        }
        _routerDraw(alice, 10, 10, 1);
        assertEq(sys.game.lastUpkeepAt(), block.timestamp, "the draw's upkeep did work");
        for (uint256 i; i < 2; ++i) {
            pullAndSettle(bob, uint256(keccak256(abi.encode("left2", i))));
        }
        vm.txGasPrice(1 gwei);
        uint256 seen = sys.game.seenSeq();
        uint256 paid = sys.game.keeperPaid();
        uint256 bal = keeper.balance;
        vm.prank(keeper);
        assertGt(sys.game.sync(), 0, "the light work is done");
        assertGt(sys.game.seenSeq(), seen, "it booked the settled draws");
        assertEq(sys.game.keeperPaid(), paid, "but nobody is paid for it");
        assertEq(keeper.balance, bal);
        // with nothing left to do, a call is still refused
        vm.prank(keeper);
        vm.expectRevert(CollectionGame.NoWork.selector);
        sys.game.sync();
        // once players are quiet, new light work is paid as before
        pullAndSettle(bob, uint256(keccak256(abi.encode("left3", 0))));
        vm.warp(sys.game.lastUpkeepAt() + sys.game.keeperParams().payDelay);
        vm.prank(keeper);
        sys.game.sync();
        assertGt(sys.game.keeperPaid(), paid, "paid once players are quiet");
    }

    /// The site's way (D60): measure the upkeep with `measureUpkeep` (an `eth_call`, before the draw), ask for it with
    /// a budget a little above the measurement, and the draw runs it: it books the settled draws and pays the player.
    /// The measurement is an upper bound: with the player's own draw in flight the game lists replacements only when
    /// the board is below its minimum (FWA's ordering), so a keeper's `sync` lists them once the draw has settled.
    function test_measuredUpkeepRunsWithinItsBudget() public {
        for (uint256 i; i < 2; ++i) {
            pullAndSettle(bob, uint256(keccak256(abi.encode("measured", i))));
        }
        window(); // replacements due
        uint256 snap = vm.snapshotState();
        (bool ran, uint256 used) = sys.drawRouter.measureUpkeep(IGameSync(address(sys.game)), 10);
        vm.revertToState(snap);
        assertTrue(ran, "upkeep to do");
        assertGt(used, 700_000, "booking and replacing two prizes");
        assertLt(used, 2_500_000, "within the site's limit for a player's upkeep");
        _upkeepGas = used * 13 / 10 + 50_000;
        vm.warp(block.timestamp + 1 hours); // the hourly flat fee is due
        vm.txGasPrice(1 gwei);
        uint256 seen = sys.game.seenSeq();
        uint256 tips = sys.game.keeperPaid();
        uint256 g = gasleft();
        (uint256[] memory ids,,) = _routerDraw(alice, 10, 10, 1);
        uint256 drawGas = g - gasleft();
        assertGt(sys.game.seenSeq(), seen, "the player's draw booked the settled draws");
        assertEq(sys.game.keeperPaid(), tips, "and was not paid for it (D77)");
        assertLt(drawGas, 700_000 + used, "at most the purchase plus the measured upkeep");
        vm.roll(block.number + 3);
        deliverWord(ids[0], wordFor(0.01 ether));
        syncAll();
        assertEq(sys.game.liveCount(), sys.game.boardSize(), "replacements listed once nothing is in flight");
        emit log_named_uint("measured upkeep", used);
        emit log_named_uint("draw with upkeep", drawGas);
    }

    /// Upkeep heavier than the player's budget (here booking 20 draws and a full listing batch with the board below its
    /// minimum, which the game lists even with draws in flight) fails on its own: the draw stands, costs at most the
    /// purchase plus the budget, and the work is left for a keeper's `sync`.
    function test_heavyUpkeepNeverBreaksTheDraw() public {
        for (uint256 i; i < 20; ++i) {
            pullAndSettle(bob, uint256(keccak256(abi.encode("heavy", i))));
        }
        window();
        uint256 snap = vm.snapshotState();
        (, uint256 used) = sys.drawRouter.measureUpkeep(IGameSync(address(sys.game)), 40);
        vm.revertToState(snap);
        assertGt(used, 5_000_000, "booking and a full listing batch");
        _upkeepGas = 2_500_000; // the site's limit for a player's upkeep (the site would not even ask for this one)
        uint256 seen = sys.game.seenSeq();
        uint256 live = sys.game.liveCount();
        uint256 g = gasleft();
        (uint256[] memory ids,,) = _routerDraw(alice, 10, 40, 1);
        uint256 drawGas = g - gasleft();
        (address purchaser,,,,) = pool.acquisitions(ids[0]);
        assertEq(purchaser, alice, "the draw stands");
        assertLt(drawGas, 700_000 + 2_500_000 + DrawRouter(payable(address(sys.drawRouter))).TAIL_GAS(), "bounded by the budget");
        // with the player's own draw in flight the upkeep books but lists nothing (D82: never over a draw in flight),
        // so it fits the budget; were it over, it would fail as a whole and leave the work for later
        assertGt(sys.game.seenSeq(), seen, "the upkeep booked the settled draws");
        assertEq(sys.game.liveCount(), live - 20, "and listed nothing over the draw in flight");
        vm.roll(block.number + 3);
        deliverWord(ids[0], wordFor(0.01 ether));
        restockAll(); // keepers do it, a batch per maintenance window
        assertGt(sys.game.seenSeq(), seen + 20);
        assertEq(sys.game.liveCount(), sys.game.boardSize());
        emit log_named_uint("draw with an over-budget upkeep", drawGas);
    }

    /// A gas limit that leaves less than the requested budget reverts up front (`UpkeepGas`): a gas estimate therefore
    /// always includes the budget, and the upkeep can never starve the rest of the transaction.
    function test_gasLimitMustCoverTheBudget() public {
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        uint256 version = pool.inventoryVersion();
        vm.deal(alice, total);
        vm.prank(alice);
        vm.expectRevert(DrawRouter.UpkeepGas.selector);
        sys.drawRouter.draw{value: total, gas: 2_000_000}(
            pool, IGameSync(address(sys.game)), 0, 10, 2_500_000, 1, fee, 0, 1_000, version, block.timestamp + 1 hours
        );
    }

    /// The router has no privileges: the purchase gate and FWA's guards apply exactly as to a direct purchase.
    function test_gateAndGuardsStillApply() public {
        // a stale inventory version reverts in FWA
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        uint256 version = pool.inventoryVersion();
        vm.deal(alice, total);
        vm.prank(alice);
        vm.expectRevert();
        sys.drawRouter.draw{value: total}(
            pool, IGameSync(address(sys.game)), 0, 0, 0, 1, fee, 0, 1_000, version + 1, block.timestamp + 1 hours
        );
        // a paused game closes FWA purchases: the router cannot open them
        vm.prank(owner);
        sys.game.setPaused(true);
        assertFalse(pool.localPurchasesEnabled());
        vm.prank(alice);
        vm.expectRevert();
        sys.drawRouter.draw{value: total}(
            pool, IGameSync(address(sys.game)), 10, 10, 5_000_000, 1, fee, 0, 1_000, version, block.timestamp + 1 hours
        );
    }

    /// Audit final (B-F4): a pool other than the game's own is refused before any ETH moves, so a site whose read RPC
    /// lies about `game.pool()` cannot have a player pay a fake pool.
    function test_onlyTheGamesPool() public {
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        uint256 version = pool.inventoryVersion();
        vm.deal(alice, total);
        vm.prank(alice);
        vm.expectRevert(DrawRouter.WrongPool.selector);
        sys.drawRouter.draw{value: total}(
            IFWAPool(makeAddr("fakePool")), IGameSync(address(sys.game)), 0, 0, 0, 1, fee, 0, 1_000, version, block.timestamp + 1 hours
        );
        assertEq(alice.balance, total);
    }

    // ------------------------------------------------------------------ redeem and draw

    /// @dev A prize won by `who` on `nft` (the game's Shapes or Packs): one draw whose word picks the first Active
    ///      listing on that contract, settled and delivered. Returns its token id and backing.
    function _win(address who, address nft) internal returns (uint256 tokenId, uint256 backing) {
        uint256 prefix;
        for (uint256 slot = 1; slot < 2000; ++slot) {
            uint256 id = pool.slotToListing(slot);
            if (id == 0) continue;
            (address c,,,, uint256 weight,,, IFWAPool.ListingStatus st) = pool.listings(id);
            if (st != IFWAPool.ListingStatus.Active) continue;
            if (c == nft) break;
            prefix += weight;
        }
        uint256 req = pullAndSettle(who, prefix);
        (,,, uint256 listingId,) = pool.acquisitions(req);
        address c;
        (c,,, tokenId,,,,) = pool.listings(listingId);
        assertEq(c, nft, "won on that contract");
        assertEq(IERC721Lite(nft).ownerOf(tokenId), who, "delivered");
        backing = IValue(nft).valueOf(tokenId);
    }

    function _params(uint256 count, uint256 fee) internal view returns (DrawRouter.DrawParams memory) {
        return DrawRouter.DrawParams(
            pool, IGameSync(address(sys.game)), 0, 0, 0, count, fee, 0, 1_000, pool.inventoryVersion(), block.timestamp + 1 hours
        );
    }

    function _approve(address who) internal {
        vm.startPrank(who);
        IERC721Lite(cfg.shapes).setApprovalForAll(address(sys.drawRouter), true);
        IERC721Lite(sys.packs).setApprovalForAll(address(sys.drawRouter), true);
        vm.stopPrank();
    }

    function _one(uint256 x) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = x;
    }

    /// A player pays for the next draws with what they won: their Shape and Pack are redeemed and the draws bought in
    /// one transaction, the wallet adding only what the prizes do not cover. The prizes are gone (redeemed, not held
    /// by the router), the draws are the player's, and the router keeps nothing.
    function test_redeemAndDrawPaysWithWonPrizes() public {
        (uint256 shapeId, uint256 shapeValue) = _win(alice, cfg.shapes);
        (uint256 packId, uint256 packValue) = _win(alice, sys.packs);
        _approve(alice);
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(2);
        uint256 won = shapeValue + packValue;
        assertLt(won, total, "a top-up is needed here");
        vm.deal(alice, total - won);
        DrawRouter.DrawParams memory dp = _params(2, fee); // before the prank: it reads the pool
        vm.prank(alice);
        uint256[] memory ids = sys.drawRouter.redeemAndDraw{value: total - won}(dp, _one(shapeId), _one(packId));
        assertEq(ids.length, 2);
        for (uint256 i; i < 2; ++i) {
            (address purchaser,,,,) = pool.acquisitions(ids[i]);
            assertEq(purchaser, alice, "the draws are the player's");
        }
        assertEq(alice.balance, 0, "the prizes and the top-up paid exactly the quote");
        assertEq(address(sys.drawRouter).balance, 0, "the router keeps nothing");
        vm.expectRevert();
        IERC721Lite(cfg.shapes).ownerOf(shapeId); // redeemed: burned
        vm.expectRevert();
        IERC721Lite(sys.packs).ownerOf(packId);
    }

    /// Prizes worth more than the draws: FWA keeps the draws' cost and the rest comes back to the player as change.
    function test_redeemAndDrawReturnsWhatThePrizesDoNotSpend() public {
        uint256[] memory shapes = new uint256[](3);
        uint256 won;
        for (uint256 i; i < 3; ++i) {
            uint256 v;
            (shapes[i], v) = _win(alice, cfg.shapes);
            won += v;
        }
        _approve(alice);
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        assertGt(won, total, "the prizes cover the draw");
        uint256 before = alice.balance;
        DrawRouter.DrawParams memory dp = _params(1, fee);
        vm.prank(alice);
        sys.drawRouter.redeemAndDraw(dp, shapes, new uint256[](0));
        assertEq(alice.balance, before + won - total, "the change, to the player");
        assertEq(address(sys.drawRouter).balance, 0);
    }

    /// With `count` 0 it only redeems: every wei to the player.
    function test_redeemOnly() public {
        (uint256 packId, uint256 packValue) = _win(alice, sys.packs);
        _approve(alice);
        uint256 before = alice.balance;
        DrawRouter.DrawParams memory dp = _params(0, 0);
        vm.prank(alice);
        uint256[] memory ids = sys.drawRouter.redeemAndDraw(dp, new uint256[](0), _one(packId));
        assertEq(ids.length, 0);
        assertEq(alice.balance, before + packValue);
    }

    /// The router moves only the caller's own tokens: another player's Shape or Pack, even with that player's approval
    /// on the router, cannot be redeemed by anyone else.
    function test_cannotRedeemSomeoneElsesPrizes() public {
        (uint256 shapeId,) = _win(bob, cfg.shapes);
        (uint256 packId,) = _win(bob, sys.packs);
        _approve(bob);
        _approve(alice);
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        vm.deal(alice, total);
        DrawRouter.DrawParams memory dp = _params(1, fee);
        uint256[] memory shapeIds = _one(shapeId);
        uint256[] memory packIds = _one(packId);
        uint256[] memory none = new uint256[](0);
        vm.startPrank(alice);
        vm.expectRevert();
        sys.drawRouter.redeemAndDraw{value: total}(dp, shapeIds, none);
        vm.expectRevert();
        sys.drawRouter.redeemAndDraw{value: total}(dp, none, packIds);
        vm.stopPrank();
        assertEq(IERC721Lite(cfg.shapes).ownerOf(shapeId), bob);
        assertEq(IERC721Lite(sys.packs).ownerOf(packId), bob);
        assertEq(alice.balance, total, "nothing moved");
    }

    /// Without the approval nothing moves.
    function test_redeemNeedsTheApproval() public {
        (uint256 shapeId,) = _win(alice, cfg.shapes);
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        vm.deal(alice, total);
        DrawRouter.DrawParams memory dp = _params(1, fee);
        uint256[] memory shapeIds = _one(shapeId);
        vm.prank(alice);
        vm.expectRevert();
        sys.drawRouter.redeemAndDraw{value: total}(dp, shapeIds, new uint256[](0));
        assertEq(IERC721Lite(cfg.shapes).ownerOf(shapeId), alice);
    }

    /// The same token twice reverts (the second `transferFrom` finds it already moved), the prize untouched.
    function test_redeemAndDrawDuplicateIdReverts() public {
        (uint256 shapeId,) = _win(alice, cfg.shapes);
        _approve(alice);
        uint256[] memory twice = new uint256[](2);
        twice[0] = shapeId;
        twice[1] = shapeId;
        DrawRouter.DrawParams memory dp = _params(0, 0);
        vm.prank(alice);
        vm.expectRevert();
        sys.drawRouter.redeemAndDraw(dp, twice, new uint256[](0));
        assertEq(IERC721Lite(cfg.shapes).ownerOf(shapeId), alice);
    }

    /// ETH sent to the router by mistake goes to the next caller with the change, as with `draw`.
    function test_redeemAndDrawReturnsStrayEth() public {
        (uint256 packId, uint256 packValue) = _win(alice, sys.packs);
        _approve(alice);
        vm.deal(address(sys.drawRouter), 1 ether);
        uint256 before = alice.balance;
        DrawRouter.DrawParams memory dp = _params(0, 0);
        vm.prank(alice);
        sys.drawRouter.redeemAndDraw(dp, new uint256[](0), _one(packId));
        assertEq(alice.balance, before + packValue + 1 ether);
        assertEq(address(sys.drawRouter).balance, 0);
    }

    /// The pool check still comes first: a fake pool is refused with the prizes untouched.
    function test_redeemAndDrawOnlyTheGamesPool() public {
        (uint256 shapeId,) = _win(alice, cfg.shapes);
        _approve(alice);
        DrawRouter.DrawParams memory p = _params(1, 0);
        p.pool = IFWAPool(makeAddr("fakePool"));
        uint256[] memory shapeIds = _one(shapeId);
        vm.prank(alice);
        vm.expectRevert(DrawRouter.WrongPool.selector);
        sys.drawRouter.redeemAndDraw(p, shapeIds, new uint256[](0));
        assertEq(IERC721Lite(cfg.shapes).ownerOf(shapeId), alice);
    }

    /// Final audit round 2 (F2): the router serves one game, fixed at deployment. A caller handed a fake game whose
    /// pool is a fake pool (and whose prize source is the real Shapes and Packs) is refused before any token or ETH moves.
    function test_onlyTheRoutersGame() public {
        assertEq(address(sys.drawRouter.game()), address(sys.game));
        address fakePool = makeAddr("fakePool");
        FakeGame fake = new FakeGame(fakePool, address(sys.poolOwner));
        (uint256 shapeId,) = _win(alice, cfg.shapes);
        _approve(alice);
        DrawRouter.DrawParams memory p = _params(1, 0);
        (p.pool, p.game) = (IFWAPool(fakePool), IGameSync(address(fake)));
        uint256[] memory shapeIds = _one(shapeId);
        vm.prank(alice);
        vm.expectRevert(DrawRouter.WrongGame.selector);
        sys.drawRouter.redeemAndDraw(p, shapeIds, new uint256[](0));
        assertEq(IERC721Lite(cfg.shapes).ownerOf(shapeId), alice);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(DrawRouter.WrongGame.selector);
        sys.drawRouter.draw{value: 1 ether}(IFWAPool(fakePool), IGameSync(address(fake)), 0, 0, 0, 1, 1 ether, 0, 1_000, 0, block.timestamp + 1 hours);
        assertEq(fakePool.balance, 0);
    }
}

/// @dev A game that names a fake pool and the real prize source.
contract FakeGame {
    address public immutable pool;
    address public immutable poolOwner;

    constructor(address pool_, address poolOwner_) {
        (pool, poolOwner) = (pool_, poolOwner_);
    }
}

interface IValue {
    function valueOf(uint256 tokenId) external view returns (uint256);
}
