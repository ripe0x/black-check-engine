// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IController} from "../interfaces/IController.sol";
import {IChecksOriginals} from "../interfaces/IChecks.sol";

interface IShapesBacking {
    function backingOf(uint256 tokenId) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @notice Custody and lifecycle of the protocol's Checks and Shapes. Upgradeable only through the timelock.
/// @dev Asset exits, exhaustively: an NFT moves to the current controller to be listed, comes back from a controller,
///      or is consumed by canonical Checks composition. ETH only arrives in this version. The engine never grants an
///      approval and has no generic call. Every listing price comes from the timelocked tier schedule (Checks) or
///      the Shape's own backing and the timelocked markup; no caller supplies a price. Maintenance needs the pool's draw queue to be empty.
///      Storage is append-only across upgrades.
contract Engine is Initializable, UUPSUpgradeable {
    uint8 internal constant TIERS = 8; // divisorIndex 0 (80 checks) .. 7 (Black)
    uint8 internal constant SINGLE = 6;
    uint8 internal constant BLACK = 7;
    uint16 public constant MAX_SHAPE_MARKUP_BPS = 5000;

    IChecksOriginals public immutable checks;
    IShapesBacking public immutable shapes;

    address public timelock;
    address public operator;
    address public guardian;
    bool public halted;

    IController public controller;
    mapping(address controller => bool) public isRetired;

    /// @notice FWA notional at listing, per Checks tier (wei). Zero means that tier is not listed.
    uint256[TIERS] public tierNotional;
    /// @notice Allocating draws a Check must survive at its tier before it can be composed (index 6: Black).
    uint32[7] public drawsToCompose;

    struct Listing {
        address controller;
        uint64 listingId;
    }

    mapping(uint256 tokenId => Listing) public checkListing;
    /// @notice Draws survived in earlier listings of the current tier (carried across migrations).
    mapping(uint256 tokenId => uint32) public carriedDraws;
    mapping(uint256 shapeId => Listing) public shapeListing;
    /// @notice Shapes list at backing x (1 + markup): a won Shape costs its backing plus the Shapes mint fee (D004).
    uint16 public shapeMarkupBps;

    event ControllerSet(address indexed controller, address indexed retired);
    event Listed(address indexed collection, uint256 indexed tokenId, address indexed controller, uint256 listingId, uint256 price);
    event Unlisted(address indexed collection, uint256 indexed tokenId, address indexed controller, uint256 listingId);
    event Composed(address indexed by, uint256 indexed survivor, uint256 indexed burned, uint8 tier);
    event BlackCheck(address indexed by, uint256 indexed survivor, uint256[] burned);
    event Halted(address indexed by, bool halted);
    event RoleSet(bytes32 indexed role, address indexed account);
    event ScheduleSet(uint256[TIERS] tierNotional, uint32[7] drawsToCompose);
    event ShapeMarkupSet(uint16 bps);

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

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert NotTimelock();
        _;
    }

    constructor(IChecksOriginals checks_, IShapesBacking shapes_) {
        checks = checks_;
        shapes = shapes_;
        _disableInitializers();
    }

    function initialize(
        address timelock_,
        address operator_,
        address guardian_,
        IController controller_,
        uint256[TIERS] calldata tierNotional_,
        uint32[7] calldata drawsToCompose_,
        uint16 shapeMarkupBps_
    ) external initializer {
        if (shapeMarkupBps_ > MAX_SHAPE_MARKUP_BPS) revert BadInput();
        shapeMarkupBps = shapeMarkupBps_;
        timelock = timelock_;
        operator = operator_;
        guardian = guardian_;
        controller = controller_;
        tierNotional = tierNotional_;
        drawsToCompose = drawsToCompose_;
        // Purchases start off: the game opens when the guardian or timelock calls `resume`.
        halted = true;
        emit ControllerSet(address(controller_), address(0));
        emit ScheduleSet(tierNotional_, drawsToCompose_);
    }

    // ------------------------------------------------------------------ pool

    /// @notice Creates the current controller's pool. Anyone; the controller refuses a second pool.
    function openPool() external {
        controller.open();
    }

    /// @notice Lists custody Checks at their tier's notional. Anyone; only revealed Originals at listed tiers.
    function listChecks(uint256[] calldata tokenIds) external {
        IController c = controller;
        uint256[] memory prices = new uint256[](tokenIds.length);
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            if (_clearIfWon(checkListing[id])) delete carriedDraws[id]; // a Check that left and came back starts anew
            IChecksOriginals.Check memory info = checks.getCheck(id);
            if (!info.isRevealed) revert NotRevealed();
            uint256 price = tierNotional[info.stored.divisorIndex];
            if (price == 0) revert TierNotListed();
            prices[i] = price;
            checks.transferFrom(address(this), address(c), id); // reverts unless held here
        }
        uint256[] memory listingIds = c.list(address(checks), tokenIds, prices);
        for (uint256 i; i < tokenIds.length; ++i) {
            checkListing[tokenIds[i]] = Listing(address(c), uint64(listingIds[i]));
            emit Listed(address(checks), tokenIds[i], address(c), listingIds[i], prices[i]);
        }
    }

    /// @notice Lists custody Shapes at exactly their ETH backing. Anyone.
    function listShapes(uint256[] calldata shapeIds) external {
        IController c = controller;
        uint256[] memory prices = new uint256[](shapeIds.length);
        for (uint256 i; i < shapeIds.length; ++i) {
            uint256 id = shapeIds[i];
            _clearIfWon(shapeListing[id]);
            prices[i] = shapes.backingOf(id) * (10_000 + shapeMarkupBps) / 10_000;
            shapes.transferFrom(address(this), address(c), id);
        }
        uint256[] memory listingIds = c.list(address(shapes), shapeIds, prices);
        for (uint256 i; i < shapeIds.length; ++i) {
            shapeListing[shapeIds[i]] = Listing(address(c), uint64(listingIds[i]));
            emit Listed(address(shapes), shapeIds[i], address(c), listingIds[i], prices[i]);
        }
    }

    /// @dev A record whose listing is still in the draw blocks relisting. A record whose listing FWA has since given to
    ///      a winner is stale (the NFT left and was sent back), so it is cleared. Returns true if it cleared one.
    function _clearIfWon(Listing storage l) internal returns (bool) {
        if (l.controller == address(0)) return false;
        if (IController(l.controller).isListed(l.listingId)) revert AlreadyListed();
        delete l.controller;
        delete l.listingId;
        return true;
    }

    // ------------------------------------------------------------------ survival and composition

    /// @notice Allocating draws a Check has survived at its current tier, across pools.
    function survivedDraws(uint256 tokenId) public view returns (uint256 draws) {
        draws = carriedDraws[tokenId];
        Listing memory l = checkListing[tokenId];
        if (l.controller != address(0)) draws += IController(l.controller).survived(l.listingId);
    }

    function eligible(uint256 tokenId) public view returns (bool) {
        Listing memory l = checkListing[tokenId];
        if (l.controller != address(controller) || l.controller == address(0)) return false;
        if (!IController(l.controller).isListed(l.listingId)) return false; // won: no longer ours
        uint8 tier = checks.getCheck(tokenId).stored.divisorIndex;
        if (tier >= BLACK) return false;
        uint256 draws = survivedDraws(tokenId);
        return draws != 0 && draws >= drawsToCompose[tier];
    }

    /// @notice Composes two eligible same-tier Checks; `keep` survives and is relisted at its new tier with a fresh
    ///         episode. Anyone. `swap` gives `keep` the burned token's visual first (canonical Checks behavior).
    function compose(uint256 keep, uint256 burn, bool swap) external {
        if (!eligible(keep) || !eligible(burn)) revert NotEligible();
        uint256[] memory ids = new uint256[](2);
        ids[0] = keep;
        ids[1] = burn;
        _withdrawChecks(controller, ids);
        uint8 tier = checks.getCheck(keep).stored.divisorIndex;
        checks.composite(keep, burn, swap); // canonical rules: same tier <= 5, distinct, owned here
        delete carriedDraws[keep];
        delete carriedDraws[burn];
        emit Composed(msg.sender, keep, burn, tier + 1);
        _relist(keep);
    }

    /// @notice Forms a Black Check from 64 eligible singles; `tokenIds[0]` survives. Anyone.
    function formBlack(uint256[] calldata tokenIds) external {
        if (tokenIds.length != 64) revert BadInput();
        for (uint256 i; i < 64; ++i) {
            if (!eligible(tokenIds[i]) || checks.getCheck(tokenIds[i]).stored.divisorIndex != SINGLE) {
                revert NotEligible();
            }
        }
        _withdrawChecks(controller, tokenIds);
        checks.infinity(tokenIds);
        for (uint256 i; i < 64; ++i) delete carriedDraws[tokenIds[i]];
        emit BlackCheck(msg.sender, tokenIds[0], tokenIds[1:]);
        _relist(tokenIds[0]);
    }

    function _relist(uint256 tokenId) internal {
        uint256 price = tierNotional[checks.getCheck(tokenId).stored.divisorIndex];
        if (price == 0) return; // stays in custody until the schedule lists its tier
        IController c = controller;
        uint256[] memory ids = new uint256[](1);
        uint256[] memory prices = new uint256[](1);
        ids[0] = tokenId;
        prices[0] = price;
        checks.transferFrom(address(this), address(c), tokenId);
        uint256 listingId = c.list(address(checks), ids, prices)[0];
        checkListing[tokenId] = Listing(address(c), uint64(listingId));
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

    // ------------------------------------------------------------------ migration and proceeds

    /// @notice Brings Checks back from a retired pool, keeping their survived draws. Anyone.
    function migrateChecks(address retired, uint256[] calldata tokenIds) external {
        if (!isRetired[retired]) revert UnknownController();
        _withdrawChecks(IController(retired), tokenIds);
    }

    function migrateShapes(address retired, uint256[] calldata shapeIds) external {
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

    /// @notice Moves a controller's FWA owner proceeds here. Anyone.
    function collect(address c) external returns (uint256) {
        if (c != address(controller) && !isRetired[c]) revert UnknownController();
        return IController(c).collect();
    }

    /// @notice Takes back a Check whose FWA delivery failed and was refunded to the winner. Anyone.
    function recoverCheck(address c, uint256 tokenId) external {
        Listing memory l = checkListing[tokenId];
        if (l.controller != c || c == address(0)) revert NotListed();
        delete checkListing[tokenId];
        delete carriedDraws[tokenId];
        IController(c).recover(l.listingId);
        if (checks.ownerOf(tokenId) != address(this)) revert NotHeld();
        emit Unlisted(address(checks), tokenId, c, l.listingId);
    }

    // ------------------------------------------------------------------ authority

    /// @notice Stops new draws. Operator or guardian. Settlement, refunds, deliveries and maintenance on settled state
    ///         (composition, migration, collection) continue: a halt protects players from new commitments, it does
    ///         not freeze the protocol.
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

    function setSchedule(uint256[TIERS] calldata tierNotional_, uint32[7] calldata drawsToCompose_)
        external
        onlyTimelock
    {
        tierNotional = tierNotional_;
        drawsToCompose = drawsToCompose_;
        emit ScheduleSet(tierNotional_, drawsToCompose_);
    }

    function setShapeMarkup(uint16 bps) external onlyTimelock {
        if (bps > MAX_SHAPE_MARKUP_BPS) revert BadInput();
        shapeMarkupBps = bps;
        emit ShapeMarkupSet(bps);
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

    receive() external payable {}
}
