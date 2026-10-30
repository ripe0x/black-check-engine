// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFWAPool, IFWAFactory, FWA_ACQUISITIONS_ENABLED} from "../interfaces/IFWA.sol";
import {IController} from "../interfaces/IController.sol";
import {SurvivalCursor} from "../game/SurvivalCursor.sol";

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
contract FwaV2Controller is IController, SurvivalCursor {
    address public immutable engine;
    IFWAFactory public immutable factory;
    address public immutable implementation;
    bytes32 public immutable salt;
    address public immutable fwaToken;
    address public immutable checks;
    address public immutable shapes;

    /// @notice Sequences counted inside `list` before it gives up; anyone can call `advance` to catch up first.
    uint256 public constant LIST_ADVANCE = 64;

    error NotEngine();
    error PoolMismatch();
    error UnknownCollection();
    error NotHeld();
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
    ) SurvivalCursor(IFWAPool(factory_.predictPoolAddress(address(this), salt_)), address(0)) {
        engine = engine_;
        factory = factory_;
        implementation = implementation_;
        salt = salt_;
        fwaToken = factory_.fwaToken();
        checks = checks_;
        shapes = shapes_;
    }

    /// @dev The FWA creation fee must already be held here (FWA is transfer-locked; it is bought into this address).
    function open() external onlyEngine {
        uint256 fee = factory.poolCreationFee();
        IERC20Approve(fwaToken).approve(address(factory), fee);
        if (factory.createPool(salt, fee, implementation) != address(pool)) revert PoolMismatch();
        IERC721Min(checks).setApprovalForAll(address(pool), true);
        IERC721Min(shapes).setApprovalForAll(address(pool), true);
    }

    function list(address collection, uint256[] calldata tokenIds, uint256[] calldata prices)
        external
        onlyEngine
        returns (uint256[] memory listingIds)
    {
        if (collection != checks && collection != shapes) revert UnknownCollection();
        IFWAPool.ListingInput[] memory items = new IFWAPool.ListingInput[](tokenIds.length);
        for (uint256 i; i < tokenIds.length; ++i) {
            if (IERC721Min(collection).ownerOf(tokenIds[i]) != address(this)) revert NotHeld();
            items[i] = IFWAPool.ListingInput(collection, tokenIds[i], prices[i]);
        }
        advance(LIST_ADVANCE);
        listingIds = pool.listNFTs(items);
        for (uint256 i; i < listingIds.length; ++i) {
            _startEpisode(listingIds[i]);
        }
    }

    function withdraw(uint256[] calldata listingIds) external onlyEngine {
        pool.withdrawListingsTo(listingIds, engine);
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

    function survived(uint256 listingId) public view override(IController, SurvivalCursor) returns (uint256) {
        return SurvivalCursor.survived(listingId);
    }

    function caughtUp() public view override(IController, SurvivalCursor) returns (bool) {
        return SurvivalCursor.caughtUp();
    }

    function unsettled() external view returns (uint256) {
        return pool.unsettledAcquisitionCount();
    }

    function advance(uint256 maxCount) public override(IController, SurvivalCursor) returns (uint256) {
        return SurvivalCursor.advance(maxCount);
    }

    /// @dev Only FWA owner proceeds arrive here, and `collect` forwards them in the same call.
    receive() external payable {
        if (msg.sender != address(pool)) revert Forward();
    }
}
