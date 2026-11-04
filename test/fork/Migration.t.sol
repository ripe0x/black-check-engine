// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase, IERC721Lite} from "./ForkBase.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {CollectionGame} from "../../src/game/CollectionGame.sol";
import {CollectionPoolOwner} from "../../src/core/CollectionPoolOwner.sol";
import {FundingVault} from "../../src/core/FundingVault.sol";
import {CollectionHook} from "../../src/token/CollectionHook.sol";
import {CollectionBurner} from "../../src/treasury/CollectionBurner.sol";
import {MigrationAuthority} from "../../src/migration/MigrationAuthority.sol";
import {MockSuccessor, RejectingReceiver} from "../utils/MigrationMocks.sol";
import {Governed} from "../../src/core/Governed.sol";

/// @notice The migration off FWA V2 (docs/MIGRATION.md) on a running V1 game: three Apes, ≈ 5 ETH of Shape and Pack
///         backing, treasury capital in the vault, committed buyback ETH (the burner and its milestone reserve), and
///         player draws still pending. Proves conservation, surviving player claims, the NFTs' records, batched and
///         retryable steps, and the coin and burner working on; and that nothing moves without the owner's proposal,
///         its 72 hours and its pinned code, nor before V1 has settled.
contract MigrationForkTest is ForkBase {
    address bob = makeAddr("cg.player.bob");
    address carol = makeAddr("cg.player.carol");
    address dave = makeAddr("cg.player.dave");
    address trader = makeAddr("cg.trader");
    uint256 internal constant SEED = 3;

    MigrationAuthority m;
    uint256 pendingCarol; // a draw whose randomness arrives after the migration starts: settles normally
    uint256 pendingDave; // a draw whose randomness never arrives: expires into a refund credit
    uint256[] apeIds;

    struct Snapshot {
        uint256 vault;
        uint256 burner;
        uint256 reserve;
        uint256 returned;
        uint256 backing;
    }

    function setUp() public {
        setUpFork();
        cfg = _testChecksConfigAt(6 ether);
        cfg.initialBoardSize = 160; // 1.6 x the launch board: ≈ 5 ETH of Shape and Pack backing
        _deploy();
        m = sys.migration;
        launchGame(6 ether);
        _buildRunningGame();
    }

    // ------------------------------------------------------------------ the running V1 game

    function _buildRunningGame() internal {
        pastOpeningCurve();
        buyCoin(trader, 3 ether);
        // a quarter of the game's buybacks ongoing, so this running game has burned some (launch: all wait for wins, D74)
        govern(address(sys.burner), abi.encodeCall(CollectionBurner.setMilestoneBps, (7_500)));
        playMany(bob, 60, SEED); // a draw sequence with no early large prize, so the game has distributed surplus
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(keeper);
        sys.burner.process(0); // some coins burned; the rest stays committed
        // two more Apes bought from holders at the standing bid
        accrueFees(30 ether);
        riseBidTo(6 ether);
        sellCheck(nextCheckId());
        riseBidTo(6 ether);
        sellCheck(nextCheckId());
        playMany(bob, 30, 8);
        accrueFees(2 ether); // treasury capital beyond what the game needs
        // draws in flight when the migration starts
        pendingCarol = pull(carol);
        pendingDave = pull(dave);
        // the three Apes, wherever they are (custody or listed)
        for (uint256 i; i < sys.poolOwner.custodyCount(); ++i) {
            apeIds.push(sys.poolOwner.custodyAt(i));
        }
        for (uint256 i; i < sys.poolOwner.listedCount(); ++i) {
            (uint256 tokenId,,,,,) = sys.poolOwner.cListings(sys.poolOwner.listedAt(i));
            apeIds.push(tokenId);
        }
        assertEq(apeIds.length, 3, "three Apes held");
        assertGe(sys.game.inventoryBacking(), 4.5 ether, "about 5 ETH of prize backing");
        assertGt(sys.vault.surplusIn(), 0, "surplus sent to the vault");
        assertGt(sys.burner.ongoingBalance() + sys.burner.reserve(), 0, "committed buyback ETH");
        assertBooks();
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        s.vault = address(sys.vault).balance;
        s.burner = address(sys.burner).balance;
        s.reserve = sys.burner.reserve();
        s.returned = sys.vault.returnedFromGame();
        s.backing = sys.game.inventoryBacking();
    }

    function _successor() internal returns (MockSuccessor s) {
        s = new MockSuccessor(cfg.collection, address(sys.vault), cfg.poolManager);
    }

    /// The owner proposes; 72 hours later anyone executes.
    function _authorize(address s) internal {
        vm.prank(council);
        m.propose(s);
        vm.warp(vm.getBlockTimestamp() + 72 hours);
    }

    /// Settles the requests in flight (carol's randomness arrives, dave's never does) and runs retirement to its end.
    function _settle() internal {
        vm.roll(vm.getBlockNumber() + 3);
        deliverWord(pendingCarol, 424_242);
        vm.roll(vm.getBlockNumber() + 300); // past dave's randomness deadline
        for (uint256 i; i < 30 && !sys.game.retired(); ++i) {
            vm.prank(keeper);
            sys.game.retireStep();
        }
        assertTrue(sys.game.retired(), "V1 settled and unwound");
    }

    // ------------------------------------------------------------------ the full migration

    Snapshot snap;
    uint256[3] refs;
    uint256 returnedByGame;
    uint256 daveCredit;

    function test_fullMigrationConservesAssetsAndClaims() public {
        snap = _snapshot();
        uint256 ownerEth = owner.balance;
        for (uint256 i; i < 3; ++i) {
            (uint128 r,,,,,) = sys.poolOwner.nfts(apeIds[i]);
            refs[i] = r;
        }
        MockSuccessor s = _successor();
        _authorize(address(s));
        vm.prank(trader);
        m.execute(); // anyone
        _checkStopped();
        _settle();
        _checkClaimsAndUnwinding();
        _checkApesMigrated(s);
        _checkCapitalMigrated(s);
        assertEq(owner.balance, ownerEth, "nothing to the owner");
        _checkCoinCarriesOn(s);
        assertBooks();
    }

    function _checkStopped() internal {
        // V1 stops for good: no new draws, direct FWA purchases included
        assertTrue(m.started() && sys.game.retiring() && pool.retired(), "V1 retired its FWA pool");
        assertEq(sys.hook.feeRecipient(), m.successor(), "trading fees follow the successor at once");
        assertFalse(pool.localPurchasesEnabled());
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        uint256 version = pool.inventoryVersion();
        vm.deal(bob, total);
        vm.prank(bob);
        vm.expectRevert();
        pool.acquire{value: total}(bob, fee, 0, 10_000, version, vm.getBlockTimestamp() + 1 hours);
        // nothing moves before V1 has settled every request
        vm.expectRevert(MigrationAuthority.NotSettled.selector);
        m.migrateApes(10);
        vm.expectRevert(MigrationAuthority.NotSettled.selector);
        m.migrateCapital();
        _checkCommittedUntouched();
    }

    function _checkCommittedUntouched() internal view {
        assertEq(address(sys.burner).balance, snap.burner, "burner untouched");
        assertEq(sys.burner.reserve(), snap.reserve, "milestone reserve untouched");
    }

    function _checkClaimsAndUnwinding() internal {
        // player claims survive: carol's draw settled and she holds her prize; dave's refund is claimable
        assertEq(uint8(statusOf(pendingCarol)), uint8(IFWAPool.AcquisitionStatus.Fulfilled));
        (,,, uint256 carolListing,) = pool.acquisitions(pendingCarol);
        (address prizeColl,,, uint256 prizeId,,,,) = pool.listings(carolListing);
        assertEq(IERC721Lite(prizeColl).ownerOf(prizeId), carol, "carol's prize delivered");
        assertEq(uint8(statusOf(pendingDave)), uint8(IFWAPool.AcquisitionStatus.Expired));
        daveCredit = pool.acquisitionRefundCredit(dave);
        assertGt(daveCredit, 0, "dave's refund credit");
        // every Shape and Pack redeemed; their ETH and all game cash returned to the vault
        assertEq(sys.game.liveCount(), 0);
        assertEq(address(sys.game).balance, 0);
        assertEq(IERC721Lite(cfg.shapes).balanceOf(address(sys.poolOwner)), 0, "no Shapes left in custody");
        assertEq(IERC721Lite(sys.packs).balanceOf(address(sys.poolOwner)), 0, "no Packs left in custody");
        returnedByGame = sys.vault.returnedFromGame() - snap.returned;
        assertGt(returnedByGame, snap.backing, "prize backing (and the reserve) came back");
        _checkCommittedUntouched();
    }

    function _checkApesMigrated(MockSuccessor s) internal {
        // batched and retryable: two NFTs, then the rest
        assertEq(m.migrateApes(2), 2);
        assertEq(m.migrateApes(10), 1);
        assertEq(m.migrateApes(10), 0, "nothing left");
        for (uint256 i; i < 3; ++i) {
            assertEq(IERC721Lite(cfg.collection).ownerOf(apeIds[i]), address(s), "same token, at the successor");
            (uint128 ref,,,,,) = sys.poolOwner.nfts(apeIds[i]);
            assertEq(ref, refs[i], "its V1 record stays readable");
        }
        assertEq(s.apeCount(), 3);
        assertEq(sys.poolOwner.migratedCount(), 3);
        assertEq(sys.poolOwner.custodyCount(), 0);
    }

    function _checkCapitalMigrated(MockSuccessor s) internal {
        m.migrateCapital();
        // conservation: the successor received exactly the vault's balance and everything the game returned
        assertEq(address(sys.vault).balance, 0);
        assertEq(s.capitalReceived(), snap.vault + returnedByGame, "every wei of treasury capital");
        assertEq(s.capitalReceived(), sys.vault.migratedOut());
        assertEq(m.capitalMigrated(), s.capitalReceived());
        // committed buyback ETH never became migration capital
        _checkCommittedUntouched();
    }

    function _checkCoinCarriesOn(MockSuccessor s) internal {
        // the coin and its burner carry on: committed ETH is still spent on buy-and-burn
        uint256 reserve = sys.burner.reserve();
        sys.burner.releaseRetired();
        assertEq(sys.burner.reserve(), 0, "the milestone reserve is spent once V1 can win nothing");
        assertEq(sys.burner.milestoneBalance(), reserve);
        uint256 burnedBefore = sys.burner.totalBurned();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(keeper);
        sys.burner.process(0);
        assertGt(sys.burner.totalBurned(), burnedBefore, "buy-and-burn continues");
        // trading continues on the same market; its fees now fund the successor
        uint256 vaultFees = sys.vault.tradingFees();
        buyCoin(trader, 1 ether);
        assertGt(s.feesReceived(), 0, "fees to the successor");
        assertEq(sys.vault.tradingFees(), vaultFees, "none to V1");
        // dave withdraws his refund from FWA after the migration
        uint256 daveBefore = dave.balance;
        vm.prank(dave);
        pool.withdrawAcquisitionRefund();
        assertEq(dave.balance - daveBefore, daveCredit);
    }

    // ------------------------------------------------------------------ proposal and delay

    function test_executionNeedsTheOwnersProposalAndTheDelay() public {
        MockSuccessor s = _successor();
        vm.expectRevert(MigrationAuthority.NothingPending.selector);
        m.execute();
        vm.prank(trader);
        vm.expectRevert();
        m.propose(address(s));
        // only a contract can be proposed
        vm.prank(council);
        vm.expectRevert(MigrationAuthority.NotAContract.selector);
        m.propose(trader);
        vm.prank(council);
        m.propose(address(s));
        assertEq(m.executableAt(), vm.getBlockTimestamp() + 72 hours);
        assertEq(m.pendingCodeHash(), address(s).codehash, "its code is pinned");
        vm.warp(vm.getBlockTimestamp() + 72 hours - 1);
        vm.expectRevert(MigrationAuthority.TooEarly.selector);
        m.execute();
        // the owner can withdraw it
        vm.prank(council);
        m.propose(address(0));
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.expectRevert(MigrationAuthority.NothingPending.selector);
        m.execute();
        assertFalse(sys.game.retiring());
    }

    /// The owner cannot skip the delay: the custody, capital and fee hooks answer only to the MigrationAuthority.
    function test_ownerCannotBypassTheDelay() public {
        vm.startPrank(owner);
        vm.expectRevert(CollectionPoolOwner.NotMigrator.selector);
        sys.poolOwner.migrateApe(owner);
        vm.expectRevert(FundingVault.NotMigrator.selector);
        sys.vault.migrateCapital(owner);
        vm.expectRevert(CollectionHook.NotMigrator.selector);
        sys.hook.setFeeRecipient(owner);
        vm.expectRevert(Governed.NotOwner.selector);
        sys.game.retire();
        vm.stopPrank();
    }

    /// The proposed successor's code is what runs: code changed after the proposal cannot execute.
    function test_changedCodeCannotExecute() public {
        MockSuccessor s = _successor();
        _authorize(address(s));
        vm.etch(address(s), address(new RejectingReceiver()).code);
        vm.expectRevert(MigrationAuthority.CodeChanged.selector);
        m.execute();
    }

    /// Trading fees move only to a contract proposed 72 hours earlier, with its code pinned; the game runs on.
    function test_feeRecipientMovesOnlyAfterTheNotice() public {
        MockSuccessor splitter = _successor();
        vm.prank(trader);
        vm.expectRevert(Governed.NotCouncil.selector);
        m.proposeFeeRecipient(address(splitter));
        vm.prank(council);
        vm.expectRevert(MigrationAuthority.NotAContract.selector);
        m.proposeFeeRecipient(trader);
        vm.prank(council);
        m.proposeFeeRecipient(address(splitter));
        assertEq(m.feeExecutableAt(), vm.getBlockTimestamp() + 72 hours);
        vm.warp(vm.getBlockTimestamp() + 72 hours - 1);
        vm.expectRevert(MigrationAuthority.TooEarly.selector);
        m.executeFeeRecipient();
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(trader);
        m.executeFeeRecipient(); // anyone
        assertEq(sys.hook.feeRecipient(), address(splitter));
        assertFalse(sys.game.retiring(), "the game runs on");
        buyCoin(trader, 1 ether);
        assertGt(splitter.feesReceived(), 0, "fees to the new recipient");
    }

    function test_incompleteSettlementBlocksTheHandOver() public {
        MockSuccessor s = _successor();
        _authorize(address(s));
        m.execute();
        // carol's request is still pending: V1 cannot finish retiring
        vm.prank(keeper);
        sys.game.retireStep();
        assertFalse(sys.game.retired());
        vm.expectRevert(MigrationAuthority.NotSettled.selector);
        m.migrateApes(10);
        vm.expectRevert(MigrationAuthority.NotSettled.selector);
        m.migrateCapital();
    }

    /// A later proposal (again 72 hours) replaces the successor for whatever has not moved yet.
    function test_laterProposalReplacesTheSuccessorForWhatRemains() public {
        MockSuccessor s1 = _successor();
        _authorize(address(s1));
        m.execute();
        _settle();
        m.migrateApes(1);
        MockSuccessor s2 = _successor();
        _authorize(address(s2));
        m.execute();
        assertEq(m.successor(), address(s2));
        m.migrateApes(10);
        m.migrateCapital();
        assertEq(s1.apeCount(), 1);
        assertEq(s2.apeCount(), 2);
        assertGt(s2.capitalReceived(), 0);
    }

    /// The capital transfer cannot be blocked by the successor: a contract refusing ETH still receives it.
    function test_successorRefusingEthStillReceivesCapital() public {
        RejectingReceiver r = new RejectingReceiver();
        _authorize(address(r));
        m.execute();
        _settle();
        uint256 v = address(sys.vault).balance;
        assertEq(m.migrateCapital(), v);
        assertEq(address(r).balance, v);
    }

    /// The sunset cancels a pending migration and, after a migration has started, takes whatever has not moved yet:
    ///         the owner can always send the rest to buybacks at once, never anywhere else.
    function test_sunsetOverridesAMigration() public {
        MockSuccessor s = _successor();
        vm.prank(council);
        m.propose(address(s));
        govern(address(m), abi.encodeCall(MigrationAuthority.sunset, ()));
        assertEq(m.pending(), address(0), "the pending proposal is cancelled");
        assertEq(m.successor(), address(sys.sunset));
        assertEq(sys.hook.feeRecipient(), address(sys.sunset));
        _settle();
        assertEq(m.migrateApes(10), 3);
        assertEq(s.apeCount(), 0);
    }

    function test_sunsetTakesWhatAMigrationHasNotMoved() public {
        MockSuccessor s = _successor();
        _authorize(address(s));
        m.execute();
        _settle();
        m.migrateApes(1);
        govern(address(m), abi.encodeCall(MigrationAuthority.sunset, ()));
        assertEq(m.migrateApes(10), 2);
        assertEq(s.apeCount(), 1);
        uint256 v = address(sys.vault).balance;
        assertEq(m.migrateCapital(), v);
        assertEq(address(sys.sunset).balance, v, "the rest of the capital to the sunset, for buybacks");
    }

    /// An Ape whose delivery to its winner failed belongs to the winner's claim: it does not block the hand-over; if
    /// the winner later takes the refund instead, the Ape follows the others to the successor.
    function test_quarantinedApeFollowsLater() public {
        // clear the queue first (the scenario's draws in flight), then win an Ape with a delivery that fails
        vm.roll(vm.getBlockNumber() + 3);
        deliverWord(pendingCarol, 1);
        vm.roll(vm.getBlockNumber() + 300);
        pool.processAcquisitions(10);
        uint256 r = pull(carol);
        vm.roll(vm.getBlockNumber() + 3);
        vm.mockCallRevert(cfg.collection, abi.encodeWithSignature("transferFrom(address,address,uint256)"), "");
        deliverWord(r, wordFor(type(uint256).max));
        pool.processAcquisitions(10);
        vm.clearMockedCalls();
        (,,, uint256 listingId,) = pool.acquisitions(r);
        assertEq(uint8(statusOf(r)), uint8(IFWAPool.AcquisitionStatus.DeliveryPending));
        MockSuccessor s = _successor();
        _authorize(address(s));
        m.execute();
        _settle();
        assertEq(m.migrateApes(10), 2, "the two Apes not in quarantine");
        // carol takes the refund after FWA's window; the Ape is recovered and migrated
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        vm.prank(carol);
        pool.refundFailedDelivery(listingId);
        // a keeper's retirement step books the refunded request: the Ape returns to custody (anyone may also call
        // `CollectionPoolOwner.settleListing`)
        sys.game.retireStep();
        assertEq(m.migrateApes(10), 1);
        assertEq(s.apeCount(), 3);
        assertGt(pool.acquisitionRefundCredit(carol), 0, "carol's refund stands");
    }

    function test_milestoneReserveReleasesOnlyAfterRetirement() public {
        vm.expectRevert(CollectionBurner.NotRetired.selector);
        sys.burner.releaseRetired();
    }
}
