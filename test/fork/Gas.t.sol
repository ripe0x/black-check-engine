// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase, IERC721Lite, IPacksView} from "./ForkBase.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {IGameSync} from "../../src/periphery/DrawRouter.sol";

/// @notice Gas receipts on the pinned fork. Run with `--isolate` so each call is its own transaction (cold storage,
///         21,000 intrinsic included by forge in `--isolate` mode); writes docs/receipts/gas.json.
contract GasForkTest is ForkBase {
    address alice = makeAddr("cg.player.alice");
    string internal j;

    function _g(string memory k, uint256 v) internal {
        j = vm.serializeUint("gas", k, v);
        emit log_named_uint(k, v);
    }

    function _measureDeploy() internal returns (uint256 used) {
        setUpFork();
        cfg = _testChecksConfig();
        cfg.create2Deployer = address(this);
        cfg.create2Direct = true;
        vm.deal(address(this), 10 ether);
        uint256 g = gasleft();
        sys = _deploySystem(cfg, address(this));
        used = g - gasleft();
        swapper = new SwapperFactory().make(cfg.poolManager, sys);
    }

    /// @dev A Pack won, booked and replaced with a new Pack; the winner redeems or opens Packs.
    function _measurePacks() internal {
        uint256 rp = pull(alice);
        vm.roll(vm.getBlockNumber() + 3);
        deliverWord(rp, wordFor(0.03 ether));
        pool.processAcquisitions(10);
        (,,, uint256 packListing,) = pool.acquisitions(rp);
        (uint256 packId,,,,,,) = sys.game.items(packListing);
        window();
        uint256 g = gasleft();
        vm.prank(keeper);
        sys.game.sync();
        _g("sync_book_1_and_replace_1_pack_of_3", g - gasleft());
        g = gasleft();
        vm.prank(alice);
        IPacksView(sys.packs).redeem(packId);
        _g("player_redeem_pack_of_3", g - gasleft());
        uint256 rq = pull(alice);
        vm.roll(vm.getBlockNumber() + 3);
        deliverWord(rq, wordFor(0.02 ether));
        pool.processAcquisitions(10);
        (,,, uint256 packListing2,) = pool.acquisitions(rq);
        (uint256 packId2,,,,,,) = sys.game.items(packListing2);
        window();
        g = gasleft();
        vm.prank(keeper);
        sys.game.sync();
        _g("sync_book_1_and_replace_1_pack_of_2", g - gasleft());
        uint256 rs = pull(alice);
        vm.roll(vm.getBlockNumber() + 3);
        deliverWord(rs, wordFor(0.01 ether));
        pool.processAcquisitions(10);
        window();
        g = gasleft();
        vm.prank(keeper);
        sys.game.sync();
        _g("sync_book_1_and_replace_1_shape_001", g - gasleft());
        g = gasleft();
        vm.prank(alice);
        IPacksView(sys.packs).open(packId2);
        _g("player_open_pack_of_2", g - gasleft());

    }

    function test_gasReceipts() public {
        _g("deploy_system_all_contracts", _measureDeploy());

        uint256 g = gasleft();
        createPool();
        _g("fee_buy_and_create_pool", g - gasleft());

        g = gasleft();
        openMarket();
        _g("market_launch", g - gasleft());

        accrueFees(6.05 ether); // the Ape and the sweep rewards on the way
        uint256 bid = riseBidTo(0.25 ether);
        uint256 id = nextCheckId();
        address holder = IERC721Lite(cfg.collection).ownerOf(id);
        vm.prank(holder);
        IERC721Lite(cfg.collection).setApprovalForAll(address(sys.vault), true);
        g = gasleft();
        vm.prank(holder);
        sys.vault.sellToProtocol(id, bid);
        _g("sell_to_protocol", g - gasleft());

        accrueFees(sys.game.capitalNeed() + listingPayRoom()); // + room for the keepers listing the board
        g = gasleft();
        vm.prank(keeper);
        sys.game.sync();
        _g("sync_fund_and_list_a_batch_of_8", g - gasleft());
        syncAll();
        g = gasleft();
        sys.game.activate();
        _g("activate", g - gasleft());

        // a player's pull
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        uint256 v = pool.inventoryVersion();
        vm.deal(alice, 10 ether);
        g = gasleft();
        vm.prank(alice);
        uint256 r = pool.acquire{value: total}(alice, fee, 0, 10_000, v, vm.getBlockTimestamp() + 1 hours);
        _g("player_acquire", g - gasleft());
        vm.roll(vm.getBlockNumber() + 3);
        deliverWord(r, wordFor(0.05 ether));
        pool.processAcquisitions(10);
        g = gasleft();
        vm.prank(keeper);
        sys.game.sync();
        _g("sync_book_1_before_window", g - gasleft());

        _measurePacks();

        // three pulls booked and replaced in one sync
        for (uint256 i; i < 3; ++i) {
            pullAndSettle(alice, uint256(keccak256(abi.encode("g", i))));
        }
        window();
        g = gasleft();
        vm.prank(keeper);
        sys.game.sync();
        _g("sync_book_3_and_replace_3", g - gasleft());

        // booking only (no window, nothing to list)
        pullAndSettle(alice, 12345);
        g = gasleft();
        vm.prank(keeper);
        try sys.game.sync() {} catch {}
        _g("sync_book_1_no_listing", g - gasleft());

        // decay reprice of the lead
        vm.prank(address(sys.game));
        g = gasleft();
        sys.poolOwner.processCollection(12 ether);
        _g("collection_decay_reprice", g - gasleft());

        // distribution: play until the game has sent surplus to the burner (early profit depends on the seed); at
        // launch all of it is locked in the milestone reserve until an Ape win releases it (D74)
        for (uint256 k; k < 6 && sys.burner.reserve() == 0; ++k) {
            playMany(alice, 60, 99 + k);
        }

        // collection win booked + milestone release + promotion attempt
        uint256 r2 = pull(alice);
        vm.roll(vm.getBlockNumber() + 3);
        deliverWord(r2, wordFor(type(uint256).max));
        pool.processAcquisitions(10);
        g = gasleft();
        vm.prank(keeper);
        sys.game.sync();
        _g("sync_collection_win_and_milestone_release", g - gasleft());

        // a buyback slice of the released reserve
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.roll(vm.getBlockNumber() + 1);
        g = gasleft();
        vm.prank(keeper);
        sys.burner.process(0);
        _g("burner_process_slice", g - gasleft());

        // a player's draw through the DrawRouter (D53), nothing waiting to settle
        {
            (uint256 f2,, uint256 t2) = pool.quoteAcquisitionPrice(1);
            uint256 v2 = pool.inventoryVersion();
            vm.deal(alice, 10 ether);
            g = gasleft();
            vm.prank(alice);
            sys.drawRouter.draw{value: t2}(
                pool, IGameSync(address(sys.game)), 10, 0, 0, 1, f2, 0, 10_000, v2, vm.getBlockTimestamp() + 1 hours
            );
            _g("player_router_draw", g - gasleft());
        }

        // canPurchase (FWA staticcalls it with a 100,000 gas stipend)
        vm.prank(address(pool));
        g = gasleft();
        sys.poolOwner.canPurchase(alice);
        _g("can_purchase_view", g - gasleft());

        vm.writeJson(j, "docs/receipts/gas.json");
    }
}

import {Swapper} from "../utils/Swapper.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {DeploySystem} from "../../script/DeploySystem.sol";

contract SwapperFactory {
    function make(address pm, DeploySystem.System memory s) external returns (Swapper) {
        return new Swapper(IPoolManager(pm), s.liquidity.poolKey());
    }
}
