// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFWAPool, IFWAFactory, IPurchaseOperator, FWA_ACQUISITIONS_ENABLED} from "../interfaces/IFWA.sol";
import {IController} from "../interfaces/IController.sol";

interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IERC721Min {
    function ownerOf(uint256 tokenId) external view returns (address);
    function setApprovalForAll(address operator, bool approved) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @notice Permanent owner of one FWA V2 standard pool, acting only for the engine.
/// @dev FWA pool ownership can never change and each address may create one pool, so this contract is immutable and
///      narrow: every pool action is one engine-only function, withdrawals and recovered NFTs go only to `engine`,
///      and proceeds are forwarded only to `engine`. It has no generic call and approves only its own pool, for the
///      two collections it can list. The pool address is predicted at construction from the pinned implementation;
///      `open` refuses any other result.
///
///      Survival (C010, D002): this contract is the pool's only depositor and lists only into an empty queue, so FWA
///      activates every listing at once and never stages one. FWA then removes an active listing in exactly two
///      ways (`_settleAndRemove`): a withdrawal by this contract, or a draw allocating that listing as its prize. So
///      prize-allocating draws = listed - withdrawn - `activeListingCount()`, read from FWA state with no per-draw
///      work, and a listing still Active has survived every allocation since its entry.
contract FwaV2Controller is IController, IPurchaseOperator {
    address public immutable engine;
    IFWAFactory public immutable factory;
    address public immutable implementation;
    bytes32 public immutable salt;
    address public immutable fwaToken;
    address public immutable checks;
    address public immutable shapes;
    IFWAPool public immutable pool;

    /// @notice FWA's inventory batch limit (`MAX_INVENTORY_BATCH`).
    uint256 public constant BATCH = 20;

    uint256 public listed;
    uint256 public withdrawn;
    /// @notice `allocated()` when the listing entered, plus one (zero: not listed by this contract).
    mapping(uint256 listingId => uint256) internal entryPlusOne;

    event EpisodeStarted(uint256 indexed listingId, uint256 entry);

    error NotEngine();
    error PoolMismatch();
    error UnknownCollection();
    error NotHeld();
    error QueueBusy();
    error NotActive();
    error Forward();

    modifier onlyEngine() {
        if (msg.sender != engine) revert NotEngine();
        _;
    }

    constructor(
        address engine_,
        IFWAFactory factory_,
        address implementation_,
        bytes32 salt_,
        address checks_,
        address shapes_
    ) {
        engine = engine_;
        factory = factory_;
        implementation = implementation_;
        salt = salt_;
        fwaToken = factory_.fwaToken();
        checks = checks_;
        shapes = shapes_;
        pool = IFWAPool(factory_.predictPoolAddress(address(this), salt_));
    }

    /// @dev The FWA creation fee must already be held here (FWA is transfer-locked; it is bought into this address).
    function open() external onlyEngine {
        uint256 fee = factory.poolCreationFee();
        IERC20Approve(fwaToken).approve(address(factory), fee);
        if (factory.createPool(salt, fee, implementation) != address(pool)) revert PoolMismatch();
        pool.setPurchaseOperator(address(this));
        IERC721Min(checks).setApprovalForAll(address(pool), true);
        IERC721Min(shapes).setApprovalForAll(address(pool), true);
    }

    function list(address collection, uint256[] calldata tokenIds, uint256[] calldata prices)
        external
        onlyEngine
        returns (uint256[] memory listingIds)
    {
        if (collection != checks && collection != shapes) revert UnknownCollection();
        // An empty queue makes FWA activate each listing immediately (no staging), which the survival rule needs.
        if (pool.unsettledAcquisitionCount() != 0) revert QueueBusy();
        uint256 n = tokenIds.length;
        listingIds = new uint256[](n);
        for (uint256 start; start < n; start += BATCH) {
            uint256 m = n - start < BATCH ? n - start : BATCH;
            IFWAPool.ListingInput[] memory items = new IFWAPool.ListingInput[](m);
            for (uint256 j; j < m; ++j) {
                uint256 id = tokenIds[start + j];
                if (IERC721Min(collection).ownerOf(id) != address(this)) revert NotHeld();
                items[j] = IFWAPool.ListingInput(collection, id, prices[start + j]);
            }
            uint256[] memory ids = pool.listNFTs(items);
            listed += m;
            uint256 entry = allocated();
            for (uint256 j; j < m; ++j) {
                (,,,,,,, IFWAPool.ListingStatus st) = pool.listings(ids[j]);
                if (st != IFWAPool.ListingStatus.Active) revert NotActive();
                entryPlusOne[ids[j]] = entry + 1;
                listingIds[start + j] = ids[j];
                emit EpisodeStarted(ids[j], entry);
            }
        }
    }

    /// @dev Only Active listings can be withdrawn here (this contract never stages), so each one lowers FWA's
    ///      active count by one, matched by `withdrawn`.
    function withdraw(uint256[] calldata listingIds) external onlyEngine {
        uint256 n = listingIds.length;
        for (uint256 start; start < n; start += BATCH) {
            uint256 m = n - start < BATCH ? n - start : BATCH;
            uint256[] memory chunk = new uint256[](m);
            for (uint256 j; j < m; ++j) chunk[j] = listingIds[start + j];
            pool.withdrawListingsTo(chunk, engine);
            withdrawn += m;
        }
    }

    function reprice(uint256 listingId, uint256 price) external onlyEngine {
        pool.updatePrice(listingId, price);
    }

    function setPurchases(bool enabled) external onlyEngine {
        pool.setBool(FWA_ACQUISITIONS_ENABLED, enabled);
    }

    function collect() external onlyEngine returns (uint256 amount) {
        if (pool.ownerProceeds() != 0) pool.withdrawOwnerProceeds();
        amount = address(this).balance;
        if (amount != 0) {
            (bool ok,) = engine.call{value: amount}("");
            if (!ok) revert Forward();
        }
    }

    function recover(uint256 listingId) external onlyEngine {
        (address collection,,, uint256 tokenId,,,,) = pool.listings(listingId);
        pool.recoverRefundedNFT(listingId);
        IERC721Min(collection).transferFrom(address(this), engine, tokenId);
    }

    /// @notice FWA's purchase gate, staticcalled before every purchase. Refuses purchasers that would put a won prize
    ///         beyond recovery: Shapes rejects receiving its own tokens, so a won Shape would sit in FWA's delivery
    ///         quarantine with no purchaser able to claim the refund that frees it (Checks is refused on the same
    ///         ground); the pool, this contract and the engine would hold a prize FWA records as delivered. Every other
    ///         address may buy (audit H2).
    function canPurchase(address purchaser) external view returns (bool) {
        return purchaser != shapes && purchaser != checks && purchaser != address(pool) && purchaser != address(this)
            && purchaser != engine;
    }

    /// @notice Draws that allocated a prize in this pool since it opened.
    function allocated() public view returns (uint256) {
        return listed - withdrawn - pool.activeListingCount();
    }

    function isListed(uint256 listingId) public view returns (bool) {
        if (entryPlusOne[listingId] == 0) return false;
        (,,,,,,, IFWAPool.ListingStatus st) = pool.listings(listingId);
        return st == IFWAPool.ListingStatus.Active;
    }

    function survived(uint256 listingId) external view returns (uint256) {
        if (!isListed(listingId)) return 0;
        return allocated() - (entryPlusOne[listingId] - 1);
    }

    function unsettled() external view returns (uint256) {
        return pool.unsettledAcquisitionCount();
    }

    /// @dev Only FWA owner proceeds arrive here, and `collect` forwards them in the same call.
    receive() external payable {
        if (msg.sender != address(pool)) revert Forward();
    }
}
