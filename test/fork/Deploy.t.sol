// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {DeploySystem} from "../../script/DeploySystem.sol";
import {LaunchConfig} from "../../script/LaunchConfig.sol";

/// @notice The production deployment routine and postflight on the pinned fork, with launch values.
contract DeployTest is ForkBase, DeploySystem {
    function _config() internal returns (Config memory c) {
        c = LaunchConfig.mainnet();
        c.council = makeAddr("council");
        c.guardian = makeAddr("guardian");
        c.operator = makeAddr("operator");
        c.coinRecipient = makeAddr("liquidity");
    }

    function test_deployAndPostflight() public {
        Config memory c = _config();
        System memory s = deploySystem(c, address(this));
        postflight(s, c, address(this));
    }

    function test_postflightRefusesUnsetRolesAndShortDelay() public {
        Config memory c = LaunchConfig.mainnet(); // roles left unset in the values file
        c.council = makeAddr("council");
        c.guardian = makeAddr("guardian");
        c.operator = c.council;
        c.coinRecipient = makeAddr("liquidity");
        System memory s = deploySystem(c, address(this));
        vm.expectRevert(abi.encodeWithSelector(Postflight.selector, "operator holds council or guardian"));
        this.check(s, c);
    }

    function check(System memory s, Config memory c) external view {
        postflight(s, c, address(this));
    }
}
