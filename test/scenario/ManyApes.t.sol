// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CollectionPoolOwner} from "../../src/core/CollectionPoolOwner.sol";
import {ForkBase, IERC721Lite} from "../fork/ForkBase.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {IGameSync} from "../../src/periphery/DrawRouter.sol";

/// @notice 1, 20, 50 and 100 Apes on the real FWA pool (D59), with the ordinary boards the 15% target needs: every Ape
///         is listed from custody ten per maintenance call, the board grows on demand and its rows are listed twenty per
///         call, gameplay credited to the Apes is repriced ten per call, and draws, settlement, an Ape win and booking
///         keep working at the largest size. Every maintenance transaction is measured. Players draw the site's way
///         (D60) in steady play, with heavy maintenance pending and right after an Ape win: the upkeep is measured,
///         asked for only when light, and the draw never costs more than the purchase plus the measured upkeep. Writes
///         docs/receipts/many-apes-<k>.json.
/// @dev Gameplay credit is applied by the pool owner's own maintenance step called as the game at a high cumulative
///      turnover (the decay of 100 Apes to their minimum needs 4,500 ETH of settled gameplay, far beyond what a test can
///      play draw by draw); every listing, repricing and board change after it is made by ordinary keeper `sync`s.
contract ManyApesTest is ForkBase {
    address alice = makeAddr("cg.many.alice");
    /// @dev EIP-7825 (Fusaka) caps a transaction at 2^24 = 16,777,216 gas; a maintenance call must fit it with a 10% margin
    ///      (D61).
    uint256 constant TX_LIMIT = 15_099_494; // 16,777,216 x 90%

    function setUp() public {
        deployChecks();
        launchGame(0.25 ether);
    }

    function test_oneApe() public {
        _run(1);
    }

    function test_twentyApes() public {
        _run(20);
    }

    function test_fiftyApes() public {
        _run(50);
    }

    function test_hundredApes() public {
        _run(100);
    }

    /// @dev Keeper `sync`s, one per maintenance window, until there is nothing left to do (`NoWork`).
    function _maintain(uint256 maxCalls) internal returns (uint256 calls, uint256 maxGas) {
        for (uint256 i; i < maxCalls; ++i) {
            window();
            uint256 g = gasleft();
            vm.prank(keeper);
            try sys.game.sync() {}
            catch {
                break;
            }
            uint256 used = g - gasleft();
            if (used > maxGas) maxGas = used;
            ++calls;
        }
    }

    function _donate(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            uint256 tokenId = nextCheckId();
            address holder = IERC721Lite(cfg.collection).ownerOf(tokenId);
            vm.startPrank(holder);
            IERC721Lite(cfg.collection).setApprovalForAll(address(sys.vault), true);
            sys.vault.contributeNFT(tokenId);
            vm.stopPrank();
        }
    }

    struct Result {
        uint256 rowsFresh;
        uint256 rowsDecayed;
        uint256 exposureFresh;
        uint256 feeFresh;
        uint256 feeDecayed;
        uint256 callsList;
        uint256 callsDecay;
        uint256 callsWin;
        uint256 maxGas;
        uint256 gateGas;
        uint256 acquireGas;
        uint256 settleGas;
        uint256 siteDraws;
        uint256 upkeepDraws;
        uint256 maxDrawGas;
        uint256 maxUpkeepMeasured;
    }

    /// @dev A player's draw as the site makes it (D60): `measureUpkeep` simulated; the upkeep asked for only when it is
    ///      at most 2.5M gas, with a budget 30% above the measurement; then the draw, whose gas is checked against the
    ///      purchase plus the measured upkeep. The draw's randomness is delivered afterwards.
    function _siteDraw(Result memory x) internal {
        uint256 snap = vm.snapshotState();
        (bool ran, uint256 measured) = sys.drawRouter.measureUpkeep(IGameSync(address(sys.game)), 10);
        vm.revertToState(snap);
        bool include = ran && measured <= 2_500_000;
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        uint256 version = pool.inventoryVersion();
        vm.deal(alice, alice.balance + total);
        uint256 g = gasleft();
        vm.prank(alice);
        uint256[] memory ids = sys.drawRouter.draw{value: total}(
            pool,
            IGameSync(address(sys.game)),
            10,
            include ? 10 : 0,
            include ? measured * 13 / 10 + 50_000 : 0,
            1,
            fee,
            0,
            1_000,
            version,
            block.timestamp + 1 hours
        );
        uint256 used = g - gasleft();
        assertLe(used, 700_000 + (include ? measured : 0), "at most the purchase plus the measured upkeep");
        ++x.siteDraws;
        if (include) ++x.upkeepDraws;
        if (used > x.maxDrawGas) x.maxDrawGas = used;
        if (ran && measured > x.maxUpkeepMeasured) x.maxUpkeepMeasured = measured;
        emit log_named_uint(include ? "site draw with upkeep (gas)" : "site draw, upkeep left to keepers (gas)", used);
        emit log_named_uint("  upkeep measured (gas)", ran ? measured : 0);
        vm.roll(block.number + 3);
        deliverWord(ids[0], wordFor(0.01 ether));
        pool.processAcquisitions(10);
    }

    function _run(uint256 k) internal {
        Result memory x;
        _donate(k - 1);
        accrueFees(k * 1.2 ether + 5 ether); // the boards the Apes will need, funded by trading fees
        _listAll(k, x);
        _siteDraw(x); // steady play
        _siteDraw(x);
        _decayAll(k, x);
        _drawAndWin(k, x);
        playMany(alice, 30, k);
        assertBooks();
        assertLt(x.maxGas, TX_LIMIT, "every maintenance call fits the per-transaction gas cap");
        _report(k, x);
    }

    /// @dev 1. Every Ape listed at its price, the board grown for them.
    function _listAll(uint256 k, Result memory x) internal {
        uint256 gas;
        (x.callsList, gas) = _maintain(1_000);
        _max(x, gas);
        assertEq(sys.poolOwner.custodyCount(), 0, "every Ape listed");
        assertEq(sys.poolOwner.listedCount(), k);
        assertEq(sys.game.owedCount(), 0, "every row listed");
        assertEq(sys.game.liveCount(), sys.game.boardSize());
        assertLe(sys.poolOwner.exposureBps(), 2_000);
        x.rowsFresh = sys.game.boardSize();
        x.exposureFresh = sys.poolOwner.exposureBps();
        (x.feeFresh,,) = pool.quoteAcquisitionPrice(1);
    }

    /// @dev 2. Every Check decays to its floor (85% of its schedule, D005) and the board grows with it. The council
    ///      sets the decay to 100% a draw for the study, so one real draw that every Check survives takes all of them
    ///      to the floor at once: the heaviest repricing the Checks can need.
    function _decayAll(uint256 k, Result memory x) internal {
        CollectionPoolOwner.ListingParams memory lp = sys.poolOwner.listingParams();
        lp.decayBps = 10_000;
        vm.prank(council);
        sys.poolOwner.setListingParams(lp);
        uint256 r = pull(alice);
        vm.roll(block.number + 3);
        deliverWord(r, wordFor(0));
        pool.processAcquisitions(10);
        for (uint256 round; round < 60 && !_allAtMinimum(k); ++round) {
            if (round == 0) {
                window();
                _siteDraw(x); // repricing and board growth pending
            }
            (uint256 calls, uint256 gas) = _maintain(200);
            x.callsDecay += calls + 1;
            _max(x, gas);
        }
        for (uint256 i; i < k; ++i) {
            (, uint128 n,,,,) = sys.poolOwner.cListings(sys.poolOwner.listedAt(i));
            assertEq(n, _floor(), "at its floor");
        }
        assertEq(sys.game.owedCount(), 0);
        assertEq(sys.poolOwner.rowsShort(), 0);
        assertLe(sys.poolOwner.exposureBps(), 2_000);
        x.rowsDecayed = sys.game.boardSize();
        (x.feeDecayed,,) = pool.quoteAcquisitionPrice(1);
    }

    /// @dev 3. A player draws on the largest pool and wins an Ape; keepers book it.
    function _drawAndWin(uint256 k, Result memory x) internal {
        uint256 g = gasleft();
        bool open = sys.poolOwner.canPurchase(alice);
        x.gateGas = g - gasleft();
        assertTrue(open);
        assertLt(x.gateGas, 100_000, "within FWA's purchase-operator stipend");
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        uint256 version = pool.inventoryVersion();
        vm.deal(alice, total);
        g = gasleft();
        vm.prank(alice);
        uint256 r = pool.acquire{value: total}(alice, fee, 0, 10_000, version, block.timestamp + 1 hours);
        x.acquireGas = g - gasleft();
        vm.roll(block.number + 3);
        uint256 word = wordFor(type(uint256).max); // this draw wins an Ape
        g = gasleft();
        deliverWord(r, word); // FWA's VRF callback settles it on its fast path
        pool.processAcquisitions(10);
        x.settleGas = g - gasleft();
        (,,, uint256 listingId,) = pool.acquisitions(r);
        assertTrue(sys.poolOwner.isCollectionListing(listingId));
        window();
        _siteDraw(x); // the Ape win, its booking and the replacements pending
        uint256 gas;
        (x.callsWin, gas) = _maintain(50);
        _max(x, gas);
        assertEq(sys.game.collectionWins(), 1);
        assertEq(sys.poolOwner.wonCount(), 1);
        assertEq(sys.poolOwner.listedCount(), k - 1);
        _siteDraw(x); // steady again
        if (k > 1) assertGt(x.upkeepDraws, 0, "players did some of the upkeep");
    }

    function _allAtMinimum(uint256 k) internal view returns (bool) {
        for (uint256 i; i < k; ++i) {
            (, uint128 n,,,,) = sys.poolOwner.cListings(sys.poolOwner.listedAt(i));
            if (n != _floor()) return false;
        }
        return true;
    }

    function _floor() internal view returns (uint256) {
        return sys.poolOwner.scheduleOf(0) * cfg.listing.floorBps / 10_000;
    }

    function _max(Result memory x, uint256 gas) internal pure {
        if (gas > x.maxGas) x.maxGas = gas;
    }

    function _report(uint256 k, Result memory x) internal {
        emit log_named_uint("Apes", k);
        emit log_named_uint("rows, all at their price", x.rowsFresh);
        emit log_named_uint("rows, all at their minimum", x.rowsDecayed);
        emit log_named_uint("exposure fresh (bps)", x.exposureFresh);
        emit log_named_uint("FWA fee fresh", x.feeFresh);
        emit log_named_uint("FWA fee decayed", x.feeDecayed);
        emit log_named_uint("keeper calls to list all", x.callsList);
        emit log_named_uint("keeper calls to decay all and grow", x.callsDecay);
        emit log_named_uint("largest maintenance call (gas)", x.maxGas);
        emit log_named_uint("purchase gate (gas)", x.gateGas);
        emit log_named_uint("acquire (gas)", x.acquireGas);
        emit log_named_uint("settle an Ape win (gas)", x.settleGas);
        emit log_named_uint("site draws / with upkeep", x.siteDraws * 1000 + x.upkeepDraws);
        emit log_named_uint("largest site draw (gas)", x.maxDrawGas);
        string memory key = "many";
        vm.serializeUint(key, "apes", k);
        vm.serializeUint(key, "rows_fresh", x.rowsFresh);
        vm.serializeUint(key, "rows_decayed", x.rowsDecayed);
        vm.serializeUint(key, "exposure_fresh_bps", x.exposureFresh);
        vm.serializeUint(key, "fwa_fee_fresh_wei", x.feeFresh);
        vm.serializeUint(key, "fwa_fee_decayed_wei", x.feeDecayed);
        vm.serializeUint(key, "keeper_calls_list_all", x.callsList);
        vm.serializeUint(key, "keeper_calls_decay_and_grow", x.callsDecay);
        vm.serializeUint(key, "keeper_calls_after_win", x.callsWin);
        vm.serializeUint(key, "max_maintenance_gas", x.maxGas);
        vm.serializeUint(key, "purchase_gate_gas", x.gateGas);
        vm.serializeUint(key, "acquire_gas", x.acquireGas);
        vm.serializeUint(key, "site_draws", x.siteDraws);
        vm.serializeUint(key, "site_draws_with_upkeep", x.upkeepDraws);
        vm.serializeUint(key, "site_draw_max_gas", x.maxDrawGas);
        vm.serializeUint(key, "upkeep_measured_max_gas", x.maxUpkeepMeasured);
        string memory json = vm.serializeUint(key, "settle_ape_win_gas", x.settleGas);
        vm.writeJson(json, string.concat("docs/receipts/many-apes-", vm.toString(k), ".json"));
    }
}
