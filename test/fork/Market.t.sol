// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {Swapper} from "../utils/Swapper.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {CollectionHook} from "../../src/token/CollectionHook.sol";
import {ProtocolLiquidity} from "../../src/token/ProtocolLiquidity.sol";
import {Governed} from "../../src/core/Governed.sol";
import {CollectionToken} from "../../src/token/CollectionToken.sol";
import {IVenuePolicy} from "../../src/interfaces/IVenuePolicy.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice The collection coin market on the real v4 PoolManager: single-sided launch, the opening fee curve (69% on
///         buys and sells, one point less a minute, D64), the ordinary 5% fee, fee routing to the vault, exempt
///         senders, unsupported routes, fee governance.
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

contract MarketForkTest is ForkBase {
    using StateLibrary for IPoolManager;

    address trader = makeAddr("trader");

    function setUp() public {
        deployChecks();
    }

    function _feeOf(uint256 eth) internal returns (uint256 fee) {
        uint256 before = feesPaid();
        buyCoin(trader, eth);
        fee = feesPaid() - before;
    }

    function test_launchIsSingleSidedAndPermanent() public {
        // the opening price is fixed at deployment; the owner's call takes none (final audit B-F6, D70)
        assertEq(sys.liquidity.startTick(), START_TICK);
        openMarket();
        assertTrue(sys.liquidity.launched());
        assertGt(sys.liquidity.coinLiquidity(), 0);
        // every coin is in the pool (dust burned), no ETH was needed
        assertEq(sys.token.balanceOf(address(sys.liquidity)), 0);
        assertEq(sys.token.balanceOf(cfg.poolManager) + (cfg.supply - sys.token.totalSupply()), cfg.supply);
        assertLt(cfg.supply - sys.token.totalSupply(), 1e12, "only rounding dust burned");
        (uint160 p,,,) = IPoolManager(cfg.poolManager).getSlot0(sys.liquidity.poolKey().toId());
        uint256 coinsPerEth = uint256(p) * uint256(p) / (1 << 192);
        assertApproxEqRel(coinsPerEth, 32_577_586, 2e16, "~32.6M coins per ETH: a ~30.7 ETH opening valuation (D70)");
        // launch only once, only the guardian
        vm.prank(owner);
        vm.expectRevert(ProtocolLiquidity.AlreadyLaunched.selector);
        sys.liquidity.launch();
    }

    /// Only the guardian opens the market, and no ETH can be sent with it: ETH above the start price could never be
    /// reached by a seller nor removed (D38). Exits are served by the ETH buyers put in, round trip within the fees.
    /// D91: the market opens only after the game's FWA pool exists, so the coin never trades before the deployment's
    /// last step.
    function test_launchWaitsForTheFwaPool() public {
        vm.prank(owner);
        vm.expectRevert(ProtocolLiquidity.NoFwaPool.selector);
        sys.liquidity.launch();
        assertFalse(sys.liquidity.launched());
        assertEq(sys.liquidity.poolOwner(), address(sys.poolOwner));
        createPool();
        vm.prank(owner);
        sys.liquidity.launch();
        assertTrue(sys.liquidity.launched());
    }

    function test_launchOnlyGuardianAndRefusesEth() public {
        createPool();
        vm.expectRevert(Governed.NotOwner.selector);
        sys.liquidity.launch();
        vm.deal(owner, 2 ether);
        vm.prank(owner);
        (bool ok,) = address(sys.liquidity).call{value: 2 ether}(
            abi.encodeCall(ProtocolLiquidity.launch, ())
        );
        assertFalse(ok, "not payable");
        vm.prank(owner);
        sys.liquidity.launch();
        assertEq(address(sys.liquidity).balance, 0);
        pastOpeningCurve();
        buyCoin(trader, 1 ether);
        uint256 bal = sys.token.balanceOf(trader);
        uint256 out = sellCoin(trader, bal);
        assertGt(out, 0.90 ether, "round trip costs the two 5% fees only");
    }

    /// The opening curve: 69% at launch, 100 bps less a minute (pro rata per second), down to the ordinary 5% at
    /// minute 64, and never again.
    function test_openingCurveOnBuysThenOrdinary() public {
        openMarket();
        uint256 t0 = sys.hook.launchedAt();
        assertEq(t0, block.timestamp);
        assertEq(_feeOf(1 ether), 0.69 ether, "minute 0: 69%");
        (uint256 b, uint256 sl, uint256 left) = sys.hook.openingFee();
        assertEq(b, 6_900);
        assertEq(sl, 6_900, "sells too");
        assertEq(left, 64 minutes, "64 minutes to the 5% fee");
        vm.warp(t0 + 30 seconds);
        assertEq(_feeOf(1 ether), 0.685 ether, "linear within the minute");
        vm.warp(t0 + 10 minutes);
        assertEq(_feeOf(1 ether), 0.59 ether, "minute 10: 59%");
        vm.warp(t0 + 30 minutes);
        assertEq(_feeOf(1 ether), 0.39 ether, "minute 30: 39%");
        vm.warp(t0 + 63 minutes);
        assertEq(_feeOf(1 ether), 0.06 ether, "minute 63: 6%");
        vm.warp(t0 + 64 minutes);
        assertEq(_feeOf(1 ether), 0.05 ether, "minute 64: the ordinary 5%");
        (,, left) = sys.hook.openingFee();
        assertEq(left, 0);
        vm.warp(t0 + 365 days);
        assertEq(_feeOf(1 ether), 0.05 ether, "never returns");
    }

    /// Sells pay the curve too: 69% of the gross ETH out at launch, the ordinary 5% after it.
    function test_openingCurveOnSells() public {
        openMarket();
        uint256 coins = buyCoin(trader, 2 ether);
        uint256 before = feesPaid();
        uint256 out = sellCoin(trader, coins / 4);
        uint256 fee = feesPaid() - before;
        assertApproxEqAbs(fee * 10_000 / (out + fee), 6_900, 1, "69% of the gross ETH out at launch");
        pastOpeningCurve();
        before = feesPaid();
        out = sellCoin(trader, coins / 4);
        fee = feesPaid() - before;
        assertApproxEqAbs(fee * 10_000 / (out + fee), 500, 1, "5% after");
    }

    /// An exact-output buy pays the same share of the gross ETH as an exact-input buy (`net × f / (1 − f)`), during
    /// the curve and after it, so exact output cannot be used to pay less.
    function test_exactOutputBuyPaysFeeOfTheGrossAndExactOutputSellIsUnsupported() public {
        openMarket();
        vm.deal(trader, 30 ether);
        uint256 before = feesPaid();
        vm.prank(trader);
        (uint256 ethIn, uint256 out) = swapper.buy{value: 10 ether}(1_000_000 ether, true);
        assertEq(out, 1_000_000 ether, "exact output");
        uint256 fee = feesPaid() - before;
        assertApproxEqAbs(fee * 10_000 / ethIn, 6_900, 1, "69% of the gross ETH paid at launch");
        pastOpeningCurve();
        before = feesPaid();
        vm.prank(trader);
        (ethIn,) = swapper.buy{value: 10 ether}(1_000_000 ether, true);
        fee = feesPaid() - before;
        assertApproxEqAbs(fee * 10_000 / ethIn, 500, 1, "5% of the gross ETH paid after the curve");
        vm.startPrank(trader);
        sys.token.approve(address(swapper), type(uint256).max);
        vm.expectRevert();
        swapper.sell(0.01 ether, true);
        vm.stopPrank();
    }

    function test_routerUsersAreNeverExempt() public {
        openMarket();
        pastOpeningCurve();
        // a second "aggregator" router: its users pay the fee like anyone else
        Swapper agg = new Swapper(IPoolManager(cfg.poolManager), sys.liquidity.poolKey());
        uint256 before = feesPaid();
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        agg.buy{value: 1 ether}(1 ether, false);
        assertEq(feesPaid() - before, 0.05 ether);
        assertFalse(sys.hook.exempt(address(agg)));
        assertFalse(sys.hook.exempt(address(swapper)));
        assertTrue(sys.hook.exempt(address(sys.burner)));
        assertEq(sys.hook.exemptSender(), address(sys.burner), "one immutable exempt sender");
    }

    function test_feeGovernanceByTheOwnerAndCapped() public {
        openMarket();
        vm.expectRevert(Governed.NotOwner.selector);
        sys.hook.setFees(100, 100);
        // above the 10% cap fails even for the owner
        vm.prank(owner);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.hook.setFees(1_001, 300);
        // within the cap, at once
        govern(address(sys.hook), abi.encodeCall(CollectionHook.setFees, (800, 200)));
        assertEq(sys.hook.buyFeeBps(), 800);
        assertEq(_feeOf(1 ether), 0.69 ether, "the curve is above any ordinary fee at launch");
        pastOpeningCurve();
        assertEq(_feeOf(1 ether), 0.08 ether);
    }

    function test_curveIsFixedAndOnlyAfterLaunch() public view {
        assertEq(sys.hook.LAUNCH_FEE_BPS(), 6_900);
        assertEq(sys.hook.LAUNCH_DECAY_BPS_PER_MINUTE(), 100);
        assertEq(sys.hook.curveBps(), 0, "before launch: no curve");
        assertEq(sys.hook.currentFeeBps(false), 500);
        assertEq(sys.hook.currentFeeBps(true), 500, "before launch: ordinary");
    }

    function test_feesFundTheVaultAtScale() public {
        openMarket();
        pastOpeningCurve();
        address[3] memory traders = [makeAddr("a"), makeAddr("b"), makeAddr("c")];
        uint256 vol;
        for (uint256 i; i < 30; ++i) {
            address t = traders[i % 3];
            uint256 coins = buyCoin(t, 0.5 ether);
            vol += 0.5 ether;
            if (i % 2 == 0) vol += sellCoin(t, coins / 2);
        }
        assertApproxEqRel(sys.vault.tradingFees(), vol * 500 / 10_000, 3e16);
        assertEq(address(sys.vault).balance, sys.vault.tradingFees());
    }

    /// D71: the coin moves only through the canonical pool. Buys and sells work; a transfer between holders, or into
    /// the PoolManager without a canonical swap (a side pool's settlement), reverts; the hook alone grants allowance.
    function test_coinTradesOnlyInTheCanonicalPool() public {
        openMarket();
        pastOpeningCurve();
        uint256 coins = buyCoin(trader, 1 ether);
        assertGt(coins, 0);
        address friend = makeAddr("friend");
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IVenuePolicy.VenueNotAllowed.selector, friend, bytes32(0), true));
        sys.token.transfer(friend, 1);
        // a side pool settles by sending coin to the PoolManager: no canonical swap, no allowance
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IVenuePolicy.VenueNotAllowed.selector, cfg.poolManager, bytes32(0), true));
        sys.token.transfer(cfg.poolManager, 1);
        vm.prank(trader);
        vm.expectRevert(CollectionToken.NotHook.selector);
        sys.token.allowSwapTransfer(1);
        // selling back through the canonical pool works, and burning always does
        assertGt(sellCoin(trader, coins / 2), 0);
        vm.prank(trader);
        sys.token.burn(1);
    }

    /// D71 (final audit round 2, F1): a buy and a sell that cancel inside one unlock leave no allowance, so they
    /// cannot carry a holder-to-holder transfer through the PoolManager (sync, transferFrom in, settle, take out).
    function test_roundTripCannotRelayAHolderTransfer() public {
        openMarket();
        pastOpeningCurve();
        uint256 coins = buyCoin(trader, 1 ether);
        address friend = makeAddr("friend");
        RoundTrip rt = new RoundTrip(IPoolManager(cfg.poolManager), sys.token, sys.liquidity.poolKey());
        vm.prank(trader);
        sys.token.approve(address(rt), coins / 4);
        vm.deal(address(rt), 3 ether);
        vm.expectRevert(abi.encodeWithSelector(IVenuePolicy.VenueNotAllowed.selector, cfg.poolManager, bytes32(0), true));
        rt.run(trader, friend, coins / 4, 2);
        assertEq(sys.token.balanceOf(friend), 0);
    }

    /// D71: several canonical swaps in one unlock settle on their net coin: buy, sell half back, take the rest.
    function test_netOfSeveralSwapsInOneUnlockSettles() public {
        openMarket();
        pastOpeningCurve();
        RoundTrip rt = new RoundTrip(IPoolManager(cfg.poolManager), sys.token, sys.liquidity.poolKey());
        vm.deal(address(rt), 3 ether);
        rt.run(address(0), address(rt), 0, 1);
        assertGt(sys.token.balanceOf(address(rt)), 0, "the net bought coin was taken");
        // and nothing more can leave: the allowance was used up exactly
        assertTrue(sys.token.restricted());
    }

    /// D71: the Admin owner lifts the restriction once and for good; the URC-5 declaration follows it.
    function test_unrestrictAndVenuePolicy() public {
        openMarket();
        pastOpeningCurve();
        CollectionToken t = sys.token;
        PoolKey memory key = sys.liquidity.poolKey();
        bytes32 id = PoolId.unwrap(sys.hook.poolId());
        assertTrue(t.supportsInterface(type(IVenuePolicy).interfaceId));
        assertTrue(t.supportsInterface(0x01ffc9a7));
        assertEq(uint8(t.venueEnforcement()), uint8(IVenuePolicy.VenueEnforcement.Enforced));
        PoolKey[] memory keys = t.canonicalPools();
        assertEq(keys.length, 1);
        assertEq(keccak256(abi.encode(keys[0])), keccak256(abi.encode(key)));
        assertTrue(t.venueAllowed(cfg.poolManager, id, true) && t.venueAllowed(cfg.poolManager, id, false));
        assertFalse(t.venueAllowed(cfg.poolManager, bytes32(0), true));
        assertFalse(t.venueAllowed(makeAddr("v2pair"), bytes32(0), true));
        (bool inR, bool outR, IVenuePolicy.ExternalVenue[] memory ext) = t.externalVenues();
        assertTrue(inR && outR);
        assertEq(ext.length, 0);
        // only the council, once
        vm.expectRevert(CollectionToken.NotCouncil.selector);
        t.unrestrict();
        vm.prank(owner);
        vm.expectRevert(CollectionToken.NotCouncil.selector); // D012: the council's, not the owner's
        t.unrestrict();
        vm.prank(council);
        vm.expectEmit(address(t));
        emit IVenuePolicy.VenueEnforcementChanged(IVenuePolicy.VenueEnforcement.Preferred);
        t.unrestrict();
        assertFalse(t.restricted());
        vm.prank(council);
        vm.expectRevert(CollectionToken.NotRestricted.selector);
        t.unrestrict();
        assertEq(uint8(t.venueEnforcement()), uint8(IVenuePolicy.VenueEnforcement.Preferred));
        assertTrue(t.venueAllowed(makeAddr("v2pair"), bytes32(0), true));
        (inR, outR,) = t.externalVenues();
        assertFalse(inR || outR);
        // holders transfer freely now
        uint256 coins = buyCoin(trader, 1 ether);
        vm.prank(trader);
        t.transfer(makeAddr("friend"), coins);
        assertEq(t.balanceOf(makeAddr("friend")), coins);
    }

    struct ExactInputSingle {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    /// The site's swap (site/app/lib/swap.ts): Uniswap's Universal Router, SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL.
    function _routerSwap(address who, bool buy, uint256 amountIn) internal {
        PoolKey memory key = sys.liquidity.poolKey();
        (address cin, address cout) = buy
            ? (address(0), address(sys.token))
            : (address(sys.token), address(0));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingle(key, buy, uint128(amountIn), 0, ""));
        params[1] = abi.encode(cin, amountIn);
        params[2] = abi.encode(cout, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f)), params);
        vm.prank(who);
        IUniversalRouter(UNIVERSAL_ROUTER).execute{value: buy ? amountIn : 0}(
            abi.encodePacked(uint8(0x10)), inputs, block.timestamp + 900
        );
    }

    /// D71: players' real route, Uniswap's Universal Router with Permit2 on sells, passes the restriction.
    function test_universalRouterBuyAndSellWhileRestricted() public {
        openMarket();
        pastOpeningCurve();
        vm.deal(trader, 1 ether);
        _routerSwap(trader, true, 1 ether);
        uint256 coins = sys.token.balanceOf(trader);
        assertGt(coins, 0, "bought through the router");
        vm.startPrank(trader);
        sys.token.approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(address(sys.token), UNIVERSAL_ROUTER, type(uint160).max, uint48(block.timestamp + 1800));
        vm.stopPrank();
        uint256 ethBefore = trader.balance;
        _routerSwap(trader, false, coins);
        assertEq(sys.token.balanceOf(trader), 0, "sold through the router");
        assertGt(trader.balance, ethBefore);
    }
}

/// @dev One unlock with two canonical swaps. mode 1: buy 1 ETH, sell half back, take the net coin. mode 2: buy 1 ETH,
///      sell it all back, then try to relay `amount` from `source` to `dest` through the PoolManager.
contract RoundTrip is IUnlockCallback {
    IPoolManager immutable pm;
    CollectionToken immutable coin;
    PoolKey key;
    address source;
    address dest;
    uint256 amount;
    uint256 mode;

    constructor(IPoolManager pm_, CollectionToken coin_, PoolKey memory key_) {
        (pm, coin, key) = (pm_, coin_, key_);
    }

    function run(address source_, address dest_, uint256 amount_, uint256 mode_) external {
        (source, dest, amount, mode) = (source_, dest_, amount_, mode_);
        pm.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        BalanceDelta b = pm.swap(key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), "");
        uint256 bought = uint256(int256(b.amount1()));
        uint256 back = mode == 1 ? bought / 2 : bought;
        BalanceDelta s = pm.swap(key, SwapParams(false, -int256(back), TickMath.MAX_SQRT_PRICE - 1), "");
        if (mode == 1) {
            pm.take(key.currency1, dest, bought - back);
        } else {
            pm.sync(key.currency1);
            coin.transferFrom(source, address(pm), amount);
            pm.settle();
            pm.take(key.currency1, dest, amount);
        }
        pm.settle{value: uint256(-int256(b.amount0()) - int256(s.amount0()))}();
        return "";
    }

    receive() external payable {}
}
