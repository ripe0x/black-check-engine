// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {CollectionGame} from "../../src/game/CollectionGame.sol";
import {Governed} from "../../src/core/Governed.sol";

/// @notice What a keeper is actually paid with the launch parameters (D63: the game pays each useful call its measured
///         gas at the transaction's gas price, capped at 3 gwei per gas, plus a flat fee, within the allowance
///         earned from captures and never out of cash owed to replacements), against what the call costs it.
contract KeeperPayForkTest is ForkBase {
    address alice = makeAddr("cg.player.alice");
    uint256 constant FLAT = 0.0002 ether; // the launch flat fee (D79)

    function setUp() public virtual {
        deployChecks();
        launchGame(0.25 ether);
    }

    function _syncPaid(uint256 basefee, uint256 priority) internal returns (uint256 tipPaid, uint256 gasUsed) {
        vm.fee(basefee);
        vm.txGasPrice(basefee + priority);
        uint256 before = keeper.balance;
        uint256 g = gasleft();
        vm.prank(keeper);
        sys.game.sync();
        gasUsed = g - gasleft();
        tipPaid = keeper.balance - before;
    }

    /// @dev The game measures its gas before refunds; depending on the Foundry version, the outer `gasleft()` reading
    ///      can come out after them. Refunds are at most a fifth of the gas used (EIP-3529), so the gas before them is at
    ///      most 5/4 of the reading.
    function _beforeRefunds(uint256 gasUsed) internal pure returns (uint256) {
        return gasUsed * 5 / 4;
    }

    function _play(uint256 n, uint256 seed) internal {
        for (uint256 i; i < n; ++i) {
            pullAndSettle(alice, uint256(keccak256(abi.encode(seed, i))));
        }
        window();
    }

    /// `upkeep` does `sync`'s work and pays nobody (D77): the same booking and replacements, no keeper allowance spent,
    /// the caller's balance untouched; with nothing to do it returns 0 instead of reverting.
    function test_upkeepDoesTheWorkUnpaid() public {
        _play(10, 1);
        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei);
        // what `sync` does from this state
        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        sys.game.sync();
        (uint256 seenSync, uint256 liveSync) = (sys.game.seenSeq(), sys.game.liveCount());
        vm.revertToState(snap);
        // `upkeep` from the same state
        uint256 seen = sys.game.seenSeq();
        uint256 paid = sys.game.keeperPaid();
        uint256 available = sys.game.keeperAvailable();
        uint256 before = alice.balance;
        vm.prank(alice); // anyone may call it: here a player, not a keeper
        uint256 work = sys.game.upkeep(40);
        assertGt(work, 0, "it did the work");
        assertGt(sys.game.seenSeq(), seen, "booked the settled draws");
        assertEq(sys.game.seenSeq(), seenSync, "the same booking as sync");
        assertEq(sys.game.liveCount(), liveSync, "the same listings as sync");
        assertEq(sys.game.keeperPaid(), paid, "no keeper allowance spent");
        assertEq(alice.balance, before, "nobody paid");
        // calling it again changes nothing in the allowance either
        vm.prank(alice);
        sys.game.upkeep(40);
        assertGe(sys.game.keeperAvailable(), available, "the allowance only grows (captures booked), never spent");
    }

    /// Where `sync` reverts `NoWork`, `upkeep` returns 0: a player's draw never fails on it (the router tries it anyway).
    function test_upkeepWithNothingToDo() public {
        _play(2, 7);
        _syncPaid(0.1 gwei, 0);
        vm.prank(keeper);
        assertEq(sys.game.upkeep(40), 0);
    }

    /// At 1 gwei a call that books and replaces ten draws is paid its gas at what it cost, plus the flat fee.
    function test_tenDrawCallPaidAtOneGwei() public {
        _play(10, 1);
        uint256 paidBefore = sys.game.keeperPaid();
        (uint256 tipPaid, uint256 gasUsed) = _syncPaid(1 gwei, 0.02 gwei);
        assertGe(sys.game.liveCount() + 2, sys.game.boardSize(), "a batch replaced; the rest at the next window");
        assertGe(tipPaid, (gasUsed + 21_000) * 1.02 gwei + FLAT, "the keeper's gas, priority included, and the flat fee");
        assertLe(tipPaid, (_beforeRefunds(gasUsed) + 70_000) * 1.02 gwei + FLAT, "no more than gas + overhead + the flat fee");
        assertEq(sys.game.keeperPaid() - paidBefore, tipPaid, "booked as keeper pay");
        assertBooks();
        emit log_named_uint("gas", gasUsed);
        emit log_named_uint("tip", tipPaid);
    }

    /// A call that books twenty draws and lists a full batch of replacements is paid in full: no cap on the gas.
    function test_fullBatchCallPaidInFull() public {
        _play(20, 3);
        (uint256 tipPaid, uint256 gasUsed) = _syncPaid(1 gwei, 0);
        assertGt(gasUsed, 5_000_000);
        assertGe(tipPaid, (gasUsed + 21_000) * 1 gwei, "covered");
        assertLe(tipPaid, (_beforeRefunds(gasUsed) + 70_000) * 1 gwei + FLAT);
    }

    /// D79: heavy work (a full listing batch, more than a player's draw takes on) is paid even while players are
    /// drawing; only light work is left to them.
    function test_heavySyncPaidWhilePlayersDraw() public {
        _play(20, 3);
        // a player's upkeep did work just now (`lastUpkeepAt`, packed after `seenSeq` in slot 26: `forge inspect
        // CollectionGame storageLayout`; the assertion below fails if the layout moves)
        bytes32 slot = bytes32(uint256(26));
        uint256 word = uint256(vm.load(address(sys.game), slot));
        vm.store(address(sys.game), slot, bytes32((word & type(uint64).max) | (vm.getBlockTimestamp() << 64)));
        assertEq(sys.game.lastUpkeepAt(), vm.getBlockTimestamp());
        (uint256 tipPaid, uint256 gasUsed) = _syncPaid(1 gwei, 0);
        assertGt(gasUsed, sys.game.PLAYER_UPKEEP_GAS());
        assertGt(tipPaid, 0, "heavy work paid");
    }

    /// Above `maxGasPrice` (3 gwei at launch) the gas is still reimbursed, at 3 gwei per gas: never refused.
    function test_aboveTheCapReimbursedAtTheCap() public {
        _play(10, 6);
        (uint256 tipPaid, uint256 gasUsed) = _syncPaid(5 gwei, 0.1 gwei);
        assertGe(tipPaid, (gasUsed + 21_000) * 3 gwei, "reimbursed at the cap");
        assertLe(tipPaid, (_beforeRefunds(gasUsed) + 70_000) * 3 gwei + FLAT, "not above it");
    }

    /// At today's low basefee (0.1 gwei) the priority fee is a large share of the keeper's cost: the reimbursement is
    /// at the transaction's gas price, priority included.
    function test_lowBasefeePriorityReimbursed() public {
        _play(10, 4);
        (uint256 tipPaid, uint256 gasUsed) = _syncPaid(0.1 gwei, 0.02 gwei);
        assertGe(tipPaid, (gasUsed + 21_000) * 0.12 gwei, "gas and priority covered");
        assertLe(tipPaid, (_beforeRefunds(gasUsed) + 70_000) * 0.12 gwei + FLAT);
    }

    /// A call with no work is refused (`NoWork`) and earns nothing.
    function test_noWorkNoPay() public {
        _play(2, 7);
        _syncPaid(0.1 gwei, 0);
        vm.prank(keeper);
        vm.expectRevert(CollectionGame.NoWork.selector);
        sys.game.sync();
    }

    /// No gas limit makes a paid `sync` that skips its work: a step that runs out of gas, anywhere down its call chain,
    /// fails the whole call. Every limit from 20% to 98% of what the full call uses either reverts or does all of the work.
    function test_tooLittleGasNeverSkipsWork() public {
        _play(10, 8);
        vm.txGasPrice(1 gwei);
        uint256 snap = vm.snapshotState();
        uint256 g = gasleft();
        vm.prank(keeper);
        sys.game.sync();
        uint256 full = g - gasleft();
        uint256 live = sys.game.liveCount();
        uint256 paid = sys.game.keeperPaid();
        for (uint256 pct = 20; pct < 100; pct += 3) {
            vm.revertToState(snap);
            vm.prank(keeper);
            (bool ok,) = address(sys.game).call{gas: full * pct / 100}(abi.encodeCall(CollectionGame.sync, ()));
            if (ok) {
                assertEq(sys.game.liveCount(), live, "a call that succeeds lists the whole batch");
                assertEq(sys.game.keeperPaid(), paid, "and is paid as the full call");
            }
        }
    }

    /// The caller does not choose how much a paid call books (`bookPerCall`, the owner's): a backlog is booked in one
    /// call for one flat fee, so splitting it into many paid calls is not possible.
    function test_backlogBookedInOneCallOneFee() public {
        _play(8, 11);
        uint64 last = pool.lastIssuedSequence();
        (uint256 tipPaid, uint256 gasUsed) = _syncPaid(1 gwei, 0);
        assertGt(sys.game.seenSeq(), last, "every waiting draw booked in one call");
        assertGt(tipPaid, 0);
        assertLe(tipPaid, (_beforeRefunds(gasUsed) + 70_000) * 1 gwei + FLAT, "one flat fee");
        vm.prank(keeper);
        vm.expectRevert(CollectionGame.NoWork.selector);
        sys.game.sync();
    }

    /// The owner sets the gas-price cap, the overhead and the flat fee (at most 0.1 ETH).
    function test_keeperParamsAreTheOwners() public {
        CollectionGame.KeeperParams memory k = CollectionGame.KeeperParams(1 gwei, 50_000, 0.001 ether, 5 minutes);
        vm.prank(alice);
        vm.expectRevert(Governed.NotOwner.selector);
        sys.game.setKeeperParams(k);
        govern(address(sys.game), abi.encodeCall(CollectionGame.setKeeperParams, (k)));
        vm.txGasPrice(2 gwei);
        assertEq(sys.game.quoteTip(100_000), 150_000 * 1 gwei + 0.001 ether, "gas at the cap plus the flat fee");
        k.flatFee = 0.001 ether + 1; // D012: at most 0.001 ETH a call
        vm.prank(owner);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.game.setKeeperParams(k);
        k.flatFee = 0.001 ether;
        k.maxGasPrice = 30 gwei + 1; // D012: gas reimbursed at no more than 30 gwei
        vm.prank(owner);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.game.setKeeperParams(k);
        k.maxGasPrice = 30 gwei;
        k.gasOverhead = 200_001; // D012: at most 200,000 gas of overhead
        vm.prank(owner);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.game.setKeeperParams(k);
        k.gasOverhead = 50_000;
        // the delay after players' upkeep (D79): up to an hour, 0 turns it off
        k.payDelay = 1 hours + 1;
        vm.prank(owner);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.game.setKeeperParams(k);
        k.payDelay = 0;
        govern(address(sys.game), abi.encodeCall(CollectionGame.setKeeperParams, (k)));
        assertEq(sys.game.keeperParams().payDelay, 0);
    }
}

/// @notice With no opening allowance, keepers are paid only from the allowance captures earn (booked in the same call):
///         at most that, however much gas the call used.
contract KeeperAllowanceForkTest is ForkBase {
    address alice = makeAddr("cg.player.alice");

    function setUp() public {
        setUpFork();
        cfg = _testChecksConfig();
        cfg.openingAllowance = 0;
        _deploy();
        launchGame(0.25 ether);
    }

    function test_payNeverExceedsTheAllowance() public {
        assertEq(sys.game.keeperPaid(), 0, "listing the board earned nothing without an opening allowance");
        for (uint256 i; i < 10; ++i) {
            pullAndSettle(alice, uint256(keccak256(abi.encode(2, i))));
        }
        window();
        vm.fee(3 gwei);
        vm.txGasPrice(3 gwei);
        uint256 before = keeper.balance;
        uint256 g = gasleft();
        vm.prank(keeper);
        sys.game.sync();
        uint256 gasUsed = g - gasleft();
        uint256 tipPaid = keeper.balance - before;
        assertGt(sys.game.keeperAllowance(), 0, "the captures earned an allowance");
        assertGt(tipPaid, 0, "paid from it");
        assertLe(sys.game.keeperPaid(), sys.game.keeperAllowance(), "never more than earned");
        assertLt(tipPaid, sys.game.quoteTip(gasUsed), "capped below the full reimbursement");
        assertBooks();
        emit log_named_uint("gas", gasUsed);
        emit log_named_uint("tip", tipPaid);
        emit log_named_uint("allowance", sys.game.keeperAllowance());
    }
}
