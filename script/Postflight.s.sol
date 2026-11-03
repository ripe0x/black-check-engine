// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {Deploy} from "./Deploy.s.sol";

/// @notice Re-runs the postflight against a live deployment from `deployments/<DEPLOY_ENV>.json` and the same
///         environment the deployment used. Read only. `DEPLOYER` is the address that deployed (its powers must be gone).
contract Postflight is Deploy {
    function check() external view {
        Config memory c = _envConfig();
        string memory json = vm.readFile(string.concat("deployments/", vm.envOr("DEPLOY_ENV", string("local")), ".json"));
        System memory s;
        s.admin = AdminT(vm.parseJsonAddress(json, ".admin"));
        s.migration = MigrationAuthorityT(vm.parseJsonAddress(json, ".migration"));
        s.liquidity = ProtocolLiquidityT(payable(vm.parseJsonAddress(json, ".liquidity")));
        s.token = CollectionTokenT(vm.parseJsonAddress(json, ".token"));
        s.burner = CollectionBurnerT(payable(vm.parseJsonAddress(json, ".burner")));
        s.vault = FundingVaultT(payable(vm.parseJsonAddress(json, ".vault")));
        s.hook = CollectionHookT(vm.parseJsonAddress(json, ".hook"));
        s.poolOwner = CollectionPoolOwnerT(payable(vm.parseJsonAddress(json, ".poolOwner")));
        s.sunset = SunsetT(payable(vm.parseJsonAddress(json, ".sunset")));
        s.adapter = SeaportAdapterT(payable(vm.parseJsonAddress(json, ".adapter")));
        s.game = CollectionGameT(payable(vm.parseJsonAddress(json, ".game")));
        s.packs = vm.parseJsonAddress(json, ".packs");
        s.packRenderer = vm.parseJsonAddress(json, ".packRenderer");
        s.layerTap = vm.parseJsonAddress(json, ".layerTap");
        s.lens = LensT(vm.parseJsonAddress(json, ".lens"));
        s.drawRouter = DrawRouterT(payable(vm.parseJsonAddress(json, ".drawRouter")));
        postflight(c, s, vm.envAddress("DEPLOYER"));
        console2.log("postflight passed");
    }
}

import {Admin as AdminT} from "../src/core/Admin.sol";
import {ProtocolLiquidity as ProtocolLiquidityT} from "../src/token/ProtocolLiquidity.sol";
import {CollectionToken as CollectionTokenT} from "../src/token/CollectionToken.sol";
import {CollectionBurner as CollectionBurnerT} from "../src/treasury/CollectionBurner.sol";
import {FundingVault as FundingVaultT} from "../src/core/FundingVault.sol";
import {CollectionHook as CollectionHookT} from "../src/token/CollectionHook.sol";
import {CollectionPoolOwner as CollectionPoolOwnerT} from "../src/core/CollectionPoolOwner.sol";
import {Sunset as SunsetT} from "../src/migration/Sunset.sol";
import {SeaportAdapter as SeaportAdapterT} from "../src/periphery/SeaportAdapter.sol";
import {MigrationAuthority as MigrationAuthorityT} from "../src/migration/MigrationAuthority.sol";
import {CollectionGame as CollectionGameT} from "../src/game/CollectionGame.sol";
import {Lens as LensT} from "../src/periphery/Lens.sol";
import {DrawRouter as DrawRouterT} from "../src/periphery/DrawRouter.sol";
