// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolInitializer_v4} from "@uniswap/v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";

// Canonical ETH/FWAToken v4 pool params. Shared with FWATokenHook + the deploy script so they can't drift.
uint24 constant POOL_LP_FEE = 0;
int24 constant POOL_TICK_SPACING = 60;

interface IBuybackRouter {
    function onTokenReceived(uint256 depositorAmt, uint256 purchaserAmt) external;
}

/// @title FWAToken - the FWA platform incentive token
/// @notice Fixed-supply ERC20 that bootstraps FWA activity. Modeled on the team's TTT token:
///         transfers are LOCKED except (a) mints/burns, (b) to/from owner-managed distributors such
///         as FWARewards and FWAClaim, (c) the owner, and (d) the v4 PoolManager, gated by a
///         per-tx transient allowance the hook bumps. The token is also its
///         own buyback sink: ETH sent here is spent permissionlessly via `buyback()` and the
///         bought FWAToken is routed to depositors / purchasers / burn via FWARewards.
/// @dev The hook is deployed first (it is token-agnostic, keyed off the pool key), then FWAToken is
///      deployed referencing it; only the hook may bump the transient transfer allowance.
contract FWAToken is ERC20, Ownable, ReentrancyGuard, IUnlockCallback {
    using CurrencySettler for Currency;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Max ETH consumed per rate-limited `buyback()` call.
    uint256 public constant BUYBACK_INCREMENT = 1 ether;
    /// @notice Minimum block gap between buyback calls.
    uint256 public constant BUYBACK_DELAY_BLOCKS = 1;
    /// @notice Caller bounty, in bps of the per-call slice, paid for poking `buyback()`.
    uint256 public constant CALLER_REWARD_BPS = 50; // 0.5%
    uint256 private constant TOTAL_BIPS = 10_000;
    /// @dev Initial sqrt-price floor is ~95.35% of launch sqrt price, bounding token-price
    ///      appreciation during a buyback to roughly 10% until the owner deliberately updates it.
    uint256 private constant DEFAULT_BUYBACK_SQRT_LIMIT_BPS = 9_535;

    /// @notice Recipient of the seeded LP position — burning it locks the launch liquidity forever.
    address private constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The v4 hook for this token's ETH/FWAToken pool. Immutable — only it may bump the
    ///         transient transfer allowance.
    address public immutable hook;
    /// @notice The v4 PoolManager (for the buyback swap path).
    IPoolManager public immutable poolManager;
    /// @notice The v4 PositionManager, used by `launch()` to init the pool + seed liquidity.
    IPositionManager public immutable positionManager;
    /// @notice Permit2, used to authorize the PositionManager to pull the seed FWAToken.
    IAllowanceTransfer public immutable permit2;

    /// @notice Set once `launch()` seeds the pool, so it can only run a single time.
    bool public launched;

    string private _name;
    string private _symbol;

    /// @notice Addresses allowed to move FWAToken freely while transfers are otherwise locked. Rewards
    ///         and claim modules are registered so they can pay participants.
    mapping(address => bool) public isDistributor;

    uint256 public lastBuybackBlock;

    /// @notice Protocol-controlled minimum sqrt price for ETH -> FWAToken buybacks. Because the pool
    ///         price is token-per-ETH, a lower sqrt price is a more expensive FWAToken. Combined with
    ///         exact full-fill enforcement, reaching this floor reverts instead of accepting a bad fill.
    uint160 public buybackSqrtPriceLimitX96;

    /// @notice The rewards router that receives depositor + purchaser slices of each buyback and
    ///         accounts them to participants. Unset => `buyback()` burns the whole bought amount.
    address public pool;
    /// @notice Buyback routing split, in bps of the bought FWAToken (after the caller bounty). Must sum
    ///         to `TOTAL_BIPS`. Defaults to 40% depositors / 40% purchasers / 20% burn. Owner-set.
    uint256 public routeDepositorBps = 4_000;
    uint256 public routePurchaserBps = 4_000;
    uint256 public routeBurnBps = 2_000;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event AllowanceIncreased(uint256 amount);
    event AllowanceSpent(address indexed from, address indexed to, uint256 amount);
    event DistributorSet(address indexed account, bool allowed);
    event Bought(address indexed caller, uint256 ethSpent, uint256 amountBought, uint256 callerReward);
    event PoolSet(address indexed pool);
    event RouteSplitSet(uint256 depBps, uint256 purchaserBps, uint256 burnBps);
    event BuybackRouted(uint256 toDepositors, uint256 toPurchasers, uint256 burned);
    event BuybackPriceLimitSet(uint160 sqrtPriceLimitX96);
    event Launched(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 tokenSeeded);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidAddress();
    error EmptyString();
    error OnlyHook();
    error InvalidTransfer();
    error NoEth();
    error NotPoolManager();
    error DelayNotMet();
    error AlreadyLaunched();
    error NoLpSupply();
    error InvalidRange();
    error InvalidSplit();
    error PartialFill();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param name_ Token name.
    /// @param symbol_ Token symbol.
    /// @param supply_ Fixed total supply.
    /// @param lpSupply_ Portion of `supply_` minted to this contract to seed the pool in `launch()`;
    ///        the remainder is minted to the deployer. Must be <= `supply_`.
    /// @param _hook The FWATokenHook deployed beforehand at its mined address.
    /// @param _poolManager The v4 PoolManager.
    /// @param _positionManager The v4 PositionManager (used by `launch()`).
    /// @param _permit2 Permit2 (used by `launch()` to let the PositionManager pull the seed FWAToken).
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 supply_,
        uint256 lpSupply_,
        address _hook,
        IPoolManager _poolManager,
        IPositionManager _positionManager,
        IAllowanceTransfer _permit2
    ) {
        if (bytes(name_).length == 0 || bytes(symbol_).length == 0) revert EmptyString();
        if (_hook == address(0) || address(_poolManager) == address(0)) revert InvalidAddress();
        if (address(_positionManager) == address(0) || address(_permit2) == address(0)) revert InvalidAddress();
        if (supply_ == 0) revert InvalidAddress();
        if (lpSupply_ > supply_) revert InvalidAddress();

        _name = name_;
        _symbol = symbol_;
        hook = _hook;
        poolManager = _poolManager;
        positionManager = _positionManager;
        permit2 = _permit2;

        _initializeOwner(msg.sender);
        // The LP seed is held here for `launch()`; the deployer gets the rest to distribute.
        if (lpSupply_ != 0) _mint(address(this), lpSupply_);
        if (supply_ - lpSupply_ != 0) _mint(msg.sender, supply_ - lpSupply_);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Add or remove an address from the distributor whitelist (e.g. FWARewards/FWAClaim).
    function setDistributor(address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert InvalidAddress();
        isDistributor[account] = allowed;
        emit DistributorSet(account, allowed);
    }

    /// @notice Set the rewards router that receives depositor + purchaser slices of each buyback.
    ///         Unset (zero) => `buyback()` burns the whole bought amount.
    function setPool(address g) external onlyOwner {
        if (g == address(0)) revert InvalidAddress();
        pool = g;
        emit PoolSet(g);
    }

    /// @notice Set the buyback routing split (bps of bought FWAToken → depositors / purchasers / burn).
    ///         The three values must sum to exactly `TOTAL_BIPS`.
    function setRouteSplit(uint256 depBps, uint256 purchaserBps, uint256 burnBps) external onlyOwner {
        if (depBps + purchaserBps + burnBps != TOTAL_BIPS) revert InvalidSplit();
        routeDepositorBps = depBps;
        routePurchaserBps = purchaserBps;
        routeBurnBps = burnBps;
        emit RouteSplitSet(depBps, purchaserBps, burnBps);
    }

    /// @notice Update the hard execution-price floor used by every permissionless buyback. This is a
    ///         protocol bound, not caller-supplied slippage, so a searcher cannot weaken it when poking.
    function setBuybackSqrtPriceLimitX96(uint160 sqrtPriceLimitX96) external onlyOwner {
        if (sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE || sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE) {
            revert InvalidRange();
        }
        buybackSqrtPriceLimitX96 = sqrtPriceLimitX96;
        emit BuybackPriceLimitSet(sqrtPriceLimitX96);
    }

    /// @notice Burn `amount` from the caller's balance, decreasing `totalSupply`.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                 LAUNCH
    //////////////////////////////////////////////////////////////*/

    /// @notice One-shot. Initializes the ETH/FWAToken pool and seeds every FWAToken held by this contract as a
    ///         single-sided, buy-only position whose LP NFT is minted to the dead address (so the
    ///         launch liquidity is locked forever). The range sits at/below the starting price, so it
    ///         is entirely FWAToken; buyers spend ETH to pull FWAToken out, pushing the price up. Any `msg.value`
    ///         is a rounding buffer for the mint's `amount0Max` (à la the 1-2 wei TTT pairs); the pool
    ///         is effectively single-sided FWAToken. The hook reads `launching()` to permit pool init + the
    ///         seed add-liquidity and to bump this token's transient transfer allowance in
    ///         `_afterAddLiquidity` so the pool can pull the FWAToken past the transfer lock.
    /// @param sqrtPriceX96 Initial pool price. Its tick must be >= `tickUpper` so the seeded position
    ///        is 100% FWAToken (token1).
    /// @param tickLower Lower bound of the seeded range (a multiple of `POOL_TICK_SPACING`).
    /// @param tickUpper Upper bound of the seeded range (a multiple of `POOL_TICK_SPACING`).
    function launch(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper) external payable onlyOwner nonReentrant {
        if (launched) revert AlreadyLaunched();
        uint256 tokenAmount = balanceOf(address(this));
        if (tokenAmount == 0) revert NoLpSupply();
        if (
            tickLower >= tickUpper || tickLower % POOL_TICK_SPACING != 0 || tickUpper % POOL_TICK_SPACING != 0
                || TickMath.getTickAtSqrtPrice(sqrtPriceX96) < tickUpper
        ) revert InvalidRange();

        launched = true;
        uint160 initialBuybackLimit = uint160(uint256(sqrtPriceX96) * DEFAULT_BUYBACK_SQRT_LIMIT_BPS / TOTAL_BIPS);
        if (initialBuybackLimit <= TickMath.MIN_SQRT_PRICE) initialBuybackLimit = TickMath.MIN_SQRT_PRICE + 1;
        buybackSqrtPriceLimitX96 = initialBuybackLimit;
        emit BuybackPriceLimitSet(initialBuybackLimit);

        PoolKey memory key = poolKey();

        // token1-only (FWAToken) liquidity across the range. getLiquidityForAmount1 rounds down, so the
        // FWAToken the mint pulls never exceeds our balance; any wei of dust stays here harmlessly.
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), tokenAmount
        );

        // Open the launch window for the hook: it reads `launching()` to allow pool init + the seed
        // add-liquidity (and to bump our transient transfer allowance). Transient (slot 1) so it is
        // only ever true within this call — pool init can't be front-run and the window can't be
        // left open. (Slot 0 is the transfer allowance.)
        assembly {
            tstore(1, 1)
        }

        // Let the PositionManager pull our FWAToken via Permit2. The pool->manager transfer passes the
        // transfer lock because the hook bumps our transient allowance in `_afterAddLiquidity`.
        _approve(address(this), address(permit2), type(uint256).max);
        permit2.approve(address(this), address(positionManager), type(uint160).max, type(uint48).max);

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory mintParams = new bytes[](2);
        // (key, tickLower, tickUpper, liquidity, amount0Max=msg.value buffer, amount1Max, recipient, hookData)
        mintParams[0] =
            abi.encode(key, tickLower, tickUpper, liquidity, msg.value, tokenAmount, DEAD_ADDRESS, bytes(""));
        mintParams[1] = abi.encode(key.currency0, key.currency1);

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encodeWithSelector(IPoolInitializer_v4.initializePool.selector, key, sqrtPriceX96);
        params[1] = abi.encodeWithSelector(
            IPositionManager.modifyLiquidities.selector, abi.encode(actions, mintParams), block.timestamp + 60
        );

        positionManager.multicall{value: msg.value}(params);

        // Close the launch window. (Transient storage also clears at end of tx, but be explicit.)
        assembly {
            tstore(1, 0)
        }

        emit Launched(sqrtPriceX96, tickLower, tickUpper, liquidity, tokenAmount);
    }

    /// @notice True only while `launch()` is mid-execution. The hook reads this to permit the
    ///         one-time pool init + seed add-liquidity and to bump the transient transfer allowance.
    function launching() external view returns (bool isLaunching) {
        assembly {
            isLaunching := tload(1)
        }
    }

    /*//////////////////////////////////////////////////////////////
                                BUYBACK
    //////////////////////////////////////////////////////////////*/

    /// @notice The canonical ETH/FWAToken pool key, reconstructed from immutables + the shared params.
    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(this)),
            fee: POOL_LP_FEE,
            tickSpacing: POOL_TICK_SPACING,
            hooks: IHooks(hook)
        });
    }

    /// @notice Permissionless. Spends up to `BUYBACK_INCREMENT` of contract ETH buying FWAToken, routing
    ///         it to depositors / purchasers / burn and paying the caller a `CALLER_REWARD_BPS`
    ///         bounty. Rate-limited and constrained by the protocol sqrt-price floor.
    function buyback() external nonReentrant returns (uint256 amountOut) {
        if (block.number < lastBuybackBlock + BUYBACK_DELAY_BLOCKS) revert DelayNotMet();

        uint256 available = address(this).balance;
        if (available == 0) revert NoEth();

        uint256 slice = available < BUYBACK_INCREMENT ? available : BUYBACK_INCREMENT;
        uint256 incentive = slice * CALLER_REWARD_BPS / TOTAL_BIPS;
        uint256 buyAmount = slice - incentive;

        lastBuybackBlock = block.number;

        if (buyAmount > 0) {
            bytes memory result = poolManager.unlock(abi.encode(buyAmount));
            uint256 amountSpent;
            (amountOut, amountSpent) = abi.decode(result, (uint256, uint256));
            // An exhausted / narrow LP range may consume less than the requested exact input. Revert
            // the entire buyback in that case so no ETH becomes untracked and the caller bounty is
            // never calculated from an amount the swap did not actually spend.
            if (amountSpent != buyAmount) revert PartialFill();
        }

        // Route the bought FWAToken (held on this contract after the swap): depositors / purchasers / burn.
        if (amountOut > 0) {
            address g = pool;
            if (g == address(0)) {
                _burn(address(this), amountOut); // not wired yet -> burn the whole amount
            } else {
                uint256 toDep = amountOut * routeDepositorBps / TOTAL_BIPS;
                uint256 toPurchaser = amountOut * routePurchaserBps / TOTAL_BIPS;
                uint256 toBurn = amountOut - toDep - toPurchaser; // remainder -> exact sum, no dust

                if (toBurn != 0) _burn(address(this), toBurn); // true supply reduction
                if (toDep + toPurchaser != 0) {
                    _transfer(address(this), g, toDep + toPurchaser); // g is a distributor -> passes the lock
                    IBuybackRouter(g).onTokenReceived(toDep, toPurchaser);
                }
                emit BuybackRouted(toDep, toPurchaser, toBurn);
            }
        }

        if (incentive > 0) SafeTransferLib.forceSafeTransferETH(msg.sender, incentive);

        emit Bought(msg.sender, buyAmount, amountOut, incentive);
    }

    /// @dev Unlock callback for the buyback swap (ETH -> FWAToken), settling against this contract's ETH.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        uint256 amountIn = abi.decode(data, (uint256));

        PoolKey memory key = poolKey();
        BalanceDelta d = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: buybackSqrtPriceLimitX96
            }),
            ""
        );

        uint256 amountSpent = uint256(int256(-d.amount0()));
        key.currency0.settle(poolManager, address(this), amountSpent, false);

        uint256 amountOut = uint256(int256(d.amount1()));
        if (amountOut > 0) {
            // Bump our own transient allowance so the pool->self transfer passes the guard below.
            _bumpTransferAllowance(amountOut);
            key.currency1.take(poolManager, address(this), amountOut, false);
        }

        return abi.encode(amountOut, amountSpent);
    }

    /*//////////////////////////////////////////////////////////////
                            TRANSFER GUARDS
    //////////////////////////////////////////////////////////////*/

    /// @notice Increase the per-tx transient transfer allowance the PoolManager is permitted to
    ///         move. Hook-only. Stored in transient slot 0, expires at end of tx.
    function increaseTransferAllowance(uint256 amountAllowed) external {
        if (msg.sender != hook) revert OnlyHook();
        _bumpTransferAllowance(amountAllowed);
    }

    function _bumpTransferAllowance(uint256 amountAllowed) internal {
        uint256 current = getTransferAllowance();
        assembly {
            tstore(0, add(current, amountAllowed))
        }
        emit AllowanceIncreased(amountAllowed);
    }

    function getTransferAllowance() public view returns (uint256 transferAllowance) {
        assembly {
            transferAllowance := tload(0)
        }
    }

    /// @dev Allow: mints, burns, owner↔anyone, distributor↔anyone, and PoolManager↔anyone capped
    ///      by the transient allowance the hook bumped. Everything else reverts — the lock.
    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        if (from == address(0) || to == address(0)) return; // mint / burn

        if (isDistributor[from] || isDistributor[to]) return;

        address o = owner();
        if (from == o || to == o) return;

        address pm = address(poolManager);
        if (from == pm || to == pm) {
            uint256 allowance = getTransferAllowance();
            require(allowance >= amount, InvalidTransfer());
            assembly {
                tstore(0, sub(allowance, amount))
            }
            emit AllowanceSpent(from, to, amount);
            return;
        }

        revert InvalidTransfer();
    }

    receive() external payable {}
}
