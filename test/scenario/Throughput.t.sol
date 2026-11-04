// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "../fork/ForkBase.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";

/// @notice FWA throughput on the pinned fork with the real FWA pool and VRF service: the in-flight limit `maxInFlight`
///         (3, 4, 5, 10) against the opening board size (50, 75, 100), under seeded arrival streams of single draws
///         and five-draw batches (FWA's per-transaction maximum), bursts on one quote, delayed and missing VRF words,
///         heavy demand with and without FWA's inventory cooldown, and a lazy keeper. Every purchase goes straight to
///         FWA's `acquireBatch`, as the official frontend does. Per run: draws attempted, completed (Fulfilled),
///         refunded for settlement drift, expired, refused at request, the most requests ever unsettled at once,
///         keeper gas, and Ape wins. Receipts: docs/receipts/throughput/k<K>-b<board>.json; table:
///         sim/throughput_table.py.
abstract contract ThroughputBase is ForkBase {
    struct Scenario {
        string name;
        uint256 blocks;
        uint256 arrivalPpm; // chance per block of an arrival, parts per million
        uint256 batchPpm; // chance an arrival is a five-draw batch instead of a single draw
        uint256 burstEvery; // every N blocks, a burst of three five-draw batches on one quote (0 = none)
        uint256 vrfMin; // VRF word delay, blocks
        uint256 vrfMax;
        uint256 missingPpm; // chance a word never arrives (request expires)
        uint256 syncEvery; // keeper cadence, blocks
        uint32 cooldown; // FWA inventory cooldown, seconds
    }

    struct Result {
        uint256 attempted;
        uint256 issued;
        uint256 fulfilled;
        uint256 refunded;
        uint256 expired;
        uint256 refused;
        uint256 maxUnsettled;
        uint256 keeperGas;
        uint256 syncs;
        uint256 apeWins;
        uint256 turnover;
    }

    struct Pending {
        uint256 id;
        uint256 readyAt;
        bool missing;
    }

    uint256 internal constant BATCH = 5;
    Pending[] internal pend;
    uint256 internal rng;
    string internal json;
    uint256 internal inFlight;

    function _rand() internal returns (uint256) {
        rng = uint256(keccak256(abi.encode(rng)));
        return rng;
    }

    function _setup(uint256 boardSize, uint32 cooldown) internal {
        setUpFork();
        cfg = _testChecksConfig();
        cfg.initialBoardSize = boardSize;
        cfg.maxInFlight = inFlight;
        _configureBoard();
        _deploy();
        launchGame(0.25 ether);
        if (cooldown != 0) {
            (bool ok, bytes memory o) = cfg.fwaFactory.staticcall(abi.encodeWithSignature("owner()"));
            require(ok);
            vm.prank(abi.decode(o, (address)));
            (ok,) = cfg.fwaFactory.call(abi.encodeWithSignature("setInventoryChangeCooldown(uint32)", cooldown));
            require(ok, "cooldown setter");
        }
        delete pend;
    }

    /// @dev Overridden by studies that compare other boards (test/scenario/BoardChoice.t.sol).
    function _configureBoard() internal virtual {}

    function _receiptPath(uint256 k, uint256 boardSize) internal view virtual returns (string memory) {
        return string.concat("docs/receipts/throughput/k", vm.toString(k), "-b", vm.toString(boardSize), ".json");
    }

    function _issue(Result memory r, Scenario memory sc, uint256 count) internal {
        r.attempted += count;
        if (!pool.localPurchasesEnabled()) {
            r.refused += count;
            return;
        }
        address who = address(uint160(0xC0FFEE0000 + _rand() % 50));
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(count);
        uint256 version = pool.inventoryVersion();
        vm.deal(who, who.balance + total);
        vm.prank(who);
        try pool.acquireBatch{value: total}(who, count, fee, 0, 10_000, version, block.timestamp + 1 hours) returns (
            uint256[] memory ids
        ) {
            for (uint256 i; i < ids.length; ++i) {
                uint256 delay = sc.vrfMin + (sc.vrfMax > sc.vrfMin ? _rand() % (sc.vrfMax - sc.vrfMin + 1) : 0);
                pend.push(Pending(ids[i], block.number + delay, _rand() % 1e6 < sc.missingPpm));
                ++r.issued;
            }
            uint256 u = pool.unsettledAcquisitionCount();
            if (u > r.maxUnsettled) r.maxUnsettled = u;
        } catch {
            r.refused += count;
        }
    }

    function _deliverDue() internal {
        uint256 i;
        while (i < pend.length) {
            Pending memory p = pend[i];
            if (p.missing || block.number < p.readyAt) {
                ++i;
                continue;
            }
            uint256[] memory words = new uint256[](1);
            words[0] = _rand();
            vm.prank(IVrfRoutedT(VRF_SERVICE).s_vrfCoordinator());
            try IVrfConsumerT(VRF_SERVICE).rawFulfillRandomWords(p.id, words) {} catch {}
            pend[i] = pend[pend.length - 1];
            pend.pop();
        }
    }

    function _sync(Result memory r) internal {
        uint256 g = gasleft();
        vm.prank(keeper);
        try sys.game.sync() {
            r.keeperGas += g - gasleft();
            ++r.syncs;
        } catch {}
    }

    function _run(Scenario memory sc, uint256 boardSize, uint256 seed) internal returns (Result memory r) {
        _setup(boardSize, sc.cooldown);
        rng = seed;
        uint256 firstSeq = pool.lastIssuedSequence() + 1;
        for (uint256 b; b < sc.blocks; ++b) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 12);
            if (_rand() % 1e6 < sc.arrivalPpm) _issue(r, sc, _rand() % 1e6 < sc.batchPpm ? BATCH : 1);
            if (sc.burstEvery != 0 && b % sc.burstEvery == sc.burstEvery - 1) {
                for (uint256 k; k < 3; ++k) {
                    _issue(r, sc, BATCH);
                }
            }
            _deliverDue();
            try pool.processAcquisitions(10) {} catch {}
            if (b % sc.syncEvery == 0) _sync(r);
        }
        for (uint256 k; k < 40; ++k) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 12);
            _deliverDue();
            try pool.processAcquisitions(10) {} catch {}
        }
        // book everything left (`bookPerCall` per call)
        for (uint256 k; k < 25 && pool.lastIssuedSequence() >= sys.game.seenSeq(); ++k) {
            _sync(r);
        }
        uint64 last = pool.lastIssuedSequence();
        for (uint64 q = uint64(firstSeq); q <= last; ++q) {
            (,,,, IFWAPool.AcquisitionStatus st) = pool.acquisitions(pool.requestIdAtSequence(q));
            if (st == IFWAPool.AcquisitionStatus.Fulfilled) ++r.fulfilled;
            else if (st == IFWAPool.AcquisitionStatus.Refunded) ++r.refunded;
            else if (st == IFWAPool.AcquisitionStatus.Expired) ++r.expired;
        }
        r.apeWins = sys.game.collectionWins();
        r.turnover = sys.game.turnover();
        assertBooks();
        assertLe(r.maxUnsettled, inFlight - 1 + BATCH, "the gate's bound with batches");
    }

    function _scenarios() internal pure returns (Scenario[6] memory s) {
        // ~1 arrival a minute, 10% of them five-draw batches (~1.4 draws a minute)
        s[0] = Scenario("steady", 900, 200_000, 100_000, 0, 3, 3, 0, 5, 0);
        // a burst of three five-draw batches every 12 minutes on top of a light stream
        s[1] = Scenario("bursts of 15 on one quote", 900, 100_000, 100_000, 60, 3, 3, 0, 5, 0);
        s[2] = Scenario("delayed and missing VRF", 900, 200_000, 100_000, 0, 3, 28, 30_000, 5, 0);
        // ~3 arrivals a minute, 30% batches (~6.6 draws a minute)
        s[3] = Scenario("heavy demand", 900, 600_000, 300_000, 0, 3, 6, 0, 5, 0);
        s[4] = Scenario("heavy demand, FWA cooldown 5 min", 900, 600_000, 300_000, 0, 3, 6, 0, 5, 300);
        s[5] = Scenario("steady, lazy keeper (5 min)", 900, 200_000, 100_000, 0, 3, 3, 0, 25, 0);
    }

    function _record(uint256 i, Scenario memory sc, uint256 boardSize, Result memory r) internal {
        string memory obj = string.concat("s", vm.toString(i));
        vm.serializeString(obj, "scenario", sc.name);
        vm.serializeUint(obj, "maxInFlight", inFlight);
        vm.serializeUint(obj, "board", boardSize);
        vm.serializeUint(obj, "attempted", r.attempted);
        vm.serializeUint(obj, "issued", r.issued);
        vm.serializeUint(obj, "fulfilled", r.fulfilled);
        vm.serializeUint(obj, "refunded", r.refunded);
        vm.serializeUint(obj, "expired", r.expired);
        vm.serializeUint(obj, "refused", r.refused);
        vm.serializeUint(obj, "maxUnsettled", r.maxUnsettled);
        vm.serializeUint(obj, "keeperGas", r.keeperGas);
        vm.serializeUint(obj, "syncs", r.syncs);
        vm.serializeUint(obj, "apeWins", r.apeWins);
        string memory out = vm.serializeUint(obj, "turnoverWei", r.turnover);
        json = vm.serializeString("throughput", obj, out);
        emit log_string(
            string.concat(
                sc.name, " | K ", vm.toString(inFlight), " board ", vm.toString(boardSize), " | attempted ",
                vm.toString(r.attempted), " fulfilled ", vm.toString(r.fulfilled), " refunded ", vm.toString(r.refunded),
                " expired ", vm.toString(r.expired), " refused ", vm.toString(r.refused), " max unsettled ",
                vm.toString(r.maxUnsettled)
            )
        );
    }

    function _grid(uint256 k, uint256 boardSize) internal virtual {
        inFlight = k;
        Scenario[6] memory s = _scenarios();
        for (uint256 i; i < 6; ++i) {
            Result memory r = _run(s[i], boardSize, 1000 + i);
            _record(i, s[i], boardSize, r);
        }
        vm.writeJson(json, _receiptPath(k, boardSize));
    }
}

/// @notice The in-flight limit x board size grid on the launch board pattern.
contract ThroughputTest is ThroughputBase {
    function test_k3_b50() public {
        _grid(3, 50);
    }

    function test_k4_b50() public {
        _grid(4, 50);
    }

    function test_k5_b50() public {
        _grid(5, 50);
    }

    function test_k10_b50() public {
        _grid(10, 50);
    }

    function test_k3_b75() public {
        _grid(3, 75);
    }

    function test_k4_b75() public {
        _grid(4, 75);
    }

    function test_k5_b75() public {
        _grid(5, 75);
    }

    function test_k10_b75() public {
        _grid(10, 75);
    }

    function test_k3_b100() public {
        _grid(3, 100);
    }

    function test_k4_b100() public {
        _grid(4, 100);
    }

    function test_k5_b100() public {
        _grid(5, 100);
    }

    function test_k10_b100() public {
        _grid(10, 100);
    }
}

interface IVrfConsumerT {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

interface IVrfRoutedT {
    function s_vrfCoordinator() external view returns (address);
}
