// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {CollectionBurner} from "../../src/treasury/CollectionBurner.sol";
import {Governed} from "../../src/core/Governed.sol";

/// @notice Surplus distribution (a share to the vault while it is short of one Ape, the rest to the burner), the
///         burner's milestone reserve, ongoing and milestone buybacks (D63: no router, no separate milestone reserve).
contract RevenueForkTest is ForkBase {
    address alice = makeAddr("cg.player.alice");
    address trader = makeAddr("cg.trader");

    function setUp() public {
        deployChecksAt(6 ether);
        launchGame(6 ether);
        pastOpeningCurve();
        buyCoin(trader, 5 ether); // some market depth beyond the opening
    }

    /// While the vault is short of one Ape, its share (35% at launch) of each distribution goes to it and the rest to the burner, which locks
    /// its milestone share (25%) in the reserve.
    function test_distributionSplitsVaultThenBurner() public {
        playMany(alice, 120, 22); // a seed whose 120 draws end in profit
        uint256 d = sys.game.distributed();
        assertGt(d, 0, "realised surplus distributed");
        assertEq(sys.game.toVault() + sys.game.toBurner(), d);
        assertGt(sys.vault.shortfall(), 0, "the vault is still short of an Ape");
        assertApproxEqAbs(sys.game.toVault(), d * cfg.settings.continuityShareBps / 10_000, 10, "the vault's share");
        assertEq(sys.vault.surplusIn(), sys.game.toVault());
        assertEq(sys.burner.reserveIn() + sys.burner.ongoingIn(), sys.game.toBurner(), "the rest to the burner");
        assertApproxEqAbs(sys.burner.reserveIn(), sys.game.toBurner() * cfg.milestoneBps / 10_000, 10, "milestone share locked");
        assertEq(sys.burner.reserve(), sys.burner.reserveIn());
        assertBooks();
    }

    /// Once the vault can buy an Ape, every distribution goes to the burner.
    function test_allSurplusToBuybacksOnceTheVaultHoldsAnApe() public {
        accrueFees(40 ether); // well beyond one Ape after the game's needs
        assertEq(sys.vault.shortfall(), 0);
        uint256 toVault = sys.game.toVault();
        playMany(alice, 120, 22);
        assertGt(sys.game.distributed(), 0);
        assertEq(sys.game.toVault(), toVault, "nothing more to the vault");
        assertEq(sys.burner.reserveIn() + sys.burner.ongoingIn(), sys.game.toBurner());
    }

    /// The burner takes ETH from anyone into the ongoing bucket; only the game's surplus feeds the milestone reserve.
    function test_burnerTakesDonationsAsOngoing() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(sys.burner).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(sys.burner.ongoingBalance(), 1 ether);
        assertEq(sys.burner.reserve(), 0, "a donation never reaches the reserve");
    }

    /// The milestone share is the owner's, 0-100%.
    function test_ownerSetsTheMilestoneShare() public {
        vm.prank(alice);
        vm.expectRevert(Governed.NotOwner.selector);
        sys.burner.setMilestoneBps(5_000);
        govern(address(sys.burner), abi.encodeCall(CollectionBurner.setMilestoneBps, (7_500)));
        assertEq(sys.burner.milestoneBps(), 7_500);
        vm.prank(owner);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.burner.setMilestoneBps(10_001);
    }

    /// The ongoing cadence follows play (D64): a slice is 0.05 ETH plus 0.005 ETH per draw since the last plus 1% of
    /// the bucket, at most 1 ETH; the spacing is 60 minutes when idle, halved every 20 draws, never under 10 minutes.
    function test_ongoingBuybacksFollowPlay() public {
        // all gameplay buybacks wait for an Ape at launch (D74): this exercises the drip at the D64 settings (75% to the
        // reserve, a big prize releasing 15%), which it was written around
        govern(address(sys.burner), abi.encodeCall(CollectionBurner.setMilestoneBps, (7_500)));
        govern(address(sys.burner), abi.encodeCall(CollectionBurner.setTiers, (CollectionBurner.Tiers(0.5 ether, 1_500, 6_000, 24 hours))));
        for (uint256 k; k < 10 && sys.burner.ongoingBalance() <= 0.3 ether; ++k) {
            playMany(alice, 300, 26 + k);
        }
        uint256 ongoing = sys.burner.ongoingBalance();
        uint256 n = sys.burner.drawsSinceLastRun();
        assertGt(n, 100, "the draws since the last slice");
        (uint256 amount, bool milestone, uint256 runAt) = sys.burner.nextSlice();
        if (sys.burner.milestoneBalance() != 0) {
            // a big prize released milestone ETH during play: it goes first, 1 ETH at a time
            uint256 m = sys.burner.milestoneBalance();
            assertTrue(milestone);
            assertEq(amount, m < 1 ether ? m : 1 ether);
        } else {
            uint256 want = 0.05 ether + 0.005 ether * n + ongoing / 100;
            if (want > 1 ether) want = 1 ether;
            if (want > ongoing) want = ongoing;
            assertFalse(milestone);
            assertEq(amount, want, "0.05 ETH + 0.005 ETH a draw + 1% of the bucket, capped");
        }
        assertEq(runAt, sys.burner.lastRunAt() + 10 minutes, "many draws: the shortest spacing");
        vm.warp(runAt);
        uint256 supply = sys.token.totalSupply();
        vm.prank(keeper);
        uint256 burned = sys.burner.process(0);
        assertGt(burned, 0);
        assertEq(supply - sys.token.totalSupply(), burned, "every bought token burned");
        assertEq(sys.token.balanceOf(address(sys.burner)), 0);
        assertLe(sys.burner.ongoingSpent() + sys.burner.milestoneSpent(), 1 ether, "bounded slice");
        // with no draws since, the next is the idle slice an hour later
        assertEq(sys.burner.drawsSinceLastRun(), 0);
        (amount,, runAt) = sys.burner.nextSlice();
        if (sys.burner.milestoneBalance() == 0) {
            assertLe(amount, 0.05 ether + sys.burner.ongoingBalance() / 100, "idle slice");
            assertEq(runAt, vm.getBlockTimestamp() + 60 minutes, "idle spacing");
        }
        vm.prank(keeper);
        vm.expectRevert(CollectionBurner.TooSoon.selector);
        sys.burner.process(0);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 1); // a new block: the burner compares with the block-open price
        // the slice may have emptied the bucket on this draw sequence: keep something to spend, so the next call reaches
        // the output check (ETH sent to the burner by anyone is ongoing)
        if (sys.burner.ongoingBalance() == 0 && sys.burner.milestoneBalance() == 0) {
            vm.deal(address(this), address(this).balance + 0.1 ether);
            (bool ok,) = address(sys.burner).call{value: 0.1 ether}("");
            assertTrue(ok);
        }
        vm.prank(keeper);
        vm.expectRevert(CollectionBurner.InsufficientOutput.selector);
        sys.burner.process(type(uint256).max);
    }

    function test_buybackRefusesSameBlockManipulation() public {
        govern(address(sys.burner), abi.encodeCall(CollectionBurner.setMilestoneBps, (7_500))); // an ongoing bucket to spend (D74)
        playMany(alice, 160, 27);
        assertGt(sys.burner.ongoingBalance(), 0);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.roll(vm.getBlockNumber() + 1);
        // a large buy ahead of the buyback in the same block moves the price more than 2%
        buyCoin(trader, 3 ether);
        vm.prank(keeper);
        vm.expectRevert(CollectionBurner.PriceMoved.selector);
        sys.burner.process(0);
        // next block it proceeds, from the new price, with the 3% impact cap
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(keeper);
        sys.burner.process(0);
    }

    /// The reserve is released only for a delivered collection win, read from FWA; a Shape win never qualifies.
    function test_releaseNeedsADeliveredCollectionWin() public {
        playMany(alice, 120, 22);
        uint256 r = pull(alice);
        vm.roll(vm.getBlockNumber() + 3);
        deliverWord(r, wordFor(0));
        pool.processAcquisitions(10);
        (,,, uint256 shapeListing,) = pool.acquisitions(r);
        assertFalse(sys.burner.qualifies(shapeListing));
        vm.expectRevert(CollectionBurner.NotQualifying.selector);
        sys.burner.release(shapeListing);
        vm.expectRevert(CollectionBurner.NotRetired.selector);
        sys.burner.releaseRetired();
    }

    /// An Ape exit releases 60% of the reserve at booking; a second exit within 24 hours the rest; released ETH is
    /// bought 1 ETH every 10 minutes, the first slice at once.
    function test_milestoneBuybackExecutesInSlicesAndTwoWinsAccountedApart() public {
        // the launch releases the whole pot on an Ape (D74): this exercises the first-exit and second-exit tiers (D64)
        govern(address(sys.burner), abi.encodeCall(CollectionBurner.setTiers, (CollectionBurner.Tiers(0.5 ether, 1_500, 6_000, 24 hours))));
        playMany(alice, 160, 28);
        uint256 r1 = sys.burner.reserve();
        assertGt(r1, 0);
        uint256 in0 = sys.burner.milestoneIn();
        // a second Ape so that winning the first leaves one in play
        accrueFees(30 ether);
        riseBidTo(6 ether);
        sellCheck(nextCheckId());
        syncAll();
        uint256 first = _winAny();
        vm.prank(keeper);
        sys.game.sync();
        assertTrue(sys.burner.released(first));
        assertEq(sys.burner.milestoneIn() - in0, r1 * 6_000 / 10_000, "60% of the reserve released at booking");
        (,, uint256 runAt) = sys.burner.nextSlice();
        assertLe(runAt, vm.getBlockTimestamp(), "the release's first slice may run at once");
        // more surplus accrues, then the other Ape is won before the first release is spent
        window();
        playMany(alice, 120, 29);
        uint256 r2 = sys.burner.reserve();
        uint256 in1 = sys.burner.milestoneIn();
        uint256 n1 = sys.burner.releases();
        uint256 second = _winAny();
        vm.prank(keeper);
        sys.game.sync();
        assertTrue(sys.burner.released(second));
        assertEq(sys.burner.releases(), n1 + 1);
        assertEq(sys.burner.milestoneIn() - in1, r2, "a second exit within 24 hours: the rest");
        vm.expectRevert(CollectionBurner.AlreadyReleased.selector);
        sys.burner.release(second);
        // the burner spends milestone ETH first, a bounded slice at a time
        uint256 slices;
        while (sys.burner.milestoneBalance() != 0 && slices < 60) {
            vm.warp(vm.getBlockTimestamp() + 10 minutes);
            vm.roll(vm.getBlockNumber() + 1);
            vm.prank(keeper);
            sys.burner.process(0);
            ++slices;
        }
        assertEq(sys.burner.milestoneBalance(), 0);
        assertEq(sys.burner.milestoneSpent() + _milestoneTips(), sys.burner.milestoneIn());
        assertGt(sys.burner.milestoneBurned(), 0);
        emit log_named_uint("milestone slices", slices);
    }

    /// Keeper reimbursements taken from milestone slices (0 in tests: the test gas price is 0).
    function _milestoneTips() internal view returns (uint256) {
        return sys.burner.milestoneIn() - sys.burner.milestoneSpent() - sys.burner.milestoneBalance();
    }

    function _winAny() internal returns (uint256 listingId) {
        uint256 r = pull(alice);
        vm.roll(vm.getBlockNumber() + 3);
        deliverWord(r, wordFor(type(uint256).max));
        pool.processAcquisitions(10);
        (,,, listingId,) = pool.acquisitions(r);
    }
}
