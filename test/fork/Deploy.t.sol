// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {DeploySystem} from "../../script/DeploySystem.sol";
import {LaunchConfig} from "../../script/LaunchConfig.sol";
import {Swapper} from "./Venue.t.sol";

/// @notice The production deployment routine and postflight on the pinned fork, with launch values.
contract DeployTest is ForkBase, DeploySystem {
    function _config() internal returns (Config memory c) {
        c = LaunchConfig.mainnet();
        c.council = makeAddr("council");
        c.guardian = makeAddr("guardian");
        c.operator = makeAddr("operator");
    }

    function test_deployAndPostflight() public {
        Config memory c = _config();
        System memory s = deploySystem(c, address(this), address(this));
        postflight(s, c, address(this));
    }

    function test_postflightRefusesUnsetRolesAndShortDelay() public {
        Config memory c = LaunchConfig.mainnet(); // roles left unset in the values file
        c.council = makeAddr("council");
        c.guardian = makeAddr("guardian");
        c.operator = c.council;
        System memory s = deploySystem(c, address(this), address(this));
        vm.expectRevert(abi.encodeWithSelector(Postflight.selector, "operator holds council or guardian"));
        this.check(s, c);
    }

    /// Coin fees fund acquisitions end to end: deploy through the production routine, open the market, trade, forward.
    function test_coinTradingFundsAcquisitions() public {
        Config memory c = _config();
        System memory s = deploySystem(c, address(this), address(this));
        postflight(s, c, address(this));
        s.liquidity.launch(161_200);
        Swapper swapper = new Swapper(c.poolManager, s.liquidity.poolKey());

        address trader = makeAddr("trader");
        vm.deal(trader, 2 ether);
        vm.prank(trader);
        (, uint256 coins) = swapper.buy{value: 2 ether}(2 ether, false);
        assertGt(coins, 0);
        assertEq(address(s.hook).balance, 0.02 ether, "1% of the ETH paid");

        s.hook.forward();
        assertEq(s.engine.acquisitionBudget(), 0.02 ether);
        assertEq(address(s.engine).balance, 0.02 ether);
    }

    function check(System memory s, Config memory c) external view {
        postflight(s, c, address(this));
    }
}
