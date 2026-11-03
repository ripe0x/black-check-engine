// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {CollectionHook} from "../../src/token/CollectionHook.sol";
import {LayerTap} from "../../src/periphery/LayerTap.sol";
import {Governed} from "../../src/core/Governed.sol";

interface ILayerRouter {
    function processBurnWeth(uint256 minLayerOut) external returns (uint256 wethIn, uint256 layerBurned);
}

interface ISupply {
    function totalSupply() external view returns (uint256);
}

/// @dev A router that reports the $LAYER token but refuses ETH.
contract RefusingRouter {
    address public immutable layerToken;

    constructor(address t) {
        layerToken = t;
    }

    receive() external payable {
        revert("no");
    }
}

/// @notice D90: the hook takes 1% of each trading fee once the opening curve is down to the ordinary fee and pays it
///         to the LayerTap, which forwards it (anyone calls `flush`) to artcoins' $LAYER burn router; the rest of the
///         fee goes to the vault. The owner sets the share (0-5%) and the tap.
contract LayerShareForkTest is ForkBase {
    address constant LAYER_ROUTER = 0x2eDBdF011768d8cd4Ef537658b41440900C52000;
    address constant LAYER = 0xb7287e4A5b605aB92A8589C62af8A4ebD347E6c9;
    address alice = makeAddr("layer.alice");
    LayerTap tap;

    function setUp() public {
        deployBayc();
        openMarket();
        tap = LayerTap(payable(sys.layerTap));
    }

    function test_launchValues() public view {
        assertEq(sys.hook.layerBps(), 100, "1% of each fee");
        assertEq(sys.hook.layerTap(), address(tap));
        assertEq(tap.router(), LAYER_ROUTER);
        assertEq(tap.layerToken(), LAYER);
        assertEq(sys.hook.MAX_LAYER_BPS(), 500);
    }

    /// During the opening curve the whole fee goes to the vault.
    function test_noShareDuringTheCurve() public {
        uint256 before = sys.vault.tradingFees();
        buyCoin(alice, 1 ether);
        assertGt(sys.vault.tradingFees() - before, 0.5 ether, "the curve's fee, all to the vault");
        assertEq(address(tap).balance, 0);
    }

    /// After the curve, every fee is split at the swap: 1% to the tap, the rest to the vault, buys and sells alike.
    function test_shareOfEveryFeeAfterTheCurve() public {
        pastOpeningCurve();
        uint256 v0 = sys.vault.tradingFees();
        uint256 out = buyCoin(alice, 4 ether); // a 0.002 ETH share: it stays in the tap
        uint256 toVault = sys.vault.tradingFees() - v0;
        uint256 toTap = address(tap).balance;
        uint256 fee = 4 ether * sys.hook.buyFeeBps() / 10_000;
        assertEq(toVault + toTap, fee, "the whole fee");
        assertEq(toTap, fee * 100 / 10_000, "1% of it");
        // a sell pays its fee in ETH the same way
        uint256 v1 = sys.vault.tradingFees();
        uint256 t1 = address(tap).balance;
        sellCoin(alice, out / 2);
        uint256 sellToVault = sys.vault.tradingFees() - v1;
        uint256 sellToTap = address(tap).balance - t1;
        assertGt(sellToTap, 0);
        assertEq(sellToTap, (sellToVault + sellToTap) * 100 / 10_000, "1% of the sell's fee");
        assertBooks();
    }

    /// The tap forwards by itself once it holds the router's 0.01 ETH minimum, and the router really buys and burns
    /// $LAYER with it; below the minimum it waits, and anyone can flush it.
    function test_tapForwardsAndRouterBurnsLayer() public {
        pastOpeningCurve();
        uint256 routerBefore = LAYER_ROUTER.balance;
        buyCoin(alice, 1 ether); // a 0.0005 ETH share: below the minimum, it waits
        assertEq(address(tap).balance, 0.0005 ether);
        assertEq(LAYER_ROUTER.balance, routerBefore);
        for (uint256 i; i < 10; ++i) {
            buyCoin(alice, 20 ether);
        }
        assertLt(address(tap).balance, tap.FORWARD_AT(), "forwarded as it reached the minimum");
        assertGt(LAYER_ROUTER.balance - routerBefore, 0.09 ether);
        uint256 held = address(tap).balance;
        if (held != 0) assertEq(tap.flush(), held); // anyone sends the rest
        vm.expectRevert(LayerTap.NothingToFlush.selector);
        tap.flush();
        uint256 supply = ISupply(LAYER).totalSupply();
        vm.roll(block.number + 1);
        // a keeper passes at least the router's own price floor (it reverts `MinLayerOutBelowFloor(min, floor)` below it)
        (bool ok, bytes memory ret) = LAYER_ROUTER.call(abi.encodeCall(ILayerRouter.processBurnWeth, (0)));
        assertFalse(ok);
        uint256 floor;
        assembly ("memory-safe") {
            floor := mload(add(ret, 68))
        }
        (, uint256 burned) = ILayerRouter(LAYER_ROUTER).processBurnWeth(floor);
        assertGt(burned, 0);
        assertEq(ISupply(LAYER).totalSupply(), supply - burned, "LAYER burned");
    }

    /// The owner sets the share (at most 5%, 0 turns it off) and the tap (a contract); nobody else can.
    function test_ownerSetsShareAndTap() public {
        vm.prank(alice);
        vm.expectRevert();
        sys.hook.setLayer(address(tap), 200);
        vm.startPrank(owner);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.hook.setLayer(address(tap), 501);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.hook.setLayer(makeAddr("layer.eoa"), 100);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.hook.setLayer(address(0), 100);
        sys.hook.setLayer(address(tap), 500);
        assertEq(sys.hook.layerBps(), 500);
        LayerTap other = new LayerTap(LAYER_ROUTER);
        sys.hook.setLayer(address(other), 100);
        assertEq(sys.hook.layerTap(), address(other));
        sys.hook.setLayer(address(0), 0); // off
        vm.stopPrank();
        pastOpeningCurve();
        uint256 v0 = sys.vault.tradingFees();
        buyCoin(alice, 20 ether);
        assertEq(sys.vault.tradingFees() - v0, 20 ether * sys.hook.buyFeeBps() / 10_000, "all to the vault when off");
    }

    /// A router that refuses ETH never blocks trading: the share waits in the tap.
    function test_refusingRouterNeverBlocksTrading() public {
        LayerTap stuck = new LayerTap(address(new RefusingRouter(LAYER)));
        vm.prank(owner);
        sys.hook.setLayer(address(stuck), 100);
        pastOpeningCurve();
        buyCoin(alice, 20 ether);
        assertGt(address(stuck).balance, 0, "trading went on");
        vm.expectRevert();
        stuck.flush();
        assertGt(address(stuck).balance, 0, "the share waits");
    }

    /// A tap needs a router that reports a $LAYER token.
    function test_tapNeedsARouter() public {
        vm.expectRevert(LayerTap.NotARouter.selector);
        new LayerTap(makeAddr("layer.notarouter"));
    }
}
