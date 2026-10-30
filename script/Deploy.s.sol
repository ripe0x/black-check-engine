// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {DeploySystem} from "./DeploySystem.sol";
import {LaunchConfig} from "./LaunchConfig.sol";

/// @notice Deploys the system with the launch values and runs the postflight. Simulation by default:
///           COUNCIL=0x.. GUARDIAN=0x.. OPERATOR=0x.. LIQUIDITY=0x.. COIN_NAME=.. COIN_SYMBOL=.. \
///           forge script script/Deploy.s.sol --rpc-url https://mainnet.gateway.tenderly.co --sender <deployer>
///         Broadcasting additionally needs I_AM_THE_OWNER=yes and is not authorized by anything in this repository.
///         Opening the FWA pool (the 50,000 FWA creation fee) and the coin venue are separate, later steps.
contract Deploy is Script, DeploySystem {
    function run() external returns (System memory s) {
        Config memory c = LaunchConfig.mainnet();
        c.council = vm.envAddress("COUNCIL");
        c.guardian = vm.envAddress("GUARDIAN");
        c.operator = vm.envAddress("OPERATOR");
        c.coinRecipient = vm.envAddress("LIQUIDITY");
        c.coinName = vm.envString("COIN_NAME");
        c.coinSymbol = vm.envString("COIN_SYMBOL");
        require(keccak256(bytes(c.coinSymbol)) != keccak256("BLACK"), "placeholder ticker: choose a distinct public name");
        require(block.chainid == 1, "mainnet values");
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            require(keccak256(bytes(vm.envOr("I_AM_THE_OWNER", string("")))) == keccak256("yes"), "owner ack");
        }

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        s = deploySystem(c, deployer);
        vm.stopBroadcast();
        postflight(s, c, deployer);
        console2.log("timelock", address(s.timelock));
        console2.log("coin", address(s.coin));
        console2.log("engine", address(s.engine));
        console2.log("controller", address(s.controller));
        console2.log("pool (predicted)", address(s.controller.pool()));
    }
}
