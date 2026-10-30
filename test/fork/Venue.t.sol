// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {Coin} from "../../src/token/Coin.sol";
import {Engine, IShapesBacking, ICoinBurn} from "../../src/core/Engine.sol";
import {IController} from "../../src/interfaces/IController.sol";
import {VenueLiquidity} from "../../src/venue/VenueLiquidity.sol";
import {VenueHook, IFundAcquisitions} from "../../src/venue/VenueHook.sol";

/// @notice A plain public test router: any user swapping through it is an ordinary sender (the hook has no exemptions).
///         (Provenance: collection-games test/utils/Swapper.sol, MIT.)
contract Swapper is IUnlockCallback {
    IPoolManager public immutable pm;
    PoolKey internal _key;

    constructor(IPoolManager pm_, PoolKey memory key_) {
        pm = pm_;
        _key = key_;
    }

    /// @dev Buy the coin with exact ETH input (`exactOut` false) or for an exact coin output.
    function buy(uint256 amount, bool exactOut) external payable returns (uint256 ethIn, uint256 coinOut) {
        (ethIn, coinOut) = abi.decode(pm.unlock(abi.encode(msg.sender, true, amount, exactOut)), (uint256, uint256));
        if (address(this).balance != 0) SafeTransferLib.forceSafeTransferETH(msg.sender, address(this).balance);
    }

    /// @dev Sell exact coin input (or, for the revert test, exact ETH output). Caller approves first.
    function sell(uint256 amount, bool exactOut) external returns (uint256 coinIn, uint256 ethOut) {
        (coinIn, ethOut) = abi.decode(pm.unlock(abi.encode(msg.sender, false, amount, exactOut)), (uint256, uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address user, bool isBuy, uint256 amount, bool exactOut) = abi.decode(data, (address, bool, uint256, bool));
        int256 specified = exactOut ? int256(amount) : -int256(amount);
        BalanceDelta d = pm.swap(
            _key,
            SwapParams({
                zeroForOne: isBuy,
                amountSpecified: specified,
                sqrtPriceLimitX96: isBuy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 a0 = d.amount0();
        int128 a1 = d.amount1();
        if (isBuy) {
            pm.settle{value: uint256(int256(-a0))}();
            pm.take(_key.currency1, user, uint256(int256(a1)));
            return abi.encode(uint256(int256(-a0)), uint256(int256(a1)));
        }
        pm.sync(_key.currency1);
        SafeTransferLib.safeTransferFrom(Currency.unwrap(_key.currency1), user, address(pm), uint256(int256(-a1)));
        pm.settle();
        pm.take(_key.currency0, user, uint256(int256(a0)));
        return abi.encode(uint256(int256(-a1)), uint256(int256(a0)));
    }

    receive() external payable {}
}

/// @notice The protocol coin's trading venue on the real mainnet Uniswap v4 PoolManager: single-sided locked launch,
///         a flat 1% ETH fee on buys and sells collected by the hook, permissionless forwarding of that ETH to the
///         Engine's `fundAcquisitions` (crediting `acquisitionBudget`), and the absence of any withdraw or
///         fee-redirect path. The Engine is the real contract behind an ERC1967 proxy (initialised with a dummy
///         controller and no pool, since `fundAcquisitions` is unguarded and `initialize` only stores the controller
///         address): this exercises the real `acquisitionBudget` accounting without the orthogonal FWA pool wiring.
contract VenueForkTest is ForkBase {
    using StateLibrary for IPoolManager;

    IPoolManager internal constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant FEE_BPS = 100; // 1% placeholder (founder decision pending)
    int24 internal constant START_TICK = 161_200; // ~10M coins per ETH, a ~100 ETH opening valuation

    address internal operator = makeAddr("operator");
    address internal guardian = makeAddr("guardian");
    address internal trader = makeAddr("trader");

    Coin internal coin;
    Engine internal engine;
    VenueLiquidity internal liq;
    VenueHook internal hook;
    Swapper internal swapper;

    function setUp() public override {
        super.setUp();
        coin = new Coin("Placeholder Coin", "BLACK", SUPPLY, address(this));
        engine = _deployEngine();
        liq = new VenueLiquidity(PM, address(coin), START_TICK, makeAddr("timelock")); // deployer = this test contract
        hook = _mineAndDeployHook();
        liq.wire(address(hook));
        coin.transfer(address(liq), SUPPLY);
        swapper = new Swapper(PM, liq.poolKey());
    }

    // ------------------------------------------------------------------ deploy helpers

    function _deployEngine() internal returns (Engine e) {
        Engine impl = new Engine(CHECKS, EDITIONS, IShapesBacking(SHAPES), ICoinBurn(address(coin)));
        e = Engine(
            payable(
                address(
                    new ERC1967Proxy(
                        address(impl),
                        abi.encodeCall(
                            Engine.initialize,
                            (
                                address(this),
                                operator,
                                guardian,
                                IController(makeAddr("controller")),
                                _tiers(),
                                _thresholds(),
                                _composeBurn(),
                                _coinPrice(),
                                _params()
                            )
                        )
                    )
                )
            )
        );
    }

    /// @dev CREATE2-mine a hook address carrying this hook's permission flags, then deploy it (from this contract).
    function _mineAndDeployHook() internal returns (VenueHook h) {
        bytes memory initCode = abi.encodePacked(
            type(VenueHook).creationCode,
            abi.encode(PM, address(coin), address(liq), IFundAcquisitions(address(engine)), FEE_BPS)
        );
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes32 initHash = keccak256(initCode);
        bytes32 salt;
        address predicted;
        for (uint256 i; i < 200_000; ++i) {
            salt = bytes32(i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == flags && predicted.code.length == 0) break;
        }
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(deployed == predicted, "hook address");
        h = VenueHook(payable(deployed));
    }

    function openMarket() internal {
        liq.launch();
    }

    function buyCoin(address who, uint256 eth) internal returns (uint256 out) {
        vm.deal(who, who.balance + eth);
        vm.prank(who);
        (, out) = swapper.buy{value: eth}(eth, false);
    }

    function sellCoin(address who, uint256 amount) internal returns (uint256 ethOut) {
        vm.startPrank(who);
        coin.approve(address(swapper), amount);
        (, ethOut) = swapper.sell(amount, false);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ tests

    function test_launchLocksFullSupplyPermanently() public {
        openMarket();
        assertTrue(liq.launched());
        assertGt(liq.coinLiquidity(), 0);
        // every coin is in the pool (dust burned); no ETH was needed or accepted
        assertEq(coin.balanceOf(address(liq)), 0);
        assertEq(address(liq).balance, 0);
        assertEq(coin.balanceOf(address(PM)) + (SUPPLY - coin.totalSupply()), SUPPLY);
        assertLt(SUPPLY - coin.totalSupply(), 1e12, "only rounding dust burned");
        (uint160 p,,,) = PM.getSlot0(liq.poolKey().toId());
        uint256 coinsPerEth = uint256(p) * uint256(p) / (1 << 192);
        assertApproxEqRel(coinsPerEth, 10_011_000, 2e16, "~10M coins per ETH");
        // launch is one-shot
        vm.expectRevert(VenueLiquidity.AlreadyLaunched.selector);
        liq.launch();
    }

    function test_launchOnlyDeployerAndRefusesEth() public {
        vm.prank(trader);
        vm.expectRevert(VenueLiquidity.NotLauncher.selector);
        liq.launch();
        // not payable: ETH sent with launch is rejected
        vm.deal(address(this), 2 ether);
        (bool ok,) = address(liq).call{value: 2 ether}(abi.encodeCall(VenueLiquidity.launch, ()));
        assertFalse(ok, "launch is not payable");
        openMarket();
        assertEq(address(liq).balance, 0);
        assertEq(liq.startTick(), START_TICK, "opening price fixed at construction");
    }

    /// Review finding: the opening price cannot be chosen at launch time; a bad tick fails at construction.
    function test_badStartTickRefusedAtConstruction() public {
        vm.expectRevert(VenueLiquidity.BadTick.selector);
        new VenueLiquidity(PM, address(coin), 161_201, makeAddr("timelock"));
    }

    function test_buyRoutesFlatFeeInEthToHook() public {
        openMarket();
        uint256 before = address(hook).balance;
        buyCoin(trader, 1 ether);
        assertEq(address(hook).balance - before, 0.01 ether, "1% of the ETH input to the hook");
        assertGt(coin.balanceOf(trader), 0);
    }

    function test_sellRoutesFlatFeeInEthToHook() public {
        openMarket();
        uint256 coins = buyCoin(trader, 2 ether);
        uint256 before = address(hook).balance;
        uint256 out = sellCoin(trader, coins / 2);
        uint256 fee = address(hook).balance - before;
        assertGt(fee, 0);
        assertApproxEqAbs(fee * 10_000 / (out + fee), FEE_BPS, 1, "1% of the gross ETH out");
    }

    function test_exactOutputBuyPaysFeeOfTheGross() public {
        openMarket();
        vm.deal(trader, 20 ether);
        uint256 before = address(hook).balance;
        vm.prank(trader);
        (uint256 ethIn, uint256 out) = swapper.buy{value: 20 ether}(1_000_000 ether, true);
        assertEq(out, 1_000_000 ether, "exact output");
        uint256 fee = address(hook).balance - before;
        assertApproxEqAbs(fee * 10_000 / ethIn, FEE_BPS, 1, "1% of the gross ETH paid");
    }

    function test_exactOutputSellReverts() public {
        openMarket();
        uint256 coins = buyCoin(trader, 1 ether);
        vm.startPrank(trader);
        coin.approve(address(swapper), coins);
        vm.expectRevert();
        swapper.sell(0.01 ether, true);
        vm.stopPrank();
    }

    function test_forwardCreditsEngineBudget() public {
        openMarket();
        buyCoin(trader, 3 ether);
        uint256 pot = address(hook).balance;
        assertGt(pot, 0);
        uint256 budgetBefore = engine.acquisitionBudget();
        uint256 engineBalBefore = address(engine).balance;
        // permissionless: anyone may forward
        vm.prank(trader);
        hook.forward();
        assertEq(engine.acquisitionBudget() - budgetBefore, pot, "budget credited by the whole pot");
        assertEq(address(engine).balance - engineBalBefore, pot, "ETH reached the engine");
        assertEq(address(hook).balance, 0, "hook emptied");
        // nothing to forward now
        vm.expectRevert(VenueHook.NothingToForward.selector);
        hook.forward();
    }

    /// Nobody, including the deployer, can withdraw the liquidity or redirect the fees: no such function exists, and
    /// the fee rate and recipient are immutable.
    function test_noWithdrawNoRedirect() public {
        openMarket();
        buyCoin(trader, 1 ether);
        // the immutable fee route
        assertEq(hook.feeBps(), FEE_BPS);
        assertEq(address(hook.engine()), address(engine), "recipient fixed at construction");
        // no liquidity-removal or ETH-withdraw entrypoint on either contract (no fallback: unknown selectors revert)
        (bool a,) = address(liq).call(abi.encodeWithSignature("removeLiquidity()"));
        (bool b,) = address(liq).call(abi.encodeWithSignature("withdraw()"));
        (bool c,) = address(hook).call(abi.encodeWithSignature("setFeeRecipient(address)", trader));
        (bool d,) = address(hook).call(abi.encodeWithSignature("withdraw()"));
        assertFalse(a || b || c || d, "no withdraw or redirect path");
        // the deployer cannot re-wire a different hook either
        vm.expectRevert(VenueLiquidity.AlreadyWired.selector);
        liq.wire(trader);
    }

    // ------------------------------------------------------------------ Engine config (from test/fork/SystemBase.sol)

    function _tiers() internal pure returns (uint256[8] memory t) {
        t = [uint256(1 ether), 2 ether, 4 ether, 8 ether, 16 ether, 32 ether, 64 ether, 4096 ether];
    }

    function _thresholds() internal pure returns (uint32[7] memory d) {
        d = [uint32(2), 2, 2, 2, 2, 2, 2];
    }

    function _composeBurn() internal pure returns (uint256[7] memory b) {
        b = [uint256(100 ether), 200 ether, 400 ether, 800 ether, 1600 ether, 3200 ether, 6400 ether];
    }

    function _coinPrice() internal pure returns (uint256[8] memory c) {
        c = [uint256(10_000 ether), 20_000 ether, 40_000 ether, 80_000 ether, 160_000 ether, 320_000 ether, 640_000 ether, 0];
    }

    function _params() internal pure returns (Engine.Params memory) {
        return Engine.Params({
            shapeMarkupBps: 1000,
            decayBpsPerDraw: 20,
            floorBps: 8500,
            repriceStepBps: 500,
            graceDraws: 3,
            buyoutMarkupBps: 2000,
            bidBps: 9000,
            bidWeeklyCap: 10 ether
        });
    }
}
