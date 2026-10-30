// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {DeploySystem} from "../../script/DeploySystem.sol";
import {LaunchConfig} from "../../script/LaunchConfig.sol";
import {Swapper} from "./Venue.t.sol";
import {FwaFeeBuyer} from "../../src/periphery/FwaFeeBuyer.sol";
import {Burner, IVenue} from "../../src/treasury/Burner.sol";
import {Engine} from "../../src/core/Engine.sol";
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

    /// An unset opening tick (0, one coin per ETH) is refused before the market can open.
    function test_postflightRefusesUnsetOpeningTick() public {
        Config memory c = _config();
        c.venueStartTick = 0;
        System memory s = deploySystem(c, address(this), address(this));
        vm.expectRevert(abi.encodeWithSelector(Postflight.selector, "opening price"));
        this.check(s, c);
    }

    /// Coin fees fund acquisitions end to end: deploy through the production routine, open the market, trade, forward.
    function test_coinTradingFundsAcquisitions() public {
        Config memory c = _config();
        System memory s = deploySystem(c, address(this), address(this));
        postflight(s, c, address(this));
        s.liquidity.launch();
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

    /// Game surplus above the acquisition budget and the reserve is released daily and burned as coin bought on the venue.
    function test_surplusBuysAndBurnsCoin() public {
        Config memory c = _config();
        System memory s = deploySystem(c, address(this), address(this));
        vm.expectRevert(Burner.NotLaunched.selector);
        new Burner(IVenue(address(s.liquidity)), 0.1 ether, 1 days);
        s.liquidity.launch();
        vm.expectRevert(Burner.Nothing.selector);
        new Burner(IVenue(address(s.liquidity)), 0, 1 days);
        Burner burner = new Burner(IVenue(address(s.liquidity)), 0.1 ether, 1 days);

        bytes memory data = abi.encodeCall(Engine.setBurner, (address(burner), uint128(0.5 ether)));
        vm.prank(c.council);
        s.timelock.schedule(address(s.engine), 0, data, bytes32(0), bytes32(0), c.delay);
        vm.warp(vm.getBlockTimestamp() + c.delay);
        s.timelock.execute(address(s.engine), 0, data, bytes32(0), bytes32(0));

        vm.deal(address(this), 0.3 ether);
        s.engine.fundAcquisitions{value: 0.3 ether}();
        vm.deal(address(s.engine), address(s.engine).balance + 1 ether); // game capital (stands in for FWA proceeds)

        assertEq(s.engine.releaseSurplus(), 0.5 ether, "1.3 held - 0.3 budget - 0.5 reserve");
        assertEq(s.engine.acquisitionBudget(), 0.3 ether);
        vm.expectRevert(Engine.NotAllowed.selector);
        s.engine.releaseSurplus(); // once a day

        uint256 supply = s.coin.totalSupply();
        (uint256 ethIn, uint256 burned) = burner.burn();
        assertEq(ethIn, 0.1 ether, "one capped chunk");
        assertGt(burned, 0);
        assertEq(supply - s.coin.totalSupply(), burned);
        assertEq(s.coin.balanceOf(address(burner)), 0);
        vm.expectRevert(Burner.TooSoon.selector);
        burner.burn();
        // The venue fee on the burner's buy (1%) went to acquisitions once forwarded.
        s.hook.forward();
        assertEq(s.engine.acquisitionBudget(), 0.3 ether + 0.001 ether);
    }

    function check(System memory s, Config memory c) external view {
        postflight(s, c, address(this));
    }
}
