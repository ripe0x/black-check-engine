// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase, IERC721Lite} from "../fork/ForkBase.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {CollectionGame} from "../../src/game/CollectionGame.sol";

/// @notice Long scenarios on the fork: zero trading after launch, weak fee funding, elevated gas, the game closing
///         when its last collection NFT is won and reopening when funding returns, buybacks throughout.
contract LongRunScenarioTest is ForkBase {
    address alice = makeAddr("cg.player.alice");
    address bob = makeAddr("cg.player.bob");

    function setUp() public {
        deployBayc();
        launchGame(6 ether);
    }

    /// Zero subsequent trading: the game runs on its own capital and margin; distributions flow; when the only Ape is
    /// won the game closes, stays solvent with every right intact, and reopens when funding (here a contribution) buys
    /// the next Ape.
    function test_zeroTradingThenWinThenRecovery() public {
        uint256 feesBefore = sys.vault.tradingFees();
        playMany(alice, 250, 31);
        assertEq(sys.vault.tradingFees(), feesBefore, "no trading");
        assertGt(sys.game.distributed(), 0, "margin distributed without any trading");
        assertGt(sys.vault.surplusIn(), 0, "the vault's surplus share accumulating from margin");
        // at launch all of it waits in the milestone reserve for an Ape win (D74): nothing to buy back yet
        assertGt(sys.burner.reserve(), 0, "the game's surplus locked in the reserve");
        assertEq(sys.burner.totalBurned(), 0, "no buyback before an Ape win");
        assertBooks();
        // the Ape is won (by now it may already have been, as its odds rose with play): no replacement funded, and the
        // draw stays open for Shapes and Packs (D53)
        if (sys.game.collectionWins() == 0) {
            uint256 r = pull(alice);
            vm.roll(block.number + 3);
            deliverWord(r, wordFor(type(uint256).max));
            pool.processAcquisitions(10);
            vm.prank(keeper);
            sys.game.sync();
        }
        assertEq(sys.game.collectionWins(), 1);
        assertEq(sys.burner.releases(), 1, "milestone released on the win");
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 1);
        vm.prank(keeper);
        sys.burner.process(0);
        assertGt(sys.burner.totalBurned(), 0, "buybacks without trading, once the win released the reserve");
        assertFalse(sys.poolOwner.collectionAvailable(), "no Ape in the draw");
        assertTrue(pool.localPurchasesEnabled(), "open for Shapes and Packs");
        // Ape-less draws still earn margin toward the next Ape
        uint256 contBefore = sys.vault.surplusIn();
        playMany(bob, 60, 33);
        assertEq(sys.game.collectionWins(), 1, "nothing else to win");
        assertGe(sys.vault.surplusIn(), contBefore, "the vault's share keeps accumulating");
        assertBooks();
        // a long quiet period: nothing decays, nothing is lost, keepers cannot drain anything
        uint256 cash = sys.game.cash();
        vm.warp(block.timestamp + 60 days);
        vm.prank(keeper);
        try sys.game.sync() {} catch {}
        assertEq(sys.game.cash(), cash);
        assertBooks();
        // funding returns: the vault's surplus share plus a contribution buy the next Ape at the bid; purchases reopen
        uint256 budget = sys.vault.acquisitionBudget();
        if (budget < 6 ether) {
            address donor = makeAddr("cg.donor");
            vm.deal(donor, 6 ether - budget);
            vm.prank(donor);
            sys.vault.contribute{value: 6 ether - budget}();
        }
        riseBidTo(6 ether); // the bid climbs back from its restart price as it is recorded
        sellApe(nextApeId());
        assertGt(sys.vault.surplusIn(), 0, "game surplus paid for part of it");
        vm.prank(keeper);
        sys.game.sync();
        assertTrue(sys.poolOwner.collectionAvailable(), "the next Ape is in the draw");
        assertTrue(pool.localPurchasesEnabled());
        playMany(bob, 20, 32);
        assertBooks();
    }

    /// Weak fee funding: trading fees trickle in at a tenth of gameplay; the game keeps its reserve and distributes only
    /// realised surplus.
    function test_weakFeeFundingSustainedPlay() public {
        int256 maxProfit;
        uint256 paidBefore = sys.game.keeperPaid();
        for (uint256 round; round < 6; ++round) {
            for (uint256 i; i < 4; ++i) {
                playMany(alice, 10, 40 + round * 10 + i);
                if (sys.game.profit() > maxProfit) maxProfit = sys.game.profit();
            }
            accrueFees(sys.game.turnover() / 100); // a trickle
            assertBooks(); // includes: nothing distributable while a loss is carried
        }
        assertGt(sys.game.pullsFulfilled(), 200);
        // distributions never exceeded the realised profit at the time; later expensive wins can put cumulative profit
        // below what was distributed, and then distributions wait until it recovers. A sync distributes before it pays
        // its keeper, so profit sampled after the call can sit below the distribution by that pay
        assertLe(int256(sys.game.distributed()), maxProfit + int256(sys.game.keeperPaid() - paidBefore) + 1);
        emit log_named_int("profit - distributed (carried)", sys.game.profit() - int256(sys.game.distributed()));
    }

    /// Elevated gas: at 60 gwei the player's VRF fee is large and keepers are reimbursed only at the 3 gwei
    /// `maxGasPrice` (plus the flat fee). Settlement and booking still work for whoever calls; the game's accounting
    /// is unaffected.
    function test_elevatedGas() public {
        vm.fee(60 gwei);
        vm.txGasPrice(60 gwei);
        (, uint256 vrf,) = pool.quoteAcquisitionPrice(1);
        emit log_named_decimal_uint("VRF fee at 60 gwei", vrf, 18);
        assertEq(vrf, 1_500_000 * 60 gwei * 13_000 / 10_000);
        uint256 r = pull(alice);
        vm.roll(block.number + 3);
        deliverWord(r, 123);
        pool.processAcquisitions(10);
        uint256 balBefore = keeper.balance;
        uint256 g = gasleft();
        vm.prank(keeper);
        sys.game.sync();
        uint256 used = g - gasleft();
        assertLe(keeper.balance - balBefore, (used + 70_000) * 3 gwei + 0.0003 ether, "reimbursed at the 3 gwei cap");
        assertGt(keeper.balance - balBefore, 0, "but not refused");
        assertEq(sys.game.pullsFulfilled(), 1);
        assertBooks();
    }
}
