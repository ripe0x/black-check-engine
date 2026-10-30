// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {DeploySystem} from "../../script/DeploySystem.sol";
import {LaunchConfig} from "../../script/LaunchConfig.sol";
import {Swapper} from "./Venue.t.sol";
import {FwaFeeBuyer} from "../../src/periphery/FwaFeeBuyer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

interface IBal {
    function balanceOf(address) external view returns (uint256);
}

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

    /// The FWA creation fee is bought on FWA's own market straight into the controller, then the pool opens (no deal).
    function test_fwaFeeBoughtWithEthOpensThePool() public {
        Config memory c = _config();
        System memory s = deploySystem(c, address(this), address(this));
        FwaFeeBuyer buyer = new FwaFeeBuyer(c.poolManager, FWA_TOKEN);
        uint256 fee = c.fwaFactory.poolCreationFee();

        // Smallest ETH (to 0.0005) that buys the fee at the fork block.
        uint256 lo;
        uint256 hi = 5 ether;
        while (hi - lo > 0.0005 ether) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            vm.deal(address(this), mid);
            uint256 out = buyer.buyTo{value: mid}(makeAddr("probe"), 0);
            vm.revertToState(snap);
            if (out >= fee) hi = mid;
            else lo = mid;
        }
        emit log_named_decimal_uint("ETH to buy the 50,000 FWA creation fee", hi, 18);
        vm.deal(address(this), hi);
        buyer.buyTo{value: hi}(address(s.controller), fee);
        assertGe(IBal(FWA_TOKEN).balanceOf(address(s.controller)), fee);

        s.engine.openPool();
        assertEq(s.controller.pool().owner(), address(s.controller));
    }

    function check(System memory s, Config memory c) external view {
        postflight(s, c, address(this));
    }
}
