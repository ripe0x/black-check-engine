// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SystemBase} from "./SystemBase.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {IChecksOriginals} from "../../src/interfaces/IChecks.sol";
import {Engine, IShapesBacking} from "../../src/core/Engine.sol";

/// @dev Test-only seller that tries to re-enter the engine when it is paid.
contract ReentrantSeller {
    Engine internal immutable engine;
    IChecksOriginals internal immutable checks;
    uint256 internal second;

    constructor(Engine e, IChecksOriginals c) {
        engine = e;
        checks = c;
    }

    function sell(uint256 a, uint256 b) external {
        second = b;
        checks.setApprovalForAll(address(engine), true);
        engine.sellCheck(a);
    }

    receive() external payable {
        engine.sellCheck(second);
    }
}

/// @notice Phase 4 lifecycle on the real FWA pool, Checks, Editions and Shapes: decay repricing, composition paid with
///         a coin burn or free after the grace period, ETH and coin buyouts, the standing bid, Shape restocking.
contract MarketTest is SystemBase {
    uint256[] internal checkIds;
    uint256[] internal shapeIds;

    function setUp() public override {
        super.setUp();
        checkIds = _takeEighties(2);
        shapeIds = _mintShapes(30);
        engine.listChecks(checkIds);
        engine.listShapes(shapeIds);
    }

    function _price(uint256 tokenId) internal view returns (uint256 p) {
        (,, p) = engine.checkListing(tokenId);
        (,,,,, uint256 fwaPrice,,) = pool.listings(_checkListing(tokenId));
        assertEq(p, fwaPrice, "engine record matches FWA");
    }

    uint256 internal nextShape;

    /// @dev `n` draws, each won by the next unused Shape.
    function _drawShapes(uint256 n) internal {
        for (uint256 i; i < n; ++i) _drawSelecting(pool, _shapeListing(shapeIds[nextShape++]));
    }

    // ------------------------------------------------------------------ decay

    function test_decayRepricesByRuleToTheFloor() public {
        uint256 start = _price(checkIds[0]);
        assertEq(start, 1 ether);
        _drawShapes(10); // 10 survived draws x 0.2% = 2% < 5% step: no reprice yet
        engine.reprice(checkIds);
        assertEq(_price(checkIds[0]), 1 ether);
        _drawShapes(15); // 25 survived: 5% drop, one step
        assertEq(engine.currentNotional(checkIds[0]), 0.95 ether);
        engine.reprice(checkIds);
        assertEq(_price(checkIds[0]), 0.95 ether);

        uint256 pending = _pullAt(pool);
        vm.expectRevert(Engine.QueueBusy.selector);
        engine.reprice(checkIds);
        vm.roll(vm.getBlockNumber() + 31);
        pool.processAcquisitions(10);
        (,,,, IFWAPool.AcquisitionStatus st) = pool.acquisitions(pending);
        assertEq(uint8(st), uint8(IFWAPool.AcquisitionStatus.Expired));

        // A schedule raise through the timelock moves the price up, keeping the decay already earned (25 draws).
        uint256[8] memory t = _tiers();
        t[0] = 2 ether;
        _govern(address(engine), abi.encodeCall(Engine.setSchedule, (t, _thresholds(), _composeBurn(), _coinPrice())));
        engine.reprice(checkIds);
        assertEq(_price(checkIds[0]), 1.9 ether);
    }

    function test_decayStopsAtFloor() public {
        Engine.Params memory p = _params();
        p.decayBpsPerDraw = 100; // 1% per draw: 15 draws reach the 85% floor
        _govern(address(engine), abi.encodeCall(Engine.setParams, (p)));
        _drawShapes(20);
        engine.reprice(checkIds);
        assertEq(_price(checkIds[0]), 0.85 ether);
        // Operator and keepers cannot set prices or parameters.
        vm.prank(operator);
        vm.expectRevert(Engine.NotTimelock.selector);
        engine.setParams(p);
    }

    // ------------------------------------------------------------------ composition

    function test_manualComposeBurnsOnceFallbackIsFree() public {
        vm.expectRevert(Engine.NotEligible.selector);
        engine.composeCost(checkIds[1], checkIds[0], true); // no draws survived yet
        _drawShapes(2); // threshold reached, grace (3 more) not
        uint256 supply = coin.totalSupply();
        assertEq(engine.composeCost(checkIds[1], checkIds[0], true), 100 ether);
        // A swapped (artistic) choice burns composeBurn[0] once.
        engine.compose(checkIds[1], checkIds[0], true);
        assertEq(supply - coin.totalSupply(), 100 ether);

        // A failed attempt burns nothing: the burned input no longer exists.
        supply = coin.totalSupply();
        vm.expectRevert();
        engine.compose(checkIds[1], checkIds[0], false);
        assertEq(coin.totalSupply(), supply);

        // Fallback: two new 80s past threshold + grace, deterministic survivor, no swap: free for anyone.
        uint256[] memory more = _takeEighties(2);
        engine.listChecks(more);
        for (uint256 i = 2; i < 7; ++i) _drawSelecting(pool, _shapeListing(shapeIds[i]));
        address nobody = makeAddr("nobody");
        uint256 keep = more[0] < more[1] ? more[0] : more[1];
        uint256 other = keep == more[0] ? more[1] : more[0];
        assertEq(engine.composeCost(keep, other, false), 0, "view agrees: free fallback");
        assertEq(engine.composeCost(other, keep, false), 100 ether, "the other survivor pays");
        vm.prank(nobody);
        engine.compose(keep, other, false);
        assertEq(coin.totalSupply(), supply, "free fallback");
        assertEq(CHECKS.getCheck(keep).stored.divisorIndex, 1);
        // The non-deterministic survivor still pays, even after the grace.
        assertFalse(engine.eligible(other));
    }

    // ------------------------------------------------------------------ buyouts

    function test_ethBuyoutAtPublishedPrice() public {
        uint256 price = engine.ethPrice(0);
        assertEq(price, 1.2 ether);
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 10 ether);

        vm.prank(buyer);
        vm.expectRevert(Engine.WrongPayment.selector);
        engine.buyWithEth{value: price - 1}(checkIds[0]);

        uint256 pending = _pullAt(pool);
        vm.prank(buyer);
        vm.expectRevert(Engine.QueueBusy.selector);
        engine.buyWithEth{value: price}(checkIds[0]);
        vm.roll(vm.getBlockNumber() + 3);
        deliverWord(pending, _wordFor(pool, _shapeListing(shapeIds[nextShape++])));
        pool.processAcquisitions(10);

        vm.prank(operator);
        engine.halt();
        vm.prank(buyer);
        vm.expectRevert(Engine.Halt.selector);
        engine.buyWithEth{value: price}(checkIds[0]);
        vm.prank(guardian);
        engine.resume();

        uint256 budget = engine.acquisitionBudget();
        vm.prank(buyer);
        engine.buyWithEth{value: price}(checkIds[0]);
        assertEq(CHECKS.ownerOf(checkIds[0]), buyer);
        assertEq(engine.acquisitionBudget() - budget, price, "sale proceeds fund acquisitions");
        assertEq(engine.survivedDraws(checkIds[0]), 0);
    }

    function test_cannotBuyWhatAPlayerWon() public {
        _drawSelecting(pool, _checkListing(checkIds[0]));
        assertEq(CHECKS.ownerOf(checkIds[0]), player);
        vm.deal(address(this), 2 ether);
        vm.expectRevert(Engine.NotListed.selector);
        engine.buyWithEth{value: 1.2 ether}(checkIds[0]);
    }

    function test_coinBuyoutBurnsExactly() public {
        uint256 supply = coin.totalSupply();
        engine.buyWithCoin(checkIds[0]);
        assertEq(supply - coin.totalSupply(), _coinPrice()[0]);
        assertEq(CHECKS.ownerOf(checkIds[0]), address(this));
        // Black has no coin price: disabled.
        uint256[8] memory c = _coinPrice();
        assertEq(c[7], 0);
    }

    // ------------------------------------------------------------------ acquisitions

    function test_standingBidBuysRealChecksWithinBudgetAndCap() public {
        uint256[] memory forSale = _takeEighties(13); // moved into the engine by the setup helper...
        address seller = makeAddr("seller");
        vm.startPrank(address(engine)); // ...so hand them to a seller first (setup only)
        for (uint256 i; i < forSale.length; ++i) CHECKS.transferFrom(address(engine), seller, forSale[i]);
        vm.stopPrank();
        vm.prank(seller);
        CHECKS.setApprovalForAll(address(engine), true);

        vm.prank(seller);
        vm.expectRevert(Engine.BudgetExceeded.selector);
        engine.sellCheck(forSale[0]);

        vm.deal(address(this), 20 ether);
        engine.fundAcquisitions{value: 20 ether}();
        uint256 bid = 0.9 ether; // 1 ETH schedule x 90%
        for (uint256 i; i < 11; ++i) {
            vm.prank(seller);
            engine.sellCheck(forSale[i]);
        }
        assertEq(seller.balance, 11 * bid);
        assertEq(engine.acquisitionBudget(), 20 ether - 11 * bid);
        // The weekly cap (10 ETH) stops the 12th sale until next week.
        vm.prank(seller);
        vm.expectRevert(Engine.BudgetExceeded.selector);
        engine.sellCheck(forSale[11]);
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        vm.prank(seller);
        engine.sellCheck(forSale[11]);
        assertEq(CHECKS.ownerOf(forSale[11]), address(engine));

        // Bought Checks are listable like any custody Check.
        uint256[] memory one = new uint256[](1);
        one[0] = forSale[0];
        engine.listChecks(one);
        assertEq(CHECKS.ownerOf(forSale[0]), address(pool));
    }

    function test_standingBidMigratesARealEdition() public {
        vm.deal(address(this), 5 ether);
        engine.fundAcquisitions{value: 5 ether}();
        uint256 id;
        address holder;
        for (id = 1; id <= 16_031; ++id) {
            try EDITIONS.ownerOf(id) returns (address h) {
                holder = h;
                break;
            } catch {}
        }
        vm.prank(holder);
        EDITIONS.setApprovalForAll(address(engine), true);
        uint256 before = holder.balance;
        vm.prank(holder);
        engine.sellEdition(id);
        assertEq(holder.balance - before, 0.9 ether);
        assertEq(CHECKS.ownerOf(id), address(engine));

        uint256[] memory one = new uint256[](1);
        one[0] = id;
        vm.expectRevert(Engine.NotRevealed.selector);
        engine.listChecks(one);
        IChecksOriginals.Epoch memory e = CHECKS.getEpochData(CHECKS.getCheck(id).stored.epoch);
        vm.roll(e.revealBlock + 1);
        CHECKS.resolveEpochIfNecessary();
        engine.listChecks(one);
        assertEq(CHECKS.ownerOf(id), address(pool));
    }

    function test_bidPaymentCannotReenter() public {
        vm.deal(address(this), 5 ether);
        engine.fundAcquisitions{value: 5 ether}();
        uint256[] memory two = _takeEighties(2);
        ReentrantSeller bad = new ReentrantSeller(engine, CHECKS);
        vm.startPrank(address(engine));
        CHECKS.transferFrom(address(engine), address(bad), two[0]);
        CHECKS.transferFrom(address(engine), address(bad), two[1]);
        vm.stopPrank();
        vm.expectRevert(Engine.PayFailed.selector); // the nested sale reverted with Reentrancy
        bad.sell(two[0], two[1]);
    }

    // ------------------------------------------------------------------ Shapes

    function test_restockReplacesWonShapesFromGameCapital() public {
        _drawSelecting(pool, _shapeListing(shapeIds[0]));
        engine.collect(address(controller));
        vm.deal(address(engine), address(engine).balance + 1 ether); // game capital (e.g. accumulated proceeds)
        uint256 budget = engine.acquisitionBudget();
        uint256 active = pool.activeListingCount();

        uint256[] memory won = new uint256[](1);
        won[0] = shapeIds[0];
        engine.restockShapes(won);
        assertEq(pool.activeListingCount(), active + 1);
        assertEq(engine.acquisitionBudget(), budget, "acquisition money untouched");
        vm.expectRevert(Engine.NotListed.selector);
        engine.restockShapes(won); // only once per won Shape
        won[0] = shapeIds[1];
        vm.expectRevert(Engine.AlreadyListed.selector);
        engine.restockShapes(won); // still in the draw
    }
}
