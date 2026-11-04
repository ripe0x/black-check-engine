// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {DeploySystem} from "../../script/DeploySystem.sol";
import {Swapper} from "../utils/Swapper.sol";

interface IVrf {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
    function s_vrfCoordinator() external view returns (address);
}

interface IERC721H {
    function ownerOf(uint256) external view returns (address);
    function setApprovalForAll(address, bool) external;
}

/// @notice Drives a launched game with random actions: pulls (single and batched), VRF words in and out of order,
///         timeouts, keeper syncs, maintenance windows, trading, fee and contribution inflows, acquisitions,
///         buybacks, milestone releases and adversarial calls. Records ghost values the
///         invariants read.
contract Handler is Test {
    address internal constant VRF_SERVICE = 0xA4adFC35dB18326eFB3b5D9bf66A8103Ec2D5EE2;

    DeploySystem.System internal s;
    IFWAPool public pool;
    Swapper internal swapper;
    address internal collection;
    address internal poolManager;
    address[3] internal players;
    uint256[] internal pending;
    uint256 internal nextApe = 2000;

    uint256 public maxProfitSeen;
    uint256 internal _paidSeen;
    uint256 public calls;
    uint256 public adversarialSuccesses;
    uint256 public notionalIncreases;
    mapping(uint256 listingId => uint256) internal _lastNotional;

    constructor(DeploySystem.System memory s_, IFWAPool pool_, Swapper swapper_, address collection_, address pm) {
        s = s_;
        pool = pool_;
        swapper = swapper_;
        collection = collection_;
        poolManager = pm;
        players = [makeAddr("cg.inv.p1"), makeAddr("cg.inv.p2"), makeAddr("cg.inv.p3")];
        _paidSeen = s_.game.keeperPaid(); // the opening board's listing pay is not this campaign's
    }

    function _track() internal {
        // a sync distributes before it pays its keeper (D79: the flat fee is paid even at a zero gas price), so the
        // profit a distribution was checked against is the profit after the call plus that call's keeper pay
        uint256 paid = s.game.keeperPaid();
        int256 p = s.game.profit() + int256(paid - _paidSeen);
        _paidSeen = paid;
        if (p > 0 && uint256(p) > maxProfitSeen) maxProfitSeen = uint256(p);
        // a listed collection NFT's notional (its odds) never gets worse
        for (uint256 i; i < s.poolOwner.listedCount(); ++i) {
            uint256 id = s.poolOwner.listedAt(i);
            (, uint128 n,,,,) = s.poolOwner.cListings(id);
            uint256 last = _lastNotional[id];
            if (last != 0 && n > last) ++notionalIncreases;
            _lastNotional[id] = n;
        }
        ++calls;
    }

    function pull(uint256 who, uint256 count) external {
        if (!pool.localPurchasesEnabled()) return;
        address purchaser = players[who % 3];
        count = 1 + count % 5; // up to FWA's per-transaction maximum
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(count);
        uint256 version = pool.inventoryVersion();
        vm.deal(purchaser, purchaser.balance + total * count);
        vm.prank(purchaser);
        try pool.acquireBatch{value: total * count}(purchaser, count, fee, 0, 10_000, version, block.timestamp + 1 hours)
        returns (uint256[] memory ids) {
            for (uint256 i; i < ids.length; ++i) {
                pending.push(ids[i]);
            }
        } catch {}
        _track();
    }

    function deliver(uint256 pick, uint256 word) external {
        if (pending.length == 0) return;
        uint256 i = pick % pending.length;
        uint256 id = pending[i];
        pending[i] = pending[pending.length - 1];
        pending.pop();
        vm.roll(block.number + 3);
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        vm.prank(IVrf(VRF_SERVICE).s_vrfCoordinator());
        try IVrf(VRF_SERVICE).rawFulfillRandomWords(id, words) {} catch {}
        try pool.processAcquisitions(10) {} catch {}
        _track();
    }

    function timeout() external {
        vm.roll(block.number + 40);
        try pool.processAcquisitions(10) {} catch {}
        delete pending;
        _track();
    }

    function sync(uint256) external {
        vm.prank(makeAddr("cg.inv.keeper"));
        try s.game.sync() {} catch {}
        _track();
    }

    function window() external {
        vm.warp(block.timestamp + 31 minutes);
        _track();
    }

    function trade(uint256 eth, bool sell) external {
        address t = makeAddr("cg.inv.trader");
        eth = 0.01 ether + eth % 2 ether;
        vm.deal(t, t.balance + eth);
        vm.prank(t);
        try swapper.buy{value: eth}(eth, false) returns (uint256, uint256 out) {
            if (sell) {
                vm.startPrank(t);
                s.token.approve(address(swapper), out / 2);
                try swapper.sell(out / 2, false) {} catch {}
                vm.stopPrank();
            }
        } catch {}
        _track();
    }

    function contribute(uint256 eth) external {
        eth = eth % 5 ether;
        vm.deal(address(this), eth);
        s.vault.contribute{value: eth}();
        _track();
    }

    function acquire() external {
        uint256 id = nextApe++;
        address holder;
        try IERC721H(collection).ownerOf(id) returns (address o) {
            holder = o;
        } catch {
            return;
        }
        if (holder == address(s.poolOwner) || holder.code.length != 0) return;
        // a day of sweeps meters fees into the live bid; then the holder takes the whole bid
        for (uint256 i; i < 72; ++i) {
            vm.roll(block.number + 300);
            vm.warp(block.timestamp + 1 hours);
            try s.vault.sweep() {} catch {}
        }
        uint256 bid = s.vault.liveBid();
        vm.startPrank(holder);
        IERC721H(collection).setApprovalForAll(address(s.vault), true);
        if (bid != 0) try s.vault.sellToProtocol(id, bid) {} catch {}
        vm.stopPrank();
        _track();
    }

    function sweep() external {
        vm.roll(block.number + 300);
        try s.vault.sweep() {} catch {}
        _track();
    }

    function buyback() external {
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 1);
        try s.burner.process(0) {} catch {}
        _track();
    }

    function release(uint256 listingId) external {
        try s.burner.release(1 + listingId % 200) {} catch {}
        _track();
    }

    /// @dev Calls that must always fail. Any success is recorded and fails the invariant.
    function adversarial(uint256 which) external {
        // the attacker is a stranger or the owner (who administers, but has no direct route to custody or capital)
        address attacker = which % 2 == 0 ? makeAddr("cg.inv.attacker") : makeAddr("cg.owner.owner");
        vm.startPrank(attacker);
        bool ok;
        uint256 w = (which / 2) % 12;
        if (w == 11 && which % 2 == 1) {
            vm.stopPrank(); // the sunset is a legitimate owner power (everything to buybacks)
            return;
        }
        if (w == 0) (ok,) = address(s.poolOwner).call(abi.encodeWithSignature("processCollection(uint256)", 1e30));
        else if (w == 1) (ok,) = address(s.poolOwner).call(abi.encodeWithSignature("withdrawCollection()"));
        else if (w == 2) (ok,) = address(s.vault).call(abi.encodeWithSignature("receiveReturn()"));
        else if (w == 3) (ok,) = address(s.game).call(abi.encodeWithSignature("retire()"));
        else if (w == 4) (ok,) = address(s.poolOwner).call(abi.encodeWithSignature("register(uint256,uint256,uint256,uint8)", 1, 1, 1, 0));
        else if (w == 6) (ok,) = address(s.poolOwner).call(abi.encodeWithSignature("migrateApe(address)", attacker));
        else if (w == 7) (ok,) = address(s.vault).call(abi.encodeWithSignature("migrateCapital(address)", attacker));
        else if (w == 8) (ok,) = address(s.hook).call(abi.encodeWithSignature("setFeeRecipient(address)", address(this)));
        else if (w == 9) (ok,) = address(s.migration).call(abi.encodeWithSignature("execute()"));
        else if (w == 10) (ok,) = address(s.migration).call(abi.encodeWithSignature("migrateApes(uint256)", 10));
        else if (w == 11) (ok,) = address(s.migration).call(abi.encodeWithSignature("sunset()"));
        else (ok,) = address(s.vault).call(abi.encodeWithSignature("receiveSurplus()"));
        vm.stopPrank();
        if (ok) ++adversarialSuccesses;
        _track();
    }

    receive() external payable {}
}
