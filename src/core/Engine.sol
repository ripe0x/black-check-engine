// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IController} from "../interfaces/IController.sol";
import {IChecksOriginals, IChecksEdition} from "../interfaces/IChecks.sol";

interface IShapesBacking {
    function backingOf(uint256 tokenId) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function mintFee() external view returns (uint256);
    function mintBatchTo(uint256 amountWei, uint256 quantity, address to)
        external
        payable
        returns (uint256 firstTokenId);
}

interface ICoinBurn {
    function burnFrom(address from, uint256 amount) external;
}

/// @notice Custody and lifecycle of the protocol's Checks and Shapes. Upgradeable only through the timelock.
/// @dev Asset exits, exhaustively:
///      - NFTs: to the current controller to be listed; consumed by canonical Checks composition; to a buyer who pays
///        the published ETH or coin price (`buyWithEth`, `buyWithCoin`).
///      - ETH: to a seller of a Check or Edition at the published bid, from the acquisition budget only and within a
///        weekly cap (`sell*`); to Shapes, minting a replacement for a won Shape at the same backing (`restockShapes`).
///      The engine never approves anyone except the canonical Checks contract on Editions (required by Checks to
///      migrate them) and has no generic call. Every price (listing, decay, buyout, bid) is computed from timelocked
///      parameters and verified state; no caller supplies one. Maintenance needs the pool's draw queue to be empty.
///      Storage is append-only across upgrades once deployed.
contract Engine is Initializable, UUPSUpgradeable {
    uint8 internal constant TIERS = 8; // divisorIndex 0 (80 checks) .. 7 (Black)
    uint8 internal constant SINGLE = 6;
    uint8 internal constant BLACK = 7;
    uint256 internal constant BPS = 10_000;

    IChecksOriginals public immutable checks;
    IChecksEdition public immutable editions;
    IShapesBacking public immutable shapes;
    ICoinBurn public immutable coin;

    /// @notice Timelocked economic parameters (D003-D005). Bounds are checked in `setParams`.
    struct Params {
        uint16 shapeMarkupBps; // Shapes list at backing x (1 + markup), <= 5,000 (D004)
        uint16 decayBpsPerDraw; // notional falls this share of the schedule per survived draw, <= 100
        uint16 floorBps; // lowest notional, share of the schedule, 5,000..10,000 (D005)
        uint16 repriceStepBps; // smallest change worth an FWA reprice, <= 2,000
        uint32 graceDraws; // draws past the threshold after which composition is free and deterministic
        uint16 buyoutMarkupBps; // ETH buyout = schedule x (1 + markup), >= 1,000
        uint16 bidBps; // standing bid = schedule x bid, <= 10,000
        uint128 bidWeeklyCap; // ETH the bid may spend per week
    }

    address public timelock;
    address public operator;
    address public guardian;
    bool public halted;

    IController public controller;
    mapping(address controller => bool) public isRetired;

    /// @notice FWA notional before decay, per Checks tier (wei). Zero means that tier is not listed or traded.
    uint256[TIERS] public tierNotional;
    /// @notice Allocating draws a Check must survive at its tier before it can be composed (index 6: Black).
    uint32[7] public drawsToCompose;
    /// @notice Coin burned to compose by choice, per input tier (index 6: Black formation).
    uint256[7] public composeBurn;
    /// @notice Coin burned to buy a Check outright, per tier. Zero disables coin buyouts for that tier (D006).
    uint256[TIERS] public coinPrice;
    Params public params;

    struct Listing {
        address controller;
        uint64 listingId;
        uint128 price; // Checks: current FWA notional. Shapes: backing.
    }

    mapping(uint256 tokenId => Listing) public checkListing;
    /// @notice Draws survived in earlier listings at the current tier (carried across migrations).
    mapping(uint256 tokenId => uint32) public carriedDraws;
    mapping(uint256 shapeId => Listing) public shapeListing;

    /// @notice ETH reserved for buying Checks (coin fees and sale proceeds). The rest of the balance is game capital.
    uint256 public acquisitionBudget;
    uint64 public bidWeek;
    uint128 public bidSpentThisWeek;
    bool internal locked;

    event ControllerSet(address indexed controller, address indexed retired);
    event Listed(address indexed collection, uint256 indexed tokenId, address indexed controller, uint256 listingId, uint256 price);
    event Unlisted(address indexed collection, uint256 indexed tokenId, address indexed controller, uint256 listingId);
    event Repriced(uint256 indexed tokenId, uint256 oldPrice, uint256 newPrice, uint256 survived);
    event Composed(address indexed by, uint256 indexed survivor, uint256 indexed burned, uint8 tier, uint256 coinBurned);
    event BlackCheck(address indexed by, uint256 indexed survivor, uint256[] burned, uint256 coinBurned);
    event Bought(address indexed buyer, uint256 indexed tokenId, uint8 tier, uint256 ethPaid, uint256 coinBurned);
    event Acquired(address indexed seller, uint256 indexed tokenId, bool fromEdition, uint8 tier, uint256 ethPaid);
    event Restocked(uint256 indexed wonShapeId, uint256 indexed newShapeId, uint256 backing);
    event Funded(address indexed from, uint256 amount);
    event Halted(address indexed by, bool halted);
    event RoleSet(bytes32 indexed role, address indexed account);
    /// @dev New values are in the call's input and public getters; the events mark that they changed.
    event ScheduleSet();
    event ParamsSet();

    error NotTimelock();
    error NotAllowed();
    error NotHeld();
    error AlreadyListed();
    error NotListed();
    error NotRevealed();
    error TierNotListed();
    error NotEligible();
    error QueueBusy();
    error UnknownController();
    error BadInput();
    error Halt();
    error WrongPayment();
    error BudgetExceeded();
    error Reentrancy();
    error PayFailed();

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert NotTimelock();
        _;
    }

    modifier nonReentrant() {
        if (locked) revert Reentrancy();
        locked = true;
        _;
        locked = false;
    }

    constructor(IChecksOriginals checks_, IChecksEdition editions_, IShapesBacking shapes_, ICoinBurn coin_) {
        checks = checks_;
        editions = editions_;
        shapes = shapes_;
        coin = coin_;
        _disableInitializers();
    }

    function initialize(
        address timelock_,
        address operator_,
        address guardian_,
        IController controller_,
        uint256[TIERS] calldata tierNotional_,
        uint32[7] calldata drawsToCompose_,
        uint256[7] calldata composeBurn_,
        uint256[TIERS] calldata coinPrice_,
        Params calldata params_
    ) external initializer {
        timelock = timelock_;
        operator = operator_;
        guardian = guardian_;
        controller = controller_;
        _setSchedule(tierNotional_, drawsToCompose_, composeBurn_, coinPrice_);
        _setParams(params_);
        // Purchases start off: the game opens when the guardian or timelock calls `resume`.
        halted = true;
        emit ControllerSet(address(controller_), address(0));
    }

    // ------------------------------------------------------------------ pool

    /// @notice Creates the current controller's pool. Anyone; the controller refuses a second pool.
    function openPool() external {
        controller.open();
    }

    /// @notice Lists custody Checks at their decayed notional. Anyone; only revealed Originals at listed tiers.
    function listChecks(uint256[] calldata tokenIds) external nonReentrant {
        IController c = controller;
        uint256[] memory prices = new uint256[](tokenIds.length);
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            if (_clearIfWon(checkListing[id])) delete carriedDraws[id]; // a Check that left and came back starts anew
            IChecksOriginals.Check memory info = checks.getCheck(id);
            if (!info.isRevealed) revert NotRevealed();
            uint256 price = _notional(info.stored.divisorIndex, carriedDraws[id]);
            if (price == 0) revert TierNotListed();
            prices[i] = price;
            checks.transferFrom(address(this), address(c), id); // reverts unless held here
        }
        uint256[] memory listingIds = c.list(address(checks), tokenIds, prices);
        for (uint256 i; i < tokenIds.length; ++i) {
            checkListing[tokenIds[i]] = Listing(address(c), uint64(listingIds[i]), uint128(prices[i]));
            emit Listed(address(checks), tokenIds[i], address(c), listingIds[i], prices[i]);
        }
    }

    /// @notice Lists custody Shapes at backing x (1 + markup). Anyone.
    function listShapes(uint256[] calldata shapeIds) external nonReentrant {
        _listShapes(shapeIds);
    }

    function _listShapes(uint256[] memory shapeIds) internal {
        IController c = controller;
        uint256[] memory prices = new uint256[](shapeIds.length);
        uint256[] memory backings = new uint256[](shapeIds.length);
        for (uint256 i; i < shapeIds.length; ++i) {
            uint256 id = shapeIds[i];
            _clearIfWon(shapeListing[id]);
            backings[i] = shapes.backingOf(id);
            prices[i] = backings[i] * (BPS + params.shapeMarkupBps) / BPS;
            shapes.transferFrom(address(this), address(c), id);
        }
        uint256[] memory listingIds = c.list(address(shapes), shapeIds, prices);
        for (uint256 i; i < shapeIds.length; ++i) {
            shapeListing[shapeIds[i]] = Listing(address(c), uint64(listingIds[i]), uint128(backings[i]));
            emit Listed(address(shapes), shapeIds[i], address(c), listingIds[i], prices[i]);
        }
    }

    /// @notice Replaces won Shapes with new ones at the same backing, paid from game capital, and lists them. Anyone.
    function restockShapes(uint256[] calldata wonShapeIds) external nonReentrant {
        uint256 fee = shapes.mintFee();
        uint256[] memory fresh = new uint256[](wonShapeIds.length);
        for (uint256 i; i < wonShapeIds.length; ++i) {
            Listing storage l = shapeListing[wonShapeIds[i]];
            uint256 backing = l.price;
            if (backing == 0 || !_clearIfWon(l)) revert NotListed(); // only Shapes FWA gave to a winner
            uint256 cost = backing + fee;
            if (address(this).balance < acquisitionBudget + cost) revert BudgetExceeded();
            fresh[i] = shapes.mintBatchTo{value: cost}(backing, 1, address(this));
            emit Restocked(wonShapeIds[i], fresh[i], backing);
        }
        _listShapes(fresh);
    }

    /// @dev A record whose listing is still in the draw blocks relisting. A record whose listing FWA has since given
    ///      to a winner is stale, so it is cleared. Returns true if it cleared one.
    function _clearIfWon(Listing storage l) internal returns (bool) {
        if (l.controller == address(0)) return false;
        if (IController(l.controller).isListed(l.listingId)) revert AlreadyListed();
        delete l.controller;
        delete l.listingId;
        delete l.price;
        return true;
    }

    // ------------------------------------------------------------------ survival, decay and composition

    /// @notice Allocating draws a Check has survived at its current tier, across pools.
    function survivedDraws(uint256 tokenId) public view returns (uint256 draws) {
        draws = carriedDraws[tokenId];
        Listing memory l = checkListing[tokenId];
        if (l.controller != address(0)) draws += IController(l.controller).survived(l.listingId);
    }

    /// @notice Notional for a tier after `survived` draws: the schedule, falling linearly to the floor (D005).
    function _notional(uint8 tier, uint256 survived) internal view returns (uint256) {
        uint256 drop = survived * params.decayBpsPerDraw;
        uint256 share = drop >= BPS - params.floorBps ? params.floorBps : BPS - drop;
        return tierNotional[tier] * share / BPS;
    }

    /// @notice Moves listed Checks to their current rule price (decay, or a new schedule). Anyone; empty queue only.
    /// @dev Skips changes smaller than `repriceStepBps` unless the target is the floor or the schedule itself, which
    ///      bounds FWA inventory churn without stranding a Check above its floor.
    function reprice(uint256[] calldata tokenIds) external {
        IController c = controller;
        if (c.unsettled() != 0) revert QueueBusy();
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            Listing storage l = checkListing[id];
            if (l.controller != address(c) || !c.isListed(l.listingId)) revert NotListed();
            uint8 tier = checks.getCheck(id).stored.divisorIndex;
            uint256 survived = survivedDraws(id);
            uint256 target = _notional(tier, survived);
            uint256 old = l.price;
            if (target == old || target == 0) continue;
            uint256 diff = target > old ? target - old : old - target;
            bool boundary = target == tierNotional[tier] * params.floorBps / BPS || target == tierNotional[tier];
            if (!boundary && diff * BPS < old * params.repriceStepBps) continue;
            c.reprice(l.listingId, target);
            l.price = uint128(target);
            emit Repriced(id, old, target, survived);
        }
    }

    function eligible(uint256 tokenId) public view returns (bool) {
        return _isLiveHere(tokenId) && _readyAt(tokenId, 0);
    }

    function _isLiveHere(uint256 tokenId) internal view returns (bool) {
        Listing memory l = checkListing[tokenId];
        return l.controller == address(controller) && l.controller != address(0)
            && IController(l.controller).isListed(l.listingId);
    }

    /// @dev Survived at least the tier threshold plus `extra` (and at least one draw).
    function _readyAt(uint256 tokenId, uint256 extra) internal view returns (bool) {
        uint8 tier = checks.getCheck(tokenId).stored.divisorIndex;
        if (tier >= BLACK) return false;
        uint256 draws = survivedDraws(tokenId);
        return draws != 0 && draws >= drawsToCompose[tier] + extra;
    }

    /// @notice Composes two eligible same-tier Checks; `keep` survives and is relisted at its new tier with a fresh
    ///         episode. Anyone. Choosing freely burns `composeBurn[tier]` coin from the caller in the same
    ///         transaction. It is free once both have survived `graceDraws` more than the threshold and the caller
    ///         takes the deterministic outcome: no swap, and `keep` is the one with more survived draws (lower ID on
    ///         a tie). A failed composition burns nothing (the whole transaction reverts).
    function compose(uint256 keep, uint256 burn, bool swap) external nonReentrant {
        if (!eligible(keep) || !eligible(burn)) revert NotEligible();
        uint8 tier = checks.getCheck(keep).stored.divisorIndex;
        uint256 burned;
        bool deterministic = !swap && _first(keep, burn) == keep;
        if (!(deterministic && _readyAt(keep, params.graceDraws) && _readyAt(burn, params.graceDraws))) {
            burned = composeBurn[tier];
        }
        uint256[] memory ids = new uint256[](2);
        ids[0] = keep;
        ids[1] = burn;
        _withdrawChecks(controller, ids);
        checks.composite(keep, burn, swap); // canonical rules: same tier <= 5, distinct, owned here
        if (burned != 0) coin.burnFrom(msg.sender, burned); // same transaction: any failure burns nothing
        delete carriedDraws[keep];
        delete carriedDraws[burn];
        emit Composed(msg.sender, keep, burn, tier + 1, burned);
        _relist(keep);
    }

    function _first(uint256 a, uint256 b) internal view returns (uint256) {
        uint256 sa = survivedDraws(a);
        uint256 sb = survivedDraws(b);
        if (sa != sb) return sa > sb ? a : b;
        return a < b ? a : b;
    }

    /// @notice Forms a Black Check from 64 eligible singles; `tokenIds[0]` survives. Anyone. Burns
    ///         `composeBurn[6]` coin unless every single is past the grace and the IDs are strictly ascending
    ///         (deterministic: the lowest ID survives).
    function formBlack(uint256[] calldata tokenIds) external nonReentrant {
        if (tokenIds.length != 64) revert BadInput();
        bool free = true;
        for (uint256 i; i < 64; ++i) {
            uint256 id = tokenIds[i];
            if (!eligible(id) || checks.getCheck(id).stored.divisorIndex != SINGLE) revert NotEligible();
            if (!_readyAt(id, params.graceDraws) || (i != 0 && id <= tokenIds[i - 1])) free = false;
        }
        uint256 burned = free ? 0 : composeBurn[SINGLE];
        _withdrawChecks(controller, tokenIds);
        checks.infinity(tokenIds);
        if (burned != 0) coin.burnFrom(msg.sender, burned);
        for (uint256 i; i < 64; ++i) delete carriedDraws[tokenIds[i]];
        emit BlackCheck(msg.sender, tokenIds[0], tokenIds[1:], burned);
        _relist(tokenIds[0]);
    }

    function _relist(uint256 tokenId) internal {
        uint256 price = _notional(checks.getCheck(tokenId).stored.divisorIndex, 0);
        if (price == 0) return; // stays in custody until the schedule lists its tier
        IController c = controller;
        uint256[] memory ids = new uint256[](1);
        uint256[] memory prices = new uint256[](1);
        ids[0] = tokenId;
        prices[0] = price;
        checks.transferFrom(address(this), address(c), tokenId);
        uint256 listingId = c.list(address(checks), ids, prices)[0];
        checkListing[tokenId] = Listing(address(c), uint64(listingId), uint128(price));
        emit Listed(address(checks), tokenId, address(c), listingId, price);
    }

    /// @dev Withdraws listed Checks from `c` back here, carrying their survived draws. Needs an empty queue.
    function _withdrawChecks(IController c, uint256[] memory tokenIds) internal {
        if (c.unsettled() != 0) revert QueueBusy();
        uint256[] memory listingIds = new uint256[](tokenIds.length);
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            Listing memory l = checkListing[id];
            if (l.controller != address(c)) revert NotListed();
            carriedDraws[id] += uint32(c.survived(l.listingId));
            listingIds[i] = l.listingId;
            delete checkListing[id];
            emit Unlisted(address(checks), id, address(c), l.listingId);
        }
        c.withdraw(listingIds);
        for (uint256 i; i < tokenIds.length; ++i) {
            if (checks.ownerOf(tokenIds[i]) != address(this)) revert NotHeld();
        }
    }

    // ------------------------------------------------------------------ direct sales and acquisitions

    /// @notice Buys a Check outright for exactly the schedule price x (1 + buyout markup). Same terms for everyone;
    ///         unavailable while halted, while the Check's draw queue is busy, or once FWA has given it to a winner.
    function buyWithEth(uint256 tokenId) external payable nonReentrant {
        uint8 tier = checks.getCheck(tokenId).stored.divisorIndex;
        uint256 price = ethPrice(tier);
        if (msg.value != price || price == 0) revert WrongPayment();
        acquisitionBudget += price;
        _release(tokenId);
        emit Bought(msg.sender, tokenId, tier, price, 0);
    }

    /// @notice Buys a Check outright by burning the tier's coin price from the caller (D006). The coin is destroyed;
    ///         no ETH is received and the Check leaves the protocol (inventory depletion, not revenue).
    function buyWithCoin(uint256 tokenId) external nonReentrant {
        uint8 tier = checks.getCheck(tokenId).stored.divisorIndex;
        uint256 amount = coinPrice[tier];
        if (amount == 0) revert TierNotListed();
        coin.burnFrom(msg.sender, amount);
        _release(tokenId);
        emit Bought(msg.sender, tokenId, tier, 0, amount);
    }

    function ethPrice(uint8 tier) public view returns (uint256) {
        return tierNotional[tier] * (BPS + params.buyoutMarkupBps) / BPS;
    }

    /// @dev Takes `tokenId` out of the draw (or custody) and sends it to the caller.
    function _release(uint256 tokenId) internal {
        if (halted) revert Halt();
        Listing memory l = checkListing[tokenId];
        if (l.controller != address(0)) {
            if (!IController(l.controller).isListed(l.listingId)) revert NotListed(); // already won
            uint256[] memory ids = new uint256[](1);
            ids[0] = tokenId;
            _withdrawChecks(IController(l.controller), ids);
        }
        if (checks.ownerOf(tokenId) != address(this)) revert NotHeld();
        delete carriedDraws[tokenId];
        checks.transferFrom(address(this), msg.sender, tokenId);
    }

    /// @notice Sells a Check to the protocol at the standing bid (schedule x bid share). The seller must have
    ///         approved the engine. Paid from the acquisition budget, within the weekly cap.
    function sellCheck(uint256 tokenId) external nonReentrant {
        uint8 tier = checks.getCheck(tokenId).stored.divisorIndex;
        checks.transferFrom(msg.sender, address(this), tokenId); // the seller must own it or be approved
        _payBid(tokenId, tier, false);
    }

    /// @notice Sells a Checks Edition, which the engine migrates to an 80-Check Original (listed after its reveal).
    function sellEdition(uint256 editionId) external nonReentrant {
        editions.transferFrom(msg.sender, address(this), editionId);
        if (!editions.isApprovedForAll(address(this), address(checks))) {
            editions.setApprovalForAll(address(checks), true); // Checks burns the Edition itself
        }
        uint256[] memory ids = new uint256[](1);
        ids[0] = editionId;
        checks.mint(ids, address(this)); // the Original keeps the Edition's ID
        _payBid(editionId, 0, true);
    }

    function _payBid(uint256 tokenId, uint8 tier, bool fromEdition) internal {
        if (halted) revert Halt();
        uint256 bid = tierNotional[tier] * params.bidBps / BPS;
        if (bid == 0) revert TierNotListed();
        uint64 week = uint64(block.timestamp / 1 weeks);
        if (week != bidWeek) {
            bidWeek = week;
            bidSpentThisWeek = 0;
        }
        if (bidSpentThisWeek + bid > params.bidWeeklyCap || bid > acquisitionBudget) revert BudgetExceeded();
        bidSpentThisWeek += uint128(bid);
        acquisitionBudget -= bid;
        emit Acquired(msg.sender, tokenId, fromEdition, tier, bid);
        (bool ok,) = msg.sender.call{value: bid}("");
        if (!ok) revert PayFailed();
    }

    /// @notice Adds ETH to the acquisition budget (coin trading fees route here). Anyone.
    function fundAcquisitions() external payable {
        acquisitionBudget += msg.value;
        emit Funded(msg.sender, msg.value);
    }

    // ------------------------------------------------------------------ migration and proceeds

    /// @notice Brings Checks back from a retired pool, keeping their survived draws. Anyone.
    function migrateChecks(address retired, uint256[] calldata tokenIds) external nonReentrant {
        if (!isRetired[retired]) revert UnknownController();
        _withdrawChecks(IController(retired), tokenIds);
    }

    function migrateShapes(address retired, uint256[] calldata shapeIds) external nonReentrant {
        if (!isRetired[retired]) revert UnknownController();
        IController c = IController(retired);
        if (c.unsettled() != 0) revert QueueBusy();
        uint256[] memory listingIds = new uint256[](shapeIds.length);
        for (uint256 i; i < shapeIds.length; ++i) {
            Listing memory l = shapeListing[shapeIds[i]];
            if (l.controller != retired) revert NotListed();
            listingIds[i] = l.listingId;
            delete shapeListing[shapeIds[i]];
            emit Unlisted(address(shapes), shapeIds[i], retired, l.listingId);
        }
        c.withdraw(listingIds);
    }

    /// @notice Moves a controller's FWA owner proceeds here (game capital). Anyone.
    function collect(address c) external nonReentrant returns (uint256) {
        if (c != address(controller) && !isRetired[c]) revert UnknownController();
        return IController(c).collect();
    }

    /// @notice Takes back a Check whose FWA delivery failed and was refunded to the winner. Anyone.
    function recoverCheck(address c, uint256 tokenId) external nonReentrant {
        Listing memory l = checkListing[tokenId];
        if (l.controller != c || c == address(0)) revert NotListed();
        delete checkListing[tokenId];
        delete carriedDraws[tokenId];
        IController(c).recover(l.listingId);
        if (checks.ownerOf(tokenId) != address(this)) revert NotHeld();
        emit Unlisted(address(checks), tokenId, c, l.listingId);
    }

    // ------------------------------------------------------------------ authority

    /// @notice Stops new draws, buyouts and the bid. Operator or guardian. Settlement, refunds, deliveries and
    ///         maintenance on settled state (composition, repricing, migration, collection) continue: a halt protects
    ///         participants from trading at stale prices, it does not freeze the protocol.
    function halt() external {
        if (msg.sender != operator && msg.sender != guardian) revert NotAllowed();
        halted = true;
        controller.setPurchases(false);
        emit Halted(msg.sender, true);
    }

    /// @notice Reopens draws. Guardian or timelock only, so the operator cannot override a guardian halt.
    function resume() external {
        if (msg.sender != guardian && msg.sender != timelock) revert NotAllowed();
        halted = false;
        controller.setPurchases(true);
        emit Halted(msg.sender, false);
    }

    /// @notice Approves the controller of a new pool (possibly a new FWA version) and retires the current one: its
    ///         purchases stop, pending draws settle there, and its inventory can then be migrated by anyone.
    function setController(IController next) external onlyTimelock {
        address old = address(controller);
        if (old != address(0)) {
            isRetired[old] = true;
            IController(old).setPurchases(false);
        }
        controller = next;
        halted = true;
        emit ControllerSet(address(next), old);
    }

    function setSchedule(
        uint256[TIERS] calldata tierNotional_,
        uint32[7] calldata drawsToCompose_,
        uint256[7] calldata composeBurn_,
        uint256[TIERS] calldata coinPrice_
    ) external onlyTimelock {
        _setSchedule(tierNotional_, drawsToCompose_, composeBurn_, coinPrice_);
    }

    function _setSchedule(
        uint256[TIERS] calldata tierNotional_,
        uint32[7] calldata drawsToCompose_,
        uint256[7] calldata composeBurn_,
        uint256[TIERS] calldata coinPrice_
    ) internal {
        for (uint256 t; t < TIERS; ++t) {
            if (tierNotional_[t] > type(uint128).max) revert BadInput();
        }
        tierNotional = tierNotional_;
        drawsToCompose = drawsToCompose_;
        composeBurn = composeBurn_;
        coinPrice = coinPrice_;
        emit ScheduleSet();
    }

    function setParams(Params calldata p) external onlyTimelock {
        _setParams(p);
    }

    function _setParams(Params calldata p) internal {
        if (
            p.shapeMarkupBps > 5000 || p.decayBpsPerDraw > 100 || p.floorBps < 5000 || p.floorBps > BPS
                || p.repriceStepBps > 2000 || p.buyoutMarkupBps < 1000 || p.bidBps > BPS
        ) revert BadInput();
        params = p;
        emit ParamsSet();
    }

    function setOperator(address account) external onlyTimelock {
        operator = account;
        emit RoleSet("operator", account);
    }

    function setGuardian(address account) external onlyTimelock {
        guardian = account;
        emit RoleSet("guardian", account);
    }

    function _authorizeUpgrade(address) internal view override onlyTimelock {}

    // ------------------------------------------------------------------ receiving

    /// @dev Accepts any NFT. Unexpected ones stay here with no exit (quarantine), since no sweep exists.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /// @dev Game capital: FWA proceeds (via controllers) and Shape redemptions. Acquisition money uses `fundAcquisitions`.
    receive() external payable {}
}
