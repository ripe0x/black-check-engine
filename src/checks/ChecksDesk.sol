// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Governed} from "../core/Governed.sol";

interface IPoolOwnerDesk {
    function nfts(uint256 tokenId)
        external
        view
        returns (uint128 refCost, uint128 cashCost, uint8 tier, uint8 source, uint8 state, uint32 carried);
    function cListings(uint256 listingId)
        external
        view
        returns (uint256 tokenId, uint128 notional, uint128 term, uint64 entry, bool open, uint128 clockStart);
    function survived(uint256 listingId) external view returns (uint256);
    function tierOf(uint256 tokenId) external view returns (uint8);
    function scheduleOf(uint8 tier) external view returns (uint256);
    function deskCompose(uint256 keepListing, uint256 burnListing, bool swap)
        external
        returns (uint256 keep, uint256 burned);
    function deskFormBlack(uint256[] calldata listingIds) external returns (uint256 black);
    function deskRelease(uint256 listingId, address to) external returns (uint256 tokenId);
}

interface ICoinBurnFrom {
    function burnFrom(address from, uint256 amount) external;
}

interface IVaultContribute {
    function contribute() external payable;
}

/// @title ChecksDesk
/// @notice The Checks-specific actions on listed Checks: composition, Black Check formation, and buyouts with ETH or
///         with the coin. It holds nothing: the pool owner moves the tokens, Checks enforces its own composition
///         rules, the coin burns what a caller pays, and ETH goes to the vault.
/// @dev Provenance: this repository at tag rc2, `src/core/Engine.sol` (`compose`, `composeCost`, `formBlack`,
///      `buyWithEth`, `buyWithCoin`), moved out of the upgradeable Engine into an immutable contract on the
///      collection-games base (docs/REBASE_PLAN.md R4-R5).
///      Rules:
///      - eligibility (D002, D008): a Check listing is eligible once it has survived at least `drawsToCompose[tier]`
///        draws (and at least one) in its current episode, below the Black tier;
///      - composition: anyone composes two eligible Checks; Checks requires the same tier at most 5 (40 to 4). Choosing
///        freely (a swap, or keeping the Check with fewer survived draws) burns `composeBurn[tier]` coin from the caller
///        in the same transaction. The deterministic outcome (no swap; keep the one with more survived draws, the lower
///        id on a tie) is free once both have survived `graceDraws` more than the threshold;
///      - Black Check formation: 64 eligible singles, the first survives. Free only when every one is past the grace
///        and the token ids are strictly ascending (deterministic); otherwise `composeBurn[6]` coin;
///      - buyouts (D006, D012): anyone buys one listed Check for its tier's schedule price plus `ethMarkupBps` in ETH
///        (to the vault), or for `coinPrice[tier]` coin (burned; zero disables the tier, and every tier launches
///        disabled). Prices are the council's; the ETH markup can never go below `MIN_ETH_MARKUP_BPS`.
///      A failed operation burns nothing and takes no ETH: everything happens in one transaction.
contract ChecksDesk is ReentrancyGuard, Governed {
    uint256 internal constant BPS = 10_000;
    uint8 internal constant SINGLE = 6;
    uint8 internal constant BLACK = 7;
    /// @notice The lowest ETH buyout markup the council may set: above the vault's 120%-of-schedule purchase cap
    ///         (FundingVault.MAX_PRICE_OF_SCHEDULE_BPS) with a margin, so a Check sold to the vault can never be bought
    ///         back for less (review M-1).
    uint256 public constant MIN_ETH_MARKUP_BPS = 2_500;
    uint256 public constant MAX_ETH_MARKUP_BPS = 100_000;
    uint256 public constant MAX_DRAWS = 1_000_000;

    IPoolOwnerDesk public immutable poolOwner;
    ICoinBurnFrom public immutable coin;
    address public immutable vault;

    /// @notice Composition rules (owner, bounded: they set pace and the coin price of choice, not what Checks are worth).
    struct ComposeParams {
        uint32[7] drawsToCompose; // per tier below Black (index 6: singles, for Black formation)
        uint32 graceDraws; // more draws after which the deterministic outcome is free
        uint256[7] composeBurn; // coin burned for a free choice, per tier (index 6: Black formation)
    }

    /// @notice Buyout prices (council: they set what a Check leaves for).
    struct BuyoutParams {
        uint256 ethMarkupBps; // over the tier's schedule price
        uint256[8] coinPrice; // coin per tier; zero disables the tier
    }

    ComposeParams internal _cp;
    BuyoutParams internal _bp;

    event ComposeParamsSet(ComposeParams p);
    event BuyoutParamsSet(BuyoutParams p);
    event Composed(
        address indexed caller, uint256 indexed keep, uint256 indexed burned, uint8 newTier, bool swap, uint256 coinBurned
    );
    event BlackCheck(address indexed caller, uint256 indexed tokenId, uint256 coinBurned);
    event BoughtWithEth(address indexed buyer, uint256 indexed tokenId, uint8 tier, uint256 price);
    event BoughtWithCoin(address indexed buyer, uint256 indexed tokenId, uint8 tier, uint256 coinBurned);

    error NotEligible();
    error BadInput();
    error Disabled();
    error Underpaid();

    constructor(address admin_, address poolOwner_, address coin_, address vault_, ComposeParams memory c, BuyoutParams memory b)
        Governed(admin_, false)
    {
        if (poolOwner_ == address(0) || coin_ == address(0) || vault_ == address(0)) revert ZeroAddress();
        poolOwner = IPoolOwnerDesk(poolOwner_);
        coin = ICoinBurnFrom(coin_);
        vault = vault_;
        _setComposeParams(c);
        _setBuyoutParams(b);
    }

    // ------------------------------------------------------------------ eligibility

    /// @notice The token id, tier and survived draws of a Check listing (tier 255 and 0 draws if not an open listing).
    function listingInfo(uint256 listingId) public view returns (uint256 tokenId, uint8 tier, uint256 draws) {
        bool open;
        (tokenId,,,, open,) = poolOwner.cListings(listingId);
        if (!open) return (tokenId, type(uint8).max, 0);
        tier = poolOwner.tierOf(tokenId);
        draws = poolOwner.survived(listingId);
    }

    /// @notice True when listing `listingId` holds a Check that may be composed now.
    function eligible(uint256 listingId) public view returns (bool) {
        (, uint8 tier, uint256 draws) = listingInfo(listingId);
        return _ready(tier, draws, 0);
    }

    function _ready(uint8 tier, uint256 draws, uint256 extra) internal view returns (bool) {
        return tier < BLACK && draws != 0 && draws >= uint256(_cp.drawsToCompose[tier]) + extra;
    }

    // ------------------------------------------------------------------ composition

    /// @notice Coin `compose(keep, burn, swap)` would burn now (zero on the free deterministic outcome). Reverts on
    ///         an ineligible listing.
    function composeCost(uint256 keepListing, uint256 burnListing, bool swap) public view returns (uint256) {
        (, uint8 tk, uint256 dk) = listingInfo(keepListing);
        (uint256 burnToken, uint8 tb, uint256 db) = listingInfo(burnListing);
        (uint256 keepToken,,) = listingInfo(keepListing);
        if (!_ready(tk, dk, 0) || !_ready(tb, db, 0) || tk != tb || keepListing == burnListing) revert NotEligible();
        bool deterministic = !swap && (dk > db || (dk == db && keepToken < burnToken));
        uint256 g = _cp.graceDraws;
        if (deterministic && _ready(tk, dk, g) && _ready(tb, db, g)) return 0;
        return _cp.composeBurn[tk];
    }

    /// @notice Composes two eligible listed Checks of the same tier; the one in `keepListing` survives at the next tier
    ///         and is listed again with a new episode. Anyone. Burns `composeCost` coin from the caller (allowance).
    function compose(uint256 keepListing, uint256 burnListing, bool swap) external nonReentrant {
        uint256 cost = composeCost(keepListing, burnListing, swap);
        (uint256 keep, uint256 burned) = poolOwner.deskCompose(keepListing, burnListing, swap);
        if (cost != 0) coin.burnFrom(msg.sender, cost); // same transaction: any failure burns nothing
        emit Composed(msg.sender, keep, burned, poolOwner.tierOf(keep), swap, cost);
    }

    /// @notice Coin `formBlack(listingIds)` would burn now. Reverts unless all 64 are eligible singles.
    function formBlackCost(uint256[] calldata listingIds) public view returns (uint256) {
        if (listingIds.length != 64) revert BadInput();
        bool free = true;
        uint256 g = _cp.graceDraws;
        uint256 prev;
        for (uint256 i; i < 64; ++i) {
            (uint256 tokenId, uint8 tier, uint256 draws) = listingInfo(listingIds[i]);
            if (tier != SINGLE || !_ready(tier, draws, 0)) revert NotEligible();
            if (!_ready(tier, draws, g) || (i != 0 && tokenId <= prev)) free = false;
            prev = tokenId;
        }
        return free ? 0 : _cp.composeBurn[SINGLE];
    }

    /// @notice Forms a Black Check from 64 eligible listed singles; the first survives and is listed again (once the
    ///         council schedules the Black tier). Anyone. Burns `formBlackCost` coin from the caller.
    function formBlack(uint256[] calldata listingIds) external nonReentrant {
        uint256 cost = formBlackCost(listingIds);
        uint256 black = poolOwner.deskFormBlack(listingIds);
        if (cost != 0) coin.burnFrom(msg.sender, cost);
        emit BlackCheck(msg.sender, black, cost);
    }

    // ------------------------------------------------------------------ buyouts

    /// @notice ETH price of the Check in `listingId` now: the higher of its tier's schedule price and its recorded
    ///         cost, plus the markup (never below what the protocol paid for it, review M-1).
    function ethPrice(uint256 listingId) public view returns (uint256) {
        (uint256 tokenId, uint8 tier,) = listingInfo(listingId);
        if (tier == type(uint8).max) revert NotEligible();
        uint256 s = poolOwner.scheduleOf(tier);
        if (s == 0) revert Disabled();
        (uint128 cost,,,,,) = poolOwner.nfts(tokenId);
        if (cost > s) s = cost;
        return s * (BPS + _bp.ethMarkupBps) / BPS;
    }

    /// @notice Buys the Check in `listingId` for ETH; the price goes to the vault (acquisitions), any excess back.
    function buyWithEth(uint256 listingId) external payable nonReentrant {
        uint256 price = ethPrice(listingId);
        if (msg.value < price) revert Underpaid();
        uint256 tokenId = poolOwner.deskRelease(listingId, msg.sender);
        IVaultContribute(vault).contribute{value: price}();
        if (msg.value > price) SafeTransferLib.forceSafeTransferETH(msg.sender, msg.value - price);
        emit BoughtWithEth(msg.sender, tokenId, poolOwner.tierOf(tokenId), price);
    }

    /// @notice Buys the Check in `listingId` by burning its tier's coin price from the caller (allowance).
    function buyWithCoin(uint256 listingId) external nonReentrant {
        (, uint8 tier,) = listingInfo(listingId);
        if (tier == type(uint8).max) revert NotEligible();
        uint256 price = _bp.coinPrice[tier];
        if (price == 0) revert Disabled();
        uint256 tokenId = poolOwner.deskRelease(listingId, msg.sender);
        coin.burnFrom(msg.sender, price);
        emit BoughtWithCoin(msg.sender, tokenId, tier, price);
    }

    // ------------------------------------------------------------------ governance

    function composeParams() external view returns (ComposeParams memory) {
        return _cp;
    }

    function buyoutParams() external view returns (BuyoutParams memory) {
        return _bp;
    }

    /// @notice Composition pace and the coin price of a free choice. Owner (bounded).
    function setComposeParams(ComposeParams calldata p) external onlyOwner {
        _setComposeParams(p);
    }

    /// @notice Buyout prices. Council only (D012).
    function setBuyoutParams(BuyoutParams calldata p) external onlyCouncil {
        _setBuyoutParams(p);
    }

    function _setComposeParams(ComposeParams memory p) internal {
        if (p.graceDraws > MAX_DRAWS) revert OutOfBounds();
        for (uint256 t; t < 7; ++t) {
            if (p.drawsToCompose[t] == 0 || p.drawsToCompose[t] > MAX_DRAWS) revert OutOfBounds();
        }
        _cp = p;
        emit ComposeParamsSet(p);
    }

    function _setBuyoutParams(BuyoutParams memory p) internal {
        if (p.ethMarkupBps < MIN_ETH_MARKUP_BPS || p.ethMarkupBps > MAX_ETH_MARKUP_BPS) revert OutOfBounds();
        _bp = p;
        emit BuyoutParamsSet(p);
    }
}
