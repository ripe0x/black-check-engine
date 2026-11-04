// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IAcquisitionAdapter} from "../interfaces/ICollectionGames.sol";

/// @dev Seaport 1.6 order structures (ConsiderationStructs.sol), the subset this adapter needs.
library SeaportTypes {
    enum OrderType {
        FULL_OPEN,
        PARTIAL_OPEN,
        FULL_RESTRICTED,
        PARTIAL_RESTRICTED,
        CONTRACT
    }

    enum ItemType {
        NATIVE,
        ERC20,
        ERC721,
        ERC1155,
        ERC721_WITH_CRITERIA,
        ERC1155_WITH_CRITERIA
    }

    enum Side {
        OFFER,
        CONSIDERATION
    }

    struct OfferItem {
        ItemType itemType;
        address token;
        uint256 identifierOrCriteria;
        uint256 startAmount;
        uint256 endAmount;
    }

    struct ConsiderationItem {
        ItemType itemType;
        address token;
        uint256 identifierOrCriteria;
        uint256 startAmount;
        uint256 endAmount;
        address payable recipient;
    }

    struct OrderParameters {
        address offerer;
        address zone;
        OfferItem[] offer;
        ConsiderationItem[] consideration;
        OrderType orderType;
        uint256 startTime;
        uint256 endTime;
        bytes32 zoneHash;
        uint256 salt;
        bytes32 conduitKey;
        uint256 totalOriginalConsiderationItems;
    }

    struct AdvancedOrder {
        OrderParameters parameters;
        uint120 numerator;
        uint120 denominator;
        bytes signature;
        bytes extraData;
    }

    struct CriteriaResolver {
        uint256 orderIndex;
        Side side;
        uint256 index;
        uint256 identifier;
        bytes32[] criteriaProof;
    }
}

interface ISeaport {
    function fulfillAdvancedOrder(
        SeaportTypes.AdvancedOrder calldata advancedOrder,
        SeaportTypes.CriteriaResolver[] calldata criteriaResolvers,
        bytes32 fulfillerConduitKey,
        address recipient
    ) external payable returns (bool fulfilled);
}

/// @title SeaportAdapter
/// @notice Marketplace route for FundingVault acquisitions: fills one Seaport 1.6 order that sells exactly one
///         ERC-721 of the configured collection for native ETH only, delivering the NFT straight to the pool owner's
///         custody, and returns every unspent wei of the vault's payment in the same call. Holds none of the vault's ETH
///         between calls; ETH anyone else sends it stays here (there is no withdrawal) and never reaches a fill.
/// @dev Checks before calling Seaport: one offer item, ERC-721, the expected collection and token ID, amount 1;
///      a signed (not CONTRACT) order with exactly the seller's signed consideration items (no fulfiller tips), each native ETH and none paying the vault
///      or custody; their total (the higher of start and end amount) within the ETH the
///      vault sent. Seaport verifies the signature (or on-chain validation), the order status and time window, and
///      pays every consideration recipient (seller, marketplace fee, creator royalty if the order includes one).
///      Royalties are paid exactly as the order specifies; the adapter adds none. The vault then checks custody and
///      the amount spent. Only the vault may call (a registered adapter is reachable only through `fillOrder`).
contract SeaportAdapter is IAcquisitionAdapter {
    ISeaport public immutable seaport;
    address public immutable vault;

    error NotVault();
    error BadOrder();

    constructor(address seaport_, address vault_) {
        seaport = ISeaport(seaport_);
        vault = vault_;
    }

    receive() external payable {}

    function execute(address collection, uint256 tokenId, address recipient, bytes calldata data)
        external
        payable
        returns (uint256 spent)
    {
        if (msg.sender != vault) revert NotVault();
        SeaportTypes.AdvancedOrder memory order = abi.decode(data, (SeaportTypes.AdvancedOrder));
        SeaportTypes.OrderParameters memory p = order.parameters;
        if (
            p.offer.length != 1 || p.offer[0].itemType != SeaportTypes.ItemType.ERC721 || p.offer[0].token != collection
                || p.offer[0].identifierOrCriteria != tokenId || p.offer[0].startAmount != 1 || p.offer[0].endAmount != 1
        ) revert BadOrder();
        // Seaport lets the fulfiller append consideration items past the signed ones (tips), unsigned by the seller:
        // the caller could pay itself from the vault's cap, or pay the vault back and inflate the booked price.
        // Only the seller's signed items are filled, and none of them may pay the vault or custody,
        // whose ETH returns to the vault as a contribution while the fill books it as spent.
        // A CONTRACT order has no signature: its offerer's `generateOrder` sets the consideration Seaport actually pays,
        // so the checks below would not bind it.
        if (
            p.orderType == SeaportTypes.OrderType.CONTRACT || p.consideration.length != p.totalOriginalConsiderationItems
        ) revert BadOrder();
        uint256 total;
        for (uint256 i; i < p.consideration.length; ++i) {
            SeaportTypes.ConsiderationItem memory c = p.consideration[i];
            if (c.itemType != SeaportTypes.ItemType.NATIVE || c.token != address(0)) revert BadOrder();
            if (c.recipient == vault || c.recipient == recipient) revert BadOrder();
            total += c.startAmount > c.endAmount ? c.startAmount : c.endAmount;
        }
        if (total > msg.value) revert BadOrder();
        SeaportTypes.CriteriaResolver[] memory none;
        uint256 before = address(this).balance;
        if (!seaport.fulfillAdvancedOrder{value: total}(order, none, bytes32(0), recipient)) revert BadOrder();
        spent = before - address(this).balance;
        // only what is left of the vault's payment goes back: ETH sent here by anyone else stays here, so it can
        // neither block a fill nor change the price the vault books
        SafeTransferLib.forceSafeTransferETH(vault, msg.value - spent);
    }
}
