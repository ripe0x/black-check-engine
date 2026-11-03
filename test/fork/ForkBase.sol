// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IFWAPool, IFWAFactory} from "../../src/interfaces/IFWA.sol";
import {LaunchConfig} from "../../script/LaunchConfig.sol";
import {FwaFeeBuyer, FwaFeeRelay} from "../../src/periphery/FwaFeeRoutes.sol";
import {Swapper} from "../utils/Swapper.sol";

interface IVrfConsumer {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

interface IVrfRouted {
    function s_vrfCoordinator() external view returns (address);
}

/// @dev The Draw Packs instance (lib/shape-packs `ShapePacks`), as tests use it.
interface IPacksView {
    function ownerOf(uint256 packId) external view returns (address);
    function valueOf(uint256 packId) external view returns (uint256);
    function contentsOf(uint256 packId) external view returns (uint256[] memory);
    function packOf(uint256 shapeId) external view returns (uint256);
    function exists(uint256 packId) external view returns (bool);
    function open(uint256 packId) external;
    function redeem(uint256 packId) external;
    function MIN_PACK_VALUE() external view returns (uint256);
    function transferFrom(address from, address to, uint256 packId) external;
}

interface IERC721Lite {
    function ownerOf(uint256 tokenId) external view returns (address);
    function setApprovalForAll(address operator, bool approved) external;
    function balanceOf(address owner) external view returns (uint256);
}

interface IERC20Lite {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice Mainnet fork base. Forks Ethereum at `FORK_BLOCK` from `MAINNET_RPC_URL` (an archive endpoint, or a local
///         anvil fork of one) and deploys a whole collection game with `script/DeploySystem.sol` against the real BAYC,
///         Shapes, FWA factory, VRF service, FWA token and Uniswap v4 PoolManager.
abstract contract ForkBase is Test, LaunchConfig {
    uint256 internal constant FORK_BLOCK = 26_284_000;
    address internal constant VRF_SERVICE = 0xA4adFC35dB18326eFB3b5D9bf66A8103Ec2D5EE2;
    /// @dev Opening tick: ~20M coins per ETH (an opening fully diluted value of ~50 ETH).
    int24 internal constant START_TICK = 173_000; // ~32.6M coins per ETH: ~30.7 ETH opening FDV (D70)

    address internal owner = makeAddr("cg.owner.owner");
    address internal keeper = makeAddr("cg.keeper");
    Config internal cfg;
    System internal sys;
    IFWAPool internal pool;
    Swapper internal swapper;
    uint256 internal nextApe = 1;

    function setUpFork() internal {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co"));
        vm.createSelectFork(rpc, vm.envOr("FORK_BLOCK", FORK_BLOCK));
        // the same transaction gas price however the suite is run: with `--fork-url` Foundry takes it from the forked
        // chain, and FWA's randomness fee (and so every quote) depends on it; tests that need a price set their own
        vm.txGasPrice(0);
    }

    /// @dev Forks and deploys the BAYC game from this test contract (no pool yet).
    function deployBayc() internal {
        setUpFork();
        cfg = _baycConfig(owner);
        _deploy();
    }

    function _deploy() internal {
        cfg.create2Deployer = address(this);
        cfg.create2Direct = true;
        vm.deal(address(this), 10 ether);
        sys = _deploySystem(cfg, address(this));
        postflight(cfg, sys, address(this));
        swapper = new Swapper(IPoolManager(cfg.poolManager), sys.liquidity.poolKey());
    }

    // ------------------------------------------------------------------ governance

    /// @dev Calls `target` as the owner (administration takes effect at once).
    function govern(address target, bytes memory data) internal {
        vm.prank(owner);
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    // ------------------------------------------------------------------ FWA pool

    /// @dev Delivers the 50,000 FWA creation fee to the pool owner by buying it with ETH, then creates the pool.
    function createPool() internal {
        FwaFeeBuyer buyer = new FwaFeeBuyer(IPoolManager(cfg.poolManager), MAINNET_FWA_TOKEN);
        uint256 fee = IFWAFactory(cfg.fwaFactory).poolCreationFee();
        uint256 eth = fwaQuoteEth(fee * 10_400 / 10_000);
        vm.deal(address(this), address(this).balance + eth);
        buyer.buyTo{value: eth}(address(sys.poolOwner), fee);
        sys.poolOwner.createPool(keccak256("collection-games.bayc.v1"));
        pool = sys.poolOwner.pool();
    }

    /// @dev ETH that buys about `fwaOut` FWA (binary search on a snapshot).
    function fwaQuoteEth(uint256 fwaOut) internal returns (uint256 eth) {
        FwaFeeBuyer b = new FwaFeeBuyer(IPoolManager(cfg.poolManager), MAINNET_FWA_TOKEN);
        address probe = makeAddr("probe");
        uint256 lo = 0.01 ether;
        uint256 hi = 200 ether;
        for (uint256 i; i < 40; ++i) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            vm.deal(address(this), address(this).balance + mid);
            uint256 out = b.buyTo{value: mid}(probe, 0);
            vm.revertToState(snap);
            if (out >= fwaOut) hi = mid;
            else lo = mid;
        }
        eth = hi;
    }

    // ------------------------------------------------------------------ market

    /// @dev Opens the market, creating the FWA pool first when a test has not (the market opens only after it, D91).
    function openMarket() internal {
        if (address(sys.poolOwner.pool()) == address(0)) createPool();
        vm.prank(owner);
        sys.liquidity.launch();
    }

    /// @dev Past the hook's opening curve (69% falling one point a minute to the ordinary fee by minute 64).
    function pastOpeningCurve() internal {
        vm.warp(block.timestamp + 65 minutes);
        vm.roll(block.number + 325);
    }

    /// @dev Every trading fee paid so far: the vault's part and the $LAYER share waiting in the tap (D90).
    function feesPaid() internal view returns (uint256) {
        return sys.vault.tradingFees() + (sys.layerTap == address(0) ? 0 : sys.layerTap.balance);
    }

    function buyCoin(address who, uint256 eth) internal returns (uint256 out) {
        vm.deal(who, who.balance + eth);
        vm.prank(who);
        (, out) = swapper.buy{value: eth}(eth, false);
    }

    function sellCoin(address who, uint256 amount) internal returns (uint256 ethOut) {
        vm.startPrank(who);
        sys.token.approve(address(swapper), amount);
        (, ethOut) = swapper.sell(amount, false);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ collection

    /// @dev An ordinary BAYC holder sells token `id` to the protocol for the whole live bid.
    function sellApe(uint256 id) internal returns (uint256 price) {
        price = sellApeAt(id, sys.vault.liveBid());
    }

    /// @dev An ordinary BAYC holder sells token `id` to the protocol for `price` (at most the live bid).
    function sellApeAt(uint256 id, uint256 price) internal returns (uint256) {
        address holder = IERC721Lite(cfg.collection).ownerOf(id);
        vm.startPrank(holder);
        IERC721Lite(cfg.collection).setApprovalForAll(address(sys.vault), true);
        sys.vault.sellToProtocol(id, price);
        vm.stopPrank();
        return price;
    }

    /// @dev Sweeps the live bid (as keepers, waiting sellers or players' draws would), waiting out each cooldown
    ///      (12 s blocks), until it reaches `target` or nothing more can enter it.
    function riseBidTo(uint256 target) internal returns (uint256 bid) {
        for (uint256 i; i < 10_000; ++i) {
            bid = sys.vault.liveBid();
            if (bid >= target) return bid;
            try sys.vault.sweep() {}
            catch {
                uint256 next = sys.vault.nextSweepBlock();
                if (block.number >= next) return bid; // nothing left to forward
                vm.warp(block.timestamp + (next - block.number) * 12);
                vm.roll(next);
            }
        }
    }

    /// @dev Finds the next BAYC token not already in protocol custody, from `nextApe`.
    function nextApeId() internal returns (uint256 id) {
        while (true) {
            id = nextApe++;
            address o = IERC721Lite(cfg.collection).ownerOf(id);
            if (o != address(sys.poolOwner) && o.code.length == 0) return id;
        }
    }

    // ------------------------------------------------------------------ launch lifecycle

    /// @dev Contributes ETH to the vault as if trading fees had accrued (`receive` from the PoolManager).
    function accrueFees(uint256 eth) internal {
        vm.deal(cfg.poolManager, cfg.poolManager.balance + eth);
        vm.prank(cfg.poolManager);
        (bool ok,) = address(sys.vault).call{value: eth}("");
        require(ok, "fee accrual");
    }

    /// @dev What keepers can earn listing the opening board: the opening allowance is a limit, not a deposit (D79),
    ///      and listing the board costs about 0.05-0.14 ETH, so fees fund at most 0.1 ETH of it.
    function listingPayRoom() internal view returns (uint256) {
        return cfg.openingAllowance < 0.1 ether ? cfg.openingAllowance : 0.1 ether;
    }

    /// @dev Full launch: pool, market, first Ape at `apePrice`, the board, the reserve, activation.
    function launchGame(uint256 apePrice) internal {
        createPool();
        openMarket();
        // fees for the Ape and the sweep rewards on the way
        accrueFees(apePrice + 0.05 ether);
        // the live bid fills to its threshold at once, then is metered up by sweeps
        assertGe(riseBidTo(apePrice), apePrice, "bid metered up to the price");
        sellApeAt(nextApeId(), apePrice);
        // the board and reserve, plus room for the keeper pay of listing it
        uint256 need = sys.game.capitalNeed() + listingPayRoom();
        accrueFees(need);
        syncAll();
        _logReady();
        sys.game.activate();
        assertTrue(sys.game.activated(), "activated");
    }

    function _logReady() internal {
        emit log_named_uint("liveRows popcount (liveCount)", sys.game.liveCount());
        emit log_named_uint("boardSize", sys.game.boardSize());
        emit log_named_uint("unsettled", pool.unsettledAcquisitionCount());
        emit log_named_uint("activeListingCount", pool.activeListingCount());
        emit log_named_uint("collectionAvailable", sys.poolOwner.collectionAvailable() ? 1 : 0);
        emit log_named_uint("cash", sys.game.cash());
        emit log_named_uint("admissible", sys.game.admissible() ? 1 : 0);
        emit log_named_uint("custody", sys.poolOwner.custodyCount());
        emit log_named_uint("vault general", sys.vault.generalBalance());
        emit log_named_uint("capitalNeed", sys.game.capitalNeed());
    }

    /// @dev The game's books reconcile to its ETH: cash + proceeds still in FWA equals capital in + booked revenue −
    ///      prizes carried − prize expense − keeper pay − distributions − returns, up to the 1 wei per capture FWA's split
    ///      rounds in the owner's favour.
    function assertBooks() internal view {
        uint256 actual = sys.game.cash() + (address(pool) == address(0) ? 0 : pool.ownerProceeds());
        uint256 credits = sys.game.capitalIn() + sys.game.revenue();
        uint256 debits = sys.game.inventoryCost() + sys.game.prizeExpense() + sys.game.keeperPaid() + sys.game.distributed()
            + sys.game.returnedToVault();
        assertGe(actual + debits, credits, "books: cash below ledger");
        // FWA credits owner proceeds at delivery; the game books them at its next sync. Exact once caught up.
        bool caughtUp = address(pool) == address(0)
            || (sys.game.seenSeq() > pool.lastIssuedSequence() && sys.game.openCount() == 0);
        if (caughtUp) {
            assertLe(actual + debits - credits, sys.game.pullsFulfilled() + 1, "books: unexplained cash");
        }
        (, uint256 d) = sys.game.distributable();
        int256 undistributed = sys.game.profit() - int256(sys.game.distributed());
        if (undistributed <= 0) assertEq(d, 0, "nothing distributable while a loss is carried");
    }

    // ------------------------------------------------------------------ pulls

    function pull(address purchaser) internal returns (uint256 requestId) {
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        uint256 version = pool.inventoryVersion();
        vm.deal(purchaser, purchaser.balance + total);
        vm.prank(purchaser);
        requestId = pool.acquire{value: total}(purchaser, fee, 0, 10_000, version, block.timestamp + 1 hours);
    }

    function deliverWord(uint256 requestId, uint256 word) internal {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        vm.prank(IVrfRouted(VRF_SERVICE).s_vrfCoordinator());
        IVrfConsumer(VRF_SERVICE).rawFulfillRandomWords(requestId, words);
    }

    function pullAndSettle(address purchaser, uint256 word) internal returns (uint256 requestId) {
        requestId = pull(purchaser);
        vm.roll(block.number + 3);
        deliverWord(requestId, word);
        pool.processAcquisitions(10);
    }

    /// @dev A word that makes the head request capture the first Active listing matching `pick`: a Shape of backing
    ///      `wantBacking`, or (wantBacking == type(uint256).max) a collection listing. FWA picks `word % totalWeight`
    ///      along slot order.
    function wordFor(uint256 wantBacking) internal view returns (uint256 prefix) {
        for (uint256 slot = 1; slot < 2000; ++slot) {
            uint256 id = pool.slotToListing(slot);
            if (id == 0) continue;
            (address c,,,, uint256 weight,,, IFWAPool.ListingStatus st) = pool.listings(id);
            if (st != IFWAPool.ListingStatus.Active) continue;
            if (wantBacking == type(uint256).max) {
                if (c == cfg.collection) return prefix;
            } else if (c == cfg.shapes || c == sys.packs) {
                (, uint72 backing,,,,,) = sys.game.items(id);
                if (backing == wantBacking || wantBacking == 0) return prefix;
            }
            prefix += weight;
        }
        revert("wordFor: none");
    }

    function window() internal {
        (, uint256 interval,,,,,,) = sys.game.settings();
        vm.warp(block.timestamp + interval);
    }

    function syncAll() internal {
        for (uint256 i; i < 30; ++i) {
            vm.prank(keeper);
            try sys.game.sync() {} catch { return; }
        }
    }

    /// @dev True when FWA would accept a purchase now: purchases enabled and our purchase gate admits it.
    function canPull(address who) internal view returns (bool) {
        return pool.localPurchasesEnabled() && sys.poolOwner.canPurchase(who);
    }

    function playMany(address who, uint256 n, uint256 seed) internal {
        for (uint256 i; i < n; ++i) {
            if (!canPull(who)) {
                window();
                syncAll();
                if (!canPull(who)) break;
            }
            pullAndSettle(who, uint256(keccak256(abi.encode(seed, i))));
            if (i % 10 == 9) {
                window();
                syncAll();
            }
        }
        restockAll();
    }

    /// @dev Keeper maintenance across maintenance windows until every row in play is listed again: a call lists at most
    ///      the board's `maxPerCall` and a remainder below `listBatch` waits for the next window (D61).
    function restockAll() internal {
        for (uint256 i; i < 20; ++i) {
            window();
            syncAll();
            if (sys.game.liveCount() == sys.game.boardSize()) return;
        }
    }

    function statusOf(uint256 requestId) internal view returns (IFWAPool.AcquisitionStatus st) {
        (,,,, st) = pool.acquisitions(requestId);
    }

    receive() external payable {}
}
