// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase, IERC721Lite} from "./ForkBase.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {CollectionGame} from "../../src/game/CollectionGame.sol";
import {FundingVault} from "../../src/core/FundingVault.sol";
import {MigrationAuthority} from "../../src/migration/MigrationAuthority.sol";
import {Sunset} from "../../src/migration/Sunset.sol";
import {Governed} from "../../src/core/Governed.sol";

/// @notice The end of the game into the built-in sunset successor (D63): the owner triggers it at once because the only
///         destination is buybacks. Requests in flight settle, refunds stay claimable, Shapes burn back to ETH, the
///         Apes are auctioned and every wei reaches the burner; nothing reaches the owner.
contract SunsetForkTest is ForkBase {
    address alice = makeAddr("cg.player.alice");
    address bidder = makeAddr("cg.bidder");

    function setUp() public {
        // a small opening allowance, so the game holds more cash than keepers may be paid (the cap under test)
        setUpFork();
        cfg = _testChecksConfigAt(6 ether);
        cfg.openingAllowance = 0.1 ether;
        _deploy();
        launchGame(6 ether);
    }

    function _sunset() internal {
        govern(address(sys.migration), abi.encodeCall(MigrationAuthority.sunset, ()));
    }

    function test_sunsetWithPendingRequestsAuctionsAndBurns() public {
        playMany(alice, 40, 1);
        uint256 a = pull(alice);
        uint256 b = pull(alice);
        uint256 ownerBalance = owner.balance;
        _sunset();
        assertTrue(pool.retired());
        assertFalse(pool.localPurchasesEnabled());
        assertEq(sys.migration.successor(), address(sys.sunset));
        assertEq(sys.hook.feeRecipient(), address(sys.sunset), "trading fees follow the sunset");
        // sync is closed; retireStep cannot finish while requests are unsettled
        vm.expectRevert(CollectionGame.Retiring.selector);
        sys.game.sync();
        vm.prank(keeper);
        sys.game.retireStep();
        assertFalse(sys.game.retired());
        // the requests settle after retirement; one expires, one is fulfilled
        vm.roll(vm.getBlockNumber() + 3);
        deliverWord(a, 1);
        vm.roll(vm.getBlockNumber() + 40);
        pool.processAcquisitions(10);
        assertEq(uint8(statusOf(a)), uint8(IFWAPool.AcquisitionStatus.Fulfilled));
        assertEq(uint8(statusOf(b)), uint8(IFWAPool.AcquisitionStatus.Expired));
        for (uint256 i; i < 10 && !sys.game.retired(); ++i) {
            vm.prank(keeper);
            sys.game.retireStep();
        }
        assertTrue(sys.game.retired());
        assertEq(address(sys.game).balance, 0, "everything returned to the vault");
        assertEq(sys.game.liveCount(), 0, "every prize withdrawn and cashed out");
        // the expired request's refund is still claimable
        assertGt(pool.acquisitionRefundCredit(alice), 0);
        vm.prank(alice);
        pool.withdrawAcquisitionRefund();
        // the Ape and the vault's ETH go to the sunset; the milestone reserve is released for buybacks
        assertEq(sys.migration.migrateApes(10), 1);
        uint256 vaultBal = address(sys.vault).balance;
        assertEq(sys.migration.migrateCapital(), vaultBal);
        assertEq(address(sys.vault).balance, 0);
        uint256 before = sys.burner.ongoingBalance();
        assertEq(sys.sunset.flush(), vaultBal);
        assertEq(sys.burner.ongoingBalance() - before, vaultBal, "the vault's ETH committed to buybacks");
        sys.burner.releaseRetired();
        assertEq(sys.burner.reserve(), 0);
        // auction: 150% of the recorded cost at the start (the flush, a keeper job, started the clock), 25% after 30
        // days; the price to the burner, any excess back to the buyer
        uint256 ape = _sunsetApe();
        assertEq(sys.sunset.startedAt(), vm.getBlockTimestamp(), "the flush started the clock");
        assertEq(sys.sunset.auctionPrice(ape), 9 ether);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        uint256 price = sys.sunset.auctionPrice(ape);
        assertEq(price, 1.5 ether);
        vm.deal(bidder, price - 1);
        vm.prank(bidder);
        vm.expectRevert(Sunset.Underpaid.selector);
        sys.sunset.buy{value: price - 1}(ape);
        vm.deal(bidder, price + 1 ether);
        before = sys.burner.ongoingBalance();
        vm.prank(bidder);
        sys.sunset.buy{value: price + 1 ether}(ape);
        assertEq(IERC721Lite(cfg.collection).ownerOf(ape), bidder);
        assertEq(bidder.balance, 1 ether, "the excess returned");
        assertEq(sys.sunset.auctionProceeds(), price);
        assertEq(sys.burner.ongoingBalance() - before, price, "auction proceeds committed to buybacks");
        assertEq(address(sys.sunset).balance, 0);
        assertEq(owner.balance, ownerBalance, "nothing to the owner");
    }

    function _sunsetApe() internal view returns (uint256) {
        for (uint256 id = 1; id < 20_000; ++id) {
            try IERC721Lite(cfg.collection).ownerOf(id) returns (address o) {
                if (o == address(sys.sunset)) return id;
            } catch {} // a Check burned in composition
        }
        revert("no Ape at the sunset");
    }

    /// Only the owner triggers the sunset; only the MigrationAuthority retires the game.
    function test_onlyTheOwnerSunsetsAndOnlyTheAuthorityRetires() public {
        vm.prank(alice);
        vm.expectRevert(Governed.NotOwner.selector);
        sys.migration.sunset();
        vm.prank(owner);
        vm.expectRevert(Governed.NotOwner.selector);
        sys.game.retire();
    }

    /// The sunset is final: no later successor and no other fee recipient, so everything still on its way to the Sunset
    /// (Apes in custody, capital, future fees) reaches buybacks. A migration likewise ties the fees to its successor.
    function test_sunsetIsFinal() public {
        address other = address(new SunsetOther());
        vm.prank(council);
        sys.migration.proposeFeeRecipient(other);
        _sunset();
        assertEq(sys.migration.pendingFeeRecipient(), address(0), "the pending fee recipient cancelled");
        vm.warp(vm.getBlockTimestamp() + 72 hours);
        vm.expectRevert(MigrationAuthority.NothingPending.selector);
        sys.migration.executeFeeRecipient();
        vm.startPrank(council);
        vm.expectRevert(MigrationAuthority.SunsetFinal.selector);
        sys.migration.propose(other);
        vm.expectRevert(MigrationAuthority.Started.selector);
        sys.migration.proposeFeeRecipient(other);
        vm.stopPrank();
        assertEq(sys.hook.feeRecipient(), address(sys.sunset));
    }

    /// Keeper pay never exceeds the allowance, during retirement too: raising the keeper parameters before a sunset
    /// cannot take the cash the retirement hands to the Sunset.
    function test_retirementPayWithinTheAllowance() public {
        playMany(alice, 40, 3);
        govern(
            address(sys.game),
            abi.encodeCall(CollectionGame.setKeeperParams, (CollectionGame.KeeperParams(30 gwei, 200_000, 0.001 ether, 0)))
        );
        _sunset();
        uint256 avail = sys.game.keeperAvailable();
        uint256 cash = address(sys.game).balance;
        assertGt(cash, avail, "more cash than allowance");
        vm.txGasPrice(1_000 gwei);
        uint256 kb = keeper.balance;
        for (uint256 i; i < 20 && !sys.game.retired(); ++i) {
            vm.prank(keeper);
            try sys.game.retireStep() {} catch {}
        }
        assertLe(sys.game.keeperPaid(), sys.game.keeperAllowance(), "never above the allowance");
        assertLe(keeper.balance - kb, avail, "the keeper took at most what was available");
        assertGt(keeper.balance - kb, 0, "and was paid");
    }

    function test_retiredGameRefusesNewCapitalAndAcquisitions() public {
        _sunset();
        accrueFees(20 ether);
        assertEq(sys.vault.acquisitionBudget(), 0);
        vm.expectRevert(FundingVault.NotAllowed.selector);
        sys.vault.fundGame();
    }

    function test_auctionOnlyAfterRetirement() public {
        vm.expectRevert(Sunset.NotRetired.selector);
        sys.sunset.start();
        vm.expectRevert(Sunset.NotRetired.selector);
        sys.sunset.buy{value: 0}(1);
    }
}

contract SunsetOther {
    receive() external payable {}
}
