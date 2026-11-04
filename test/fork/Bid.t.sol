// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CollectionPoolOwner} from "../../src/core/CollectionPoolOwner.sol";
import {ForkBase, IERC721Lite} from "./ForkBase.sol";
import {FundingVault} from "../../src/core/FundingVault.sol";
import {CollectionGame} from "../../src/game/CollectionGame.sol";
import {Governed} from "../../src/core/Governed.sol";

/// @notice The vault's live bid (docs/SPEC.md "The bid", D59), Permanent Collection's funding-driven model: real ETH
///         metered into one public bid, fast up to the activation threshold, then at most `maxSweepWei` per cooldown;
///         an acquisition subtracts the price paid and resets the threshold to 75% of it; no inventory limit; the
///         game's capital comes first; above 120% of the last price only a slow step (D60, D61). Every parameter is the
///         owner's.
contract BidForkTest is ForkBase {
    uint256 constant SWEEP = 1 ether; // the launch metered step (D82)
    uint256 constant COOLDOWN = 300;

    function setUp() public {
        deployChecksAt(6 ether);
        launchGame(6 ether); // the first Ape at 6 ETH: the threshold is now 4.5 ETH
        _wait(); // past the launch's last metered sweep
    }

    function _wait() internal {
        vm.roll(vm.getBlockNumber() + COOLDOWN);
        vm.warp(vm.getBlockTimestamp() + COOLDOWN * 12);
    }

    /// Funds arriving fast fill the bid to its threshold at once and no further: above it ETH is metered in.
    function test_fillsToThresholdThenMetered() public {
        assertEq(sys.vault.activationThreshold(), 4.5 ether, "75% of the clearing price");
        accrueFees(50 ether);
        assertGt(sys.vault.acquisitionBudget(), 40 ether);
        sys.vault.sweep();
        assertEq(sys.vault.liveBid(), 4.5 ether, "fast mode: clamped to land at the threshold");
        // the next sweep is metered
        uint256 before = sys.vault.liveBid();
        sys.vault.sweep();
        assertEq(sys.vault.liveBid(), before + SWEEP, "one metered step");
        uint256 next = sys.vault.nextSweepBlock();
        vm.expectRevert(abi.encodeWithSelector(FundingVault.SweepTooEarly.selector, next));
        sys.vault.sweep();
        _wait();
        sys.vault.sweep();
        assertEq(sys.vault.liveBid(), before + 2 * SWEEP);
    }

    /// No time-based rise: a month with nobody sweeping leaves the bid where it was; one sweep adds one step.
    function test_bidGrowsOnlyByEthForwarded() public {
        accrueFees(40 ether);
        sys.vault.sweep();
        sys.vault.sweep();
        uint256 b = sys.vault.liveBid();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.roll(vm.getBlockNumber() + 216_000);
        assertEq(sys.vault.liveBid(), b, "nothing accrues with time");
        sys.vault.sweep();
        assertEq(sys.vault.liveBid(), b + SWEEP, "a month later: one step, not a month of rise");
    }

    /// While the vault cannot fund the threshold, every ETH that arrives enters the bid at once.
    function test_belowThresholdEveryEthEntersAtOnce() public {
        accrueFees(1 ether);
        sys.vault.sweep();
        uint256 b = sys.vault.liveBid();
        assertGt(b, 0.9 ether);
        assertLt(b, 4.5 ether);
        accrueFees(1 ether);
        sys.vault.sweep(); // no cooldown below the threshold
        assertApproxEqAbs(sys.vault.liveBid(), b + 1 ether, 0.01 ether);
    }

    /// An acquisition takes the price paid out of the bid; the rest of the bid stays, and the threshold resets to 75%
    /// of the clearing price.
    function test_purchaseSubtractsPriceAndKeepsTheRest() public {
        accrueFees(40 ether);
        uint256 bid = riseBidTo(6.2 ether);
        assertGe(bid, 6.2 ether);
        uint256 balance = sys.vault.bidBalance();
        sellCheckAt(nextCheckId(), 5.9 ether); // the holder asked less than the bid
        assertEq(sys.vault.bidBalance(), balance - 5.9 ether, "unspent bid ETH stays");
        assertEq(sys.vault.lastPrice(), 5.9 ether);
        assertEq(sys.vault.activationThreshold(), 4.425 ether, "75% of 5.9");
        assertEq(sys.vault.lastPrice(), 5.9 ether);
        sys.vault.sweep();
        assertEq(sys.vault.liveBid(), 4.425 ether, "refilled to the new threshold at once");
    }

    /// The holder names its price: never above the live bid, never zero.
    function test_sellerNamesPriceAtMostTheBid() public {
        accrueFees(20 ether);
        uint256 bid = riseBidTo(5 ether);
        uint256 id = nextCheckId();
        address holder = IERC721Lite(cfg.collection).ownerOf(id);
        vm.startPrank(holder);
        IERC721Lite(cfg.collection).setApprovalForAll(address(sys.vault), true);
        vm.expectRevert(abi.encodeWithSelector(FundingVault.AboveBid.selector, bid));
        sys.vault.sellToProtocol(id, bid + 1);
        vm.expectRevert(abi.encodeWithSelector(FundingVault.AboveBid.selector, bid));
        sys.vault.sellToProtocol(id, 0);
        uint256 before = holder.balance;
        sys.vault.sellToProtocol(id, bid);
        vm.stopPrank();
        assertEq(holder.balance - before, bid, "paid exactly the named price");
        assertEq(IERC721Lite(cfg.collection).ownerOf(id), address(sys.poolOwner));
    }

    /// No inventory limit: with funds, the vault keeps buying; each purchase resets the threshold.
    function test_noInventoryLimit() public {
        accrueFees(60 ether);
        for (uint256 i; i < 5; ++i) {
            riseBidTo(6 ether);
            sellCheckAt(nextCheckId(), 6 ether);
            assertEq(sys.vault.activationThreshold(), 4.5 ether);
        }
        assertEq(sys.poolOwner.heldCount(), 6);
        assertGt(sys.vault.acquisitionBudget(), 0, "still buying");
    }

    /// The game's capital comes first: when the game needs capital, the live bid is what is left, and a sweep
    /// clamps the bid's ETH to it.
    function test_gameCapitalComesFirst() public {
        accrueFees(10 ether);
        riseBidTo(6 ether);
        assertGe(sys.vault.liveBid(), 6 ether);
        // the owner raises the operating reserve: the game now needs 6 ETH more from the vault
        (uint256 reserve, uint256 interval, uint256 minLive, uint256 maxOut, uint256 edge, uint256 cool, uint256 minD,
            uint256 cont) = sys.game.settings();
        CollectionGame.Settings memory st = CollectionGame.Settings(reserve + 6 ether, interval, minLive, maxOut, edge,
            cool, minD, cont);
        govern(address(sys.game), abi.encodeCall(CollectionGame.setSettings, (st)));
        uint256 budget = sys.vault.acquisitionBudget();
        assertLt(budget, 6 ether);
        assertEq(sys.vault.liveBid(), budget, "the bid is what the game does not need");
        // a seller cannot be paid out of the game's capital
        uint256 id = nextCheckId();
        address holder = IERC721Lite(cfg.collection).ownerOf(id);
        vm.startPrank(holder);
        IERC721Lite(cfg.collection).setApprovalForAll(address(sys.vault), true);
        vm.expectRevert(abi.encodeWithSelector(FundingVault.AboveBid.selector, budget));
        sys.vault.sellToProtocol(id, 6 ether);
        vm.stopPrank();
        sys.vault.fundGame();
        assertEq(sys.game.capitalNeed(), 0);
    }

    /// Anyone sweeps and is rewarded like a keeper (D82): its gas at the game's capped gas price plus the flat fee,
    /// whatever the size of the sweep, at most 0.01 ETH.
    function test_sweepIsPermissionlessAndRewarded() public {
        accrueFees(20 ether);
        uint256 paid0 = sys.vault.sweepRewards();
        uint256 flat = sys.game.keeperParams().flatFee;
        address anyone = makeAddr("anyone");
        uint256 before = anyone.balance;
        vm.prank(anyone);
        uint256 fwd = sys.vault.sweep();
        assertEq(anyone.balance - before, flat, "at a zero gas price: the flat fee alone, for a fill of ~4.5 ETH");
        assertGt(fwd, 4 ether);
        vm.roll(vm.getBlockNumber() + 300);
        vm.txGasPrice(1 gwei);
        before = anyone.balance;
        vm.prank(anyone);
        fwd = sys.vault.sweep();
        assertEq(fwd, SWEEP);
        uint256 r = anyone.balance - before;
        assertGt(r, flat, "gas is reimbursed too");
        assertLt(r, flat + 0.001 ether, "at 1 gwei, about its gas");
        assertEq(sys.vault.sweepRewards() - paid0, flat + r);
    }

    /// No cap at launch: if the floor doubles overnight, the bid still reaches it with nobody updating anything (above
    /// the 120% ceiling at a twentieth of the rate: about 80 days from 7.2 to 12 ETH), and the threshold and the ceiling
    /// follow the new price.
    function test_risingFloorNeedsNoUpdate() public {
        assertEq(sys.vault.bidParams().maxPrice, 0, "no cap");
        // the council has moved the 80-Check price with the market (the shown bid stops at 120% of it, D012; that cap
        // is tested in ChecksAcquisition.t.sol): the bid climbs on its own, slowly above its own ceiling
        _setSchedule(12 ether);
        accrueFees(40 ether);
        uint256 start = vm.getBlockNumber();
        uint256 bid = riseBidTo(12 ether);
        assertGe(bid, 12 ether, "reached a doubled floor");
        // 4.8 ETH above the 7.2 ETH ceiling at 0.01 ETH per 300 blocks (D82): 480 sweeps, 20 days
        assertApproxEqRel((vm.getBlockNumber() - start) * 12, 20 days, 0.15e18, "slowly above the ceiling");
        uint256 id = nextCheckId();
        sellCheckAt(id, 12 ether);
        assertEq(sys.vault.activationThreshold(), 9 ether);
        assertEq(sys.vault.bidCeiling(), 14.4 ether, "120% of the new price");
    }

    function sellAt(uint256 id, uint256 price) external {
        sellCheckAt(id, price);
    }

    /// @dev The council sets the 80-Check price (the vault's purchase cap is 120% of it).
    function _setSchedule(uint256 price) internal {
        uint256[8] memory sched = sys.poolOwner.schedule();
        sched[0] = price;
        councilCall(address(sys.poolOwner), abi.encodeCall(CollectionPoolOwner.setSchedule, (sched)));
    }

    /// The ceiling (D60, D61): above 120% of the last acquisition price a sweep forwards only `slowSweepWei`; a bid nobody
    /// accepts climbs a tenth as fast instead of piling up. It moves with every acquisition.
    function test_ceilingSlowsTheBidAboveIt() public {
        _setSchedule(20 ether); // the schedule cap out of the way: this exercises the vault's own ceiling
        assertEq(sys.vault.bidCeiling(), 7.2 ether, "120% of the 6 ETH clearing price");
        accrueFees(40 ether);
        assertEq(riseBidTo(7.2 ether), 7.2 ether, "the normal meter lands exactly on the ceiling");
        _wait();
        sys.vault.sweep();
        assertEq(sys.vault.liveBid(), 7.21 ether, "above it, the slow step");
        _wait();
        sys.vault.sweep();
        assertEq(sys.vault.liveBid(), 7.22 ether);
        // a purchase moves the ceiling with its price
        sellCheckAt(nextCheckId(), 7 ether);
        assertEq(sys.vault.bidCeiling(), 8.4 ether);
        assertEq(sys.vault.activationThreshold(), 5.25 ether);
    }

    /// The owner may make the ceiling a hard stop (`slowSweepWei` 0) or remove it (`ceilingBps` 0); bounds hold.
    function test_ceilingIsTheOwners() public {
        _setSchedule(20 ether); // the schedule cap out of the way: this exercises the vault's own ceiling
        accrueFees(40 ether);
        FundingVault.BidParams memory p = sys.vault.bidParams();
        p.slowSweepWei = 0;
        govern(address(sys.vault), abi.encodeCall(FundingVault.setBidParams, (p)));
        assertEq(riseBidTo(100 ether), 7.2 ether, "a hard stop at the ceiling");
        _wait();
        vm.expectRevert(FundingVault.NothingToSend.selector);
        sys.vault.sweep();
        p.ceilingBps = 0;
        govern(address(sys.vault), abi.encodeCall(FundingVault.setBidParams, (p)));
        assertEq(sys.vault.bidCeiling(), type(uint256).max, "no ceiling");
        sys.vault.sweep();
        assertEq(sys.vault.liveBid(), 7.2 ether + SWEEP, "the normal meter again");
        p.ceilingBps = 9_999; // below the last price
        vm.prank(owner);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.vault.setBidParams(p);
        p.ceilingBps = 15_000;
        p.slowSweepWei = p.maxSweepWei + 1; // faster above the ceiling than below
        vm.prank(owner);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.vault.setBidParams(p);
    }

    /// Every bid parameter is the owner's and takes effect at once; `maxPrice` caps the bid and every acquisition.
    function test_ownerSetsEveryBidParameter() public {
        accrueFees(40 ether);
        FundingVault.BidParams memory p = sys.vault.bidParams();
        p.maxSweepWei = 0.2 ether;
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Governed.NotOwner.selector);
        sys.vault.setBidParams(p);
        govern(address(sys.vault), abi.encodeCall(FundingVault.setBidParams, (p)));
        sys.vault.sweep();
        uint256 b = sys.vault.liveBid();
        sys.vault.sweep();
        assertEq(sys.vault.liveBid(), b + 0.2 ether, "a larger step");
        // the threshold can be corrected; the next acquisition re-syncs it
        govern(address(sys.vault), abi.encodeCall(FundingVault.setActivationThreshold, (7 ether)));
        sys.vault.sweep();
        assertEq(sys.vault.liveBid(), 7 ether, "fills to the corrected threshold (below the 120% ceiling)");
        p.maxPrice = 6.5 ether;
        govern(address(sys.vault), abi.encodeCall(FundingVault.setBidParams, (p)));
        assertEq(sys.vault.liveBid(), 6.5 ether, "capped by maxPrice");
        p.minBlocksBetweenSweeps = 0;
        vm.prank(owner);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.vault.setBidParams(p);
        // a token can be refused (e.g. stolen)
        uint256 id = nextCheckId();
        govern(address(sys.vault), abi.encodeCall(FundingVault.setExcluded, (id, true)));
        address holder = IERC721Lite(cfg.collection).ownerOf(id);
        vm.startPrank(holder);
        IERC721Lite(cfg.collection).setApprovalForAll(address(sys.vault), true);
        vm.expectRevert(FundingVault.NotEligible.selector);
        sys.vault.sellToProtocol(id, 1 ether);
        vm.stopPrank();
    }
}

/// @notice D64/D65: trading fees overflow to buybacks only when the vault holds more than the bid can use: the bid is
///         full and one more Ape at the last price is kept beyond it.
contract FlowForkTest is ForkBase {
    /// The overflow is off at launch (D72); these tests exercise it at the 50% an owner may set.
    function setUp() public {
        deployChecksAt(6 ether);
        launchGame(6 ether);
        assertEq(sys.vault.overflowBps(), 0, "off at launch (D72)");
        govern(address(sys.vault), abi.encodeCall(FundingVault.setOverflowBps, (5_000)));
        vm.roll(vm.getBlockNumber() + 300);
    }

    /// @dev What the vault may spend beyond its bid and the next Ape.
    function _excess() internal view returns (uint256) {
        uint256 budget = sys.vault.acquisitionBudget();
        uint256 bid = sys.vault.bidBalance();
        uint256 keep = (bid < budget ? bid : budget) + sys.vault.lastPrice();
        return budget > keep ? budget - keep : 0;
    }

    /// While the bid is filling, or the vault holds no more than the bid and the next Ape, every fee stays as capital.
    function test_noOverflowWhileTheBidCanUseTheEth() public {
        accrueFees(8 ether);
        assertLt(sys.vault.liveBid(), sys.vault.activationThreshold());
        assertEq(sys.vault.pendingOverflow(), 0, "the bid is not full yet");
        sys.vault.sweep(); // the bid fills to its threshold; the counted fees become capital
        assertEq(sys.vault.liveBid(), sys.vault.activationThreshold());
        assertEq(sys.vault.unsplitFees(), 0);
        accrueFees(2 ether);
        assertEq(_excess(), 0, "less than the next Ape beyond the bid");
        assertEq(sys.vault.pendingOverflow(), 0);
        uint256 burner0 = address(sys.burner).balance;
        vm.roll(vm.getBlockNumber() + 300);
        sys.vault.sweep();
        assertEq(address(sys.burner).balance, burner0);
        assertEq(sys.vault.unsplitFees(), 0, "counted fees become capital at the sweep");
    }

    /// With the bid full and more than the next Ape beyond it, half of the fees since the last sweep go to the burner's
    /// ongoing buybacks at the next sweep, capped so the vault keeps the game's capital, its growth, the bid's ETH and
    /// one more Ape at the last price.
    function test_feesOverflowBeyondTheNextApe() public {
        accrueFees(30 ether);
        sys.vault.sweep(); // the bid at its threshold
        accrueFees(4 ether);
        assertEq(sys.vault.unsplitFees(), 4 ether);
        assertGt(_excess(), 2 ether);
        assertEq(sys.vault.pendingOverflow(), 2 ether, "50% of the fees");
        uint256 ongoing0 = sys.burner.ongoingBalance();
        vm.roll(vm.getBlockNumber() + 300);
        sys.vault.sweep();
        assertEq(sys.burner.ongoingBalance() - ongoing0, 2 ether, "to ongoing buybacks");
        assertEq(sys.vault.overflowOut(), 2 ether);
        assertEq(sys.vault.unsplitFees(), 0);
        assertGe(sys.vault.liveBid(), sys.vault.activationThreshold(), "the bid keeps its ETH");
        assertGe(sys.vault.acquisitionBudget(), sys.vault.bidBalance() + sys.vault.lastPrice(), "the next Ape kept");
        // a sweep that only overflows (the cooldown not yet over) still runs
        accrueFees(1 ether);
        sys.vault.sweep();
        assertEq(sys.vault.overflowOut(), 2.5 ether);
    }

    /// The overflow is capped at what lies beyond the bid and the next Ape: with 1 ETH beyond them, 1 ETH goes even
    /// when half of the new fees is more.
    function test_overflowStopsAtTheNextApe() public {
        accrueFees(8 ether);
        sys.vault.sweep(); // the bid at its threshold, less than the next Ape beyond it
        uint256 keep = sys.vault.bidBalance() + sys.vault.lastPrice();
        uint256 short = keep - sys.vault.acquisitionBudget();
        accrueFees(short + 1 ether);
        assertEq(_excess(), 1 ether);
        assertGt((short + 1 ether) / 2, 1 ether);
        assertEq(sys.vault.pendingOverflow(), 1 ether, "capped at the excess");
        vm.roll(vm.getBlockNumber() + 300);
        sys.vault.sweep();
        assertEq(sys.vault.overflowOut(), 1 ether);
        assertGe(sys.vault.acquisitionBudget(), sys.vault.lastPrice() + sys.vault.bidBalance() - cfg.bid.maxSweepWei - 0.01 ether,
            "the next Ape kept (less the metered step forwarded into the bid and its reward)");
    }

    /// Before the game is active nothing overflows, however much the opening hour brings: that ETH is the first Ape's
    /// and the game's capital.
    function test_noOverflowBeforeActivation() public {
        FundingVault v = new FundingVault(owner, cfg.poolManager, cfg.collection, address(0), address(sys.burner), address(0),
            sys.vault.bidParams(), 5_000, 6 ether, 10_000);
        v.wire(address(sys.game), address(sys.poolOwner), address(0));
        // the game before activation, no Ape held yet (the vault may then spend everything on the first one)
        vm.mockCall(address(sys.game), abi.encodeWithSignature("activated()"), abi.encode(false));
        vm.mockCall(address(sys.poolOwner), abi.encodeWithSignature("heldCount()"), abi.encode(uint256(0)));
        vm.deal(cfg.poolManager, 40 ether);
        vm.prank(cfg.poolManager);
        (bool ok,) = address(v).call{value: 40 ether}("");
        require(ok);
        v.sweep(); // the bid at its threshold, 34 ETH beyond it
        vm.deal(cfg.poolManager, 4 ether);
        vm.prank(cfg.poolManager);
        (ok,) = address(v).call{value: 4 ether}("");
        require(ok);
        assertEq(v.liveBid(), 6 ether);
        assertEq(v.pendingOverflow(), 0, "not before activation");
        vm.clearMockedCalls();
        assertEq(v.pendingOverflow(), 2 ether, "the same vault once the game is active");
    }

    /// The owner sets the share (0 turns it off; at most 100%).
    function test_overflowShareIsTheOwners() public {
        govern(address(sys.vault), abi.encodeCall(FundingVault.setOverflowBps, (0)));
        assertEq(sys.vault.overflowBps(), 0);
        accrueFees(30 ether);
        sys.vault.sweep();
        accrueFees(4 ether);
        assertEq(sys.vault.pendingOverflow(), 0, "off");
        vm.prank(owner);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.vault.setOverflowBps(10_001);
        vm.expectRevert(Governed.NotOwner.selector);
        sys.vault.setOverflowBps(5_000);
        govern(address(sys.vault), abi.encodeCall(FundingVault.setOverflowBps, (10_000)));
        assertEq(sys.vault.overflowBps(), 10_000);
        assertEq(sys.vault.pendingOverflow(), 4 ether, "all of it");
    }
}

/// @dev Gas of a sweep that splits the fee overflow (DrawRouter gives `sweep` a fixed budget).
contract FlowGasForkTest is ForkBase {
    function test_overflowSweepGas() public {
        deployChecksAt(6 ether);
        launchGame(6 ether);
        govern(address(sys.vault), abi.encodeCall(FundingVault.setOverflowBps, (5_000)));
        vm.roll(vm.getBlockNumber() + 300);
        accrueFees(30 ether);
        sys.vault.sweep();
        vm.roll(vm.getBlockNumber() + 300);
        uint256 g = gasleft();
        sys.vault.sweep();
        emit log_named_uint("sweep: a metered step, nothing to split", g - gasleft());
        accrueFees(4 ether);
        vm.roll(vm.getBlockNumber() + 300);
        g = gasleft();
        sys.vault.sweep();
        emit log_named_uint("sweep with overflow and a metered step", g - gasleft());
        assertGt(sys.vault.overflowOut(), 0);
    }
}
