// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {LaunchConfig} from "./LaunchConfig.sol";

/// @notice Deploys Ape Draw (coin, game, MigrationAuthority), wires it, runs the postflight and writes
///         `deployments/<DEPLOY_ENV>.json`.
///         Never run against mainnet from an automated session; use `script/deploy.sh <env>` (dry run by default).
/// @dev Environment (values only, see script/env/*.env):
///      OWNER                   the administrator (Admin.owner: two-step transferable, renounceable)
///      COLLECTION              "bayc" (the launch config)
///      COIN_NAME, COIN_SYMBOL  coin identity (placeholders in LaunchConfig if unset)
///      REF_PRICE_WEI           the reference price: the live floor on the day; the live bid's first activation
///                              threshold is 100% of it (OWNER; D64)
///      MAX_PRICE_WEI           optional emergency cap on any acquisition (default 0: none)
///      CREATE2_FACTORY         deterministic deployment proxy (default 0x4e59b44847b379578588920cA78FbF26c0B4956C)
contract Deploy is Script, LaunchConfig {
    address internal constant DEFAULT_CREATE2 = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external virtual returns (System memory s) {
        Config memory c = _envConfig();
        address deployer = msg.sender;
        // a real broadcast to mainnet needs the owner's affirmation here too, not only in deploy.sh (a direct
        // `forge script --broadcast` skips the shell)
        if (block.chainid == 1 && vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            require(keccak256(bytes(vm.envOr("I_AM_THE_OWNER", string("")))) == keccak256("yes"), "I_AM_THE_OWNER=yes");
        }
        vm.startBroadcast(deployer);
        s = _deploySystem(c, deployer);
        vm.stopBroadcast();
        postflight(c, s, deployer);
        _write(s, c);
        console2.log("deployed; postflight passed");
    }

    function _envConfig() internal view virtual returns (Config memory c) {
        address owner = vm.envAddress("OWNER");
        string memory which = vm.envOr("COLLECTION", string("bayc"));
        if (keccak256(bytes(which)) == keccak256("bayc")) {
            c = _baycConfig(owner);
        } else {
            c = _collectionConfig(owner, vm.parseAddress(which), "Collection Game Coin", "CGC");
        }
        c.name = vm.envOr("COIN_NAME", c.name);
        c.symbol = vm.envOr("COIN_SYMBOL", c.symbol);
        c.coinImage = vm.envOr("COIN_IMAGE", c.coinImage);
        c.coinDescription = vm.envOr("COIN_DESCRIPTION", c.coinDescription);
        c.refPrice = vm.envOr("REF_PRICE_WEI", c.refPrice);
        c.bid.maxPrice = vm.envOr("MAX_PRICE_WEI", c.bid.maxPrice);
        c.initialBoardSize = vm.envOr("INITIAL_BOARD_SIZE", c.initialBoardSize); // rehearsals only; launch: 50
        c.create2Deployer = vm.envOr("CREATE2_FACTORY", DEFAULT_CREATE2);
        require(c.refPrice != 0 && (c.bid.maxPrice == 0 || c.bid.maxPrice >= c.refPrice), "bid prices");
        // the environment named must be the chain connected: never mainnet values on a fork, nor fork values on mainnet
        bool mainnetEnv = keccak256(bytes(vm.envOr("DEPLOY_ENV", string("local")))) == keccak256("mainnet");
        require(mainnetEnv == (block.chainid == 1), "DEPLOY_ENV does not match the chain");
    }

    function _write(System memory s, Config memory c) internal {
        string memory env = vm.envOr("DEPLOY_ENV", string("local"));
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "block", block.number);
        vm.serializeAddress(k, "owner", c.owner);
        vm.serializeAddress(k, "admin", address(s.admin));
        vm.serializeAddress(k, "collection", c.collection);
        vm.serializeAddress(k, "migration", address(s.migration));
        vm.serializeAddress(k, "liquidity", address(s.liquidity));
        vm.serializeAddress(k, "token", address(s.token));
        vm.serializeAddress(k, "burner", address(s.burner));
        vm.serializeAddress(k, "vault", address(s.vault));
        vm.serializeAddress(k, "hook", address(s.hook));
        vm.serializeAddress(k, "poolOwner", address(s.poolOwner));
        vm.serializeAddress(k, "sunset", address(s.sunset));
        vm.serializeAddress(k, "adapter", address(s.adapter));
        vm.serializeAddress(k, "lens", address(s.lens));
        vm.serializeAddress(k, "drawRouter", address(s.drawRouter));
        vm.serializeAddress(k, "packs", s.packs);
        vm.serializeAddress(k, "packRenderer", s.packRenderer);
        vm.serializeAddress(k, "layerTap", s.layerTap);
        vm.serializeAddress(k, "deployer", msg.sender);
        string memory out = vm.serializeAddress(k, "game", address(s.game));
        vm.writeJson(out, string.concat("deployments/", env, ".json"));
    }
}
