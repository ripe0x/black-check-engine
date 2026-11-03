// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FwaFeeBuyer} from "../../src/periphery/FwaFeeRoutes.sol";
import {Swapper} from "../../test/utils/Swapper.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {DrawRouter, IGameSync} from "../../src/periphery/DrawRouter.sol";
import {MockSuccessor} from "../../test/utils/MigrationMocks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface ILiquidityKey {
    function poolKey() external view returns (PoolKey memory);
}

interface IVaultR {
    function sellToProtocol(uint256 tokenId, uint256 price) external;
    function liveBid() external view returns (uint256);
}

interface IGameR {
    function capitalNeed() external view returns (uint256);
    function pool() external view returns (IFWAPool);
}

interface IERC721R {
    function ownerOf(uint256) external view returns (address);
    function setApprovalForAll(address, bool) external;
}

interface IVrfR {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
    function s_vrfCoordinator() external view returns (address);
}

/// @notice Local anvil rehearsal helpers (script/rehearse-anvil.sh). Run with `--unlocked` against an anvil started
///         with `--auto-impersonate`; never against a live network. Each function is one rehearsal step.
contract Rehearse is Script {
    address constant PM = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address constant VRF_SERVICE = 0xA4adFC35dB18326eFB3b5D9bf66A8103Ec2D5EE2;

    function _dep(string memory key) internal view returns (address) {
        string memory json = vm.readFile(string.concat("deployments/", vm.envOr("DEPLOY_ENV", string("anvil")), ".json"));
        return vm.parseJsonAddress(json, string.concat(".", key));
    }

    /// @notice Gives `owner` FWA the way a wallet can receive it (a buy delivered by the PoolManager): stands in for
    ///         the owner's existing FWA balance.
    function seedFwa(address owner, uint256 eth) external {
        vm.startBroadcast(owner);
        FwaFeeBuyer b = new FwaFeeBuyer(IPoolManager(PM), FWA);
        b.buyTo{value: eth}(owner, 0);
        vm.stopBroadcast();
    }

    /// @notice Ordinary trading through a public router (fees go to the vault).
    function trade(address trader, uint256 rounds) external {
        vm.startBroadcast(trader);
        Swapper s = new Swapper(IPoolManager(PM), _key());
        for (uint256 i; i < rounds; ++i) {
            (, uint256 out) = s.buy{value: 0.5 ether}(0.5 ether, false);
            (bool ok,) = _dep("token").call(abi.encodeWithSignature("approve(address,uint256)", address(s), out / 2));
            require(ok);
            s.sell(out / 2, false);
        }
        vm.stopBroadcast();
    }

    function _key() internal view returns (PoolKey memory) {
        return ILiquidityKey(_dep("liquidity")).poolKey();
    }

    /// @notice A BAYC holder accepts the live bid for `tokenId`, naming the whole bid as its price.
    function sellApe(uint256 tokenId) external {
        address collection = _dep("collection");
        address holder = IERC721R(collection).ownerOf(tokenId);
        uint256 bid = IVaultR(_dep("vault")).liveBid();
        console2.log("holder", holder, "bid", bid);
        vm.startBroadcast(holder);
        IERC721R(collection).setApprovalForAll(_dep("vault"), true);
        IVaultR(_dep("vault")).sellToProtocol(tokenId, bid);
        vm.stopBroadcast();
    }

    /// @notice A player pulls once through FWA directly, as FWA's own interface would.
    function pull(address player) external {
        IFWAPool pool = IGameR(_dep("game")).pool();
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        uint256 v = pool.inventoryVersion();
        vm.startBroadcast(player);
        pool.acquire{value: total + 0.01 ether}(player, fee, 0, 1_000, v, block.timestamp + 1 hours);
        vm.stopBroadcast();
    }

    /// @notice A draw through the DrawRouter, as the site makes it: quoted after the settlement it makes, bought for the
    ///         player; with `syncCount` the upkeep is measured first (simulated) and requested with a budget 30% above
    ///         the measurement when it is within the site's 2.5M-gas limit, and the player is paid for it (D60).
    function routerDraw(address player, uint256 syncCount) external {
        IFWAPool pool = IGameR(_dep("game")).pool();
        DrawRouter router = DrawRouter(payable(_dep("drawRouter")));
        (uint256 fee,, uint256 total) = router.quote(pool, 10, 1); // simulated here, not broadcast
        uint256 v = pool.inventoryVersion();
        uint256 budget;
        if (syncCount != 0) {
            uint256 snap = vm.snapshotState(); // measured as the player (as the site does), not broadcast, discarded
            vm.prank(player);
            (bool ran, uint256 used) = router.measureUpkeep(IGameSync(_dep("game")), syncCount);
            vm.revertToState(snap);
            if (ran && used <= 2_500_000) budget = used * 13 / 10 + 50_000;
            console2.log("upkeep measured", used, ran ? "to do" : "nothing to do");
        }
        vm.startBroadcast(player);
        router.draw{value: total + 0.01 ether}(
            pool, IGameSync(_dep("game")), 10, budget == 0 ? 0 : syncCount, budget, 1, fee, 0, 1_000, v, block.timestamp + 1 hours
        );
        vm.stopBroadcast();
    }

    /// @notice The VRF coordinator delivers a word for the latest request (anvil only).
    function fulfillLatest(uint256 word) external {
        IFWAPool pool = IGameR(_dep("game")).pool();
        uint256 id = pool.requestIdAtSequence(pool.lastIssuedSequence());
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        vm.startBroadcast(IVrfR(VRF_SERVICE).s_vrfCoordinator());
        IVrfR(VRF_SERVICE).rawFulfillRandomWords(id, words);
        vm.stopBroadcast();
    }

    /// @notice The VRF coordinator delivers a word for the request at FWA sequence `seq` (anvil only).
    function fulfillSeq(uint64 seq, uint256 word) external {
        IFWAPool pool = IGameR(_dep("game")).pool();
        uint256 id = pool.requestIdAtSequence(seq);
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        vm.startBroadcast(IVrfR(VRF_SERVICE).s_vrfCoordinator());
        IVrfR(VRF_SERVICE).rawFulfillRandomWords(id, words);
        vm.stopBroadcast();
    }

    /// @notice Deploys the rehearsal's successor (test/utils/MigrationMocks.sol: holds the NFTs, counts capital and
    ///         trading fees). A stand-in: a real successor is a separately built pool system.
    function deploySuccessor(address deployer) external {
        vm.startBroadcast(deployer);
        MockSuccessor s =
            new MockSuccessor(_dep("collection"), _dep("vault"), 0x000000000004444c5dc75cB358380D2e3dE08A90);
        vm.stopBroadcast();
        console2.log("successor", address(s));
    }
}
