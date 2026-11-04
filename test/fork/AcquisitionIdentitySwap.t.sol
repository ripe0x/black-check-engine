// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FundingForkTest} from "./Funding.t.sol";
import {SeaportTypes} from "../../src/periphery/SeaportAdapter.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";

interface ITransferableBayc {
    function transferFrom(address from, address to, uint256 tokenId) external;
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
    function setApprovalForAll(address operator, bool approved) external;
}

interface IVaultAcquisition {
    function sellToProtocol(uint256 tokenId, uint256 price) external;
    function claimStray(uint256 tokenId) external;
}

/// @dev A recipient in a seller-prevalidated Seaport order uses its ETH callback to try the custody swap.
contract InventorySwapRecipient {
    ITransferableBayc public immutable bayc;
    address public immutable custody;
    address public immutable vault;
    uint256 public immutable heldId;
    uint256 public immutable paddingId;
    bool public removalBlocked;
    bool public paddingSent;
    bool public nestedClaimBlocked;

    constructor(address collection, address custody_, address vault_, uint256 heldId_, uint256 paddingId_) {
        bayc = ITransferableBayc(collection);
        custody = custody_;
        vault = vault_;
        heldId = heldId_;
        paddingId = paddingId_;
    }

    function sell(uint256 tokenId, uint256 price) external {
        bayc.setApprovalForAll(vault, true);
        IVaultAcquisition(vault).sellToProtocol(tokenId, price);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }

    receive() external payable {
        try bayc.safeTransferFrom(custody, address(this), heldId) {} catch {
            removalBlocked = true;
        }
        bayc.transferFrom(address(this), custody, paddingId);
        paddingSent = true;
        try IVaultAcquisition(vault).claimStray(paddingId) {} catch {
            nestedClaimBlocked = true;
        }
    }
}

contract AcquisitionIdentitySwapForkTest is FundingForkTest {
    function _activateWithHeldApe() internal returns (uint256 heldId) {
        accrueFees(20 ether);
        riseBidTo(6 ether);
        sellCheckAt(nextCheckId(), 6 ether);
        accrueFees(sys.game.capitalNeed() + listingPayRoom());
        syncAll();
        assertTrue(sys.game.ready(), "opening board funded");
        sys.game.activate();

        // Keep a second registered Ape in custody while the active game is allowed to buy another one.
        heldId = nextCheckId();
        address heldDonor = bayc.ownerOf(heldId);
        vm.startPrank(heldDonor);
        bayc.setApprovalForAll(address(sys.vault), true);
        sys.vault.contributeNFT(heldId);
        vm.stopPrank();
        assertEq(bayc.ownerOf(heldId), address(sys.poolOwner));
        accrueFees(20 ether);
        riseBidTo(4.5 ether);
    }

    function _giveToRecipient(uint256 id, InventorySwapRecipient recipient) internal {
        address source = bayc.ownerOf(id);
        vm.prank(source);
        ITransferableBayc(cfg.collection).transferFrom(source, address(recipient), id);
    }

    function test_marketplaceCallbackCannotSwapRegisteredApeForPaddingApe() public {
        uint256 heldId = _activateWithHeldApe();
        uint256 heldBefore = sys.poolOwner.heldCount();
        uint256 balanceBefore = bayc.balanceOf(address(sys.poolOwner));

        uint256 offeredId = nextCheckId();
        uint256 paddingId = nextCheckId();
        InventorySwapRecipient recipient =
            new InventorySwapRecipient(cfg.collection, address(sys.poolOwner), address(sys.vault), heldId, paddingId);
        _giveToRecipient(paddingId, recipient);
        SeaportTypes.AdvancedOrder memory order = _seaportListing(offeredId, address(recipient));

        // The vault's bytes are an order, not a target address and a call payload.
        vm.prank(keeper);
        vm.expectRevert();
        sys.vault.fillOrder(
            offeredId,
            10 ether,
            abi.encodeWithSelector(
                ITransferableBayc.safeTransferFrom.selector,
                address(sys.poolOwner),
                address(recipient),
                heldId
            )
        );
        assertEq(bayc.ownerOf(heldId), address(sys.poolOwner), "raw calldata moved held Ape");

        vm.prank(keeper);
        uint256 beforeGas = gasleft();
        uint256 spent = sys.vault.fillOrder(offeredId, 10 ether, abi.encode(order));
        assertLt(beforeGas - gasleft(), 16_777_216, "marketplace fill exceeds transaction gas cap");
        assertEq(spent, 4 ether, "seller-authorized marketplace price");
        assertTrue(recipient.removalBlocked(), "callback moved registered Ape");
        assertTrue(recipient.paddingSent(), "callback did not reach padding transfer");
        assertTrue(recipient.nestedClaimBlocked(), "callback registered padding reentrantly");
        assertEq(bayc.ownerOf(heldId), address(sys.poolOwner), "registered Ape lost");
        assertEq(bayc.ownerOf(offeredId), address(sys.poolOwner), "purchased Ape not delivered");
        assertEq(bayc.ownerOf(paddingId), address(sys.poolOwner), "padding Ape not at custody");
        assertEq(bayc.balanceOf(address(sys.poolOwner)), balanceBefore + 2, "real NFT count");
        assertEq(sys.poolOwner.heldCount(), heldBefore + 1, "only bought Ape registered so far");
        assertEq(sys.vault.lastPrice(), 4 ether, "callback did not corrupt acquisition price");
        (, uint128 purchasedCash,, uint8 purchasedSource,,) = sys.poolOwner.nfts(offeredId);
        assertEq(purchasedCash, 4 ether, "marketplace Ape cash cost");
        assertEq(purchasedSource, 0, "marketplace Ape source");

        sys.vault.claimStray(paddingId);
        assertEq(sys.poolOwner.heldCount(), heldBefore + 2, "padding Ape has public registration route");
        (, uint128 paddingCash,, uint8 source,,) = sys.poolOwner.nfts(paddingId);
        assertEq(paddingCash, 0, "padding Ape recorded as donation");
        assertEq(source, 1, "padding Ape source");
    }

    function test_directSellerCallbackCannotSwapRegisteredApeOrReenterRegistration() public {
        uint256 heldId = _activateWithHeldApe();
        uint256 heldBefore = sys.poolOwner.heldCount();
        uint256 balanceBefore = bayc.balanceOf(address(sys.poolOwner));
        uint256 offeredId = nextCheckId();
        uint256 paddingId = nextCheckId();
        InventorySwapRecipient recipient =
            new InventorySwapRecipient(cfg.collection, address(sys.poolOwner), address(sys.vault), heldId, paddingId);
        _giveToRecipient(offeredId, recipient);
        _giveToRecipient(paddingId, recipient);

        uint256 beforeGas = gasleft();
        recipient.sell(offeredId, 1);
        assertLt(beforeGas - gasleft(), 16_777_216, "direct sale exceeds transaction gas cap");
        assertTrue(recipient.removalBlocked(), "seller callback moved registered Ape");
        assertTrue(recipient.paddingSent(), "seller callback did not reach padding transfer");
        assertTrue(recipient.nestedClaimBlocked(), "seller callback registered padding reentrantly");
        assertEq(bayc.ownerOf(heldId), address(sys.poolOwner), "registered Ape lost");
        assertEq(bayc.ownerOf(offeredId), address(sys.poolOwner), "one-wei Ape not delivered");
        assertEq(bayc.ownerOf(paddingId), address(sys.poolOwner), "padding Ape not delivered");
        assertEq(bayc.balanceOf(address(sys.poolOwner)), balanceBefore + 2, "real NFT count");
        assertEq(sys.poolOwner.heldCount(), heldBefore + 1, "only paid Ape registered so far");
        assertEq(sys.vault.lastPrice(), 1, "seller-named price changed in callback");
        (, uint128 purchasedCash,, uint8 purchasedSource,,) = sys.poolOwner.nfts(offeredId);
        assertEq(purchasedCash, 1, "one-wei Ape cash cost");
        assertEq(purchasedSource, 0, "direct-sale Ape source");
        sys.vault.claimStray(paddingId);
        assertEq(sys.poolOwner.heldCount(), heldBefore + 2, "padding donation can be registered later");
    }

    function test_oneWeiSaleThenSameTransactionDrawCannotTargetTheCheapApe() public {
        uint256 heldId = _activateWithHeldApe();
        uint256 offeredId = nextCheckId();
        uint256 paddingId = nextCheckId();
        InventorySwapRecipient recipient =
            new InventorySwapRecipient(cfg.collection, address(sys.poolOwner), address(sys.vault), heldId, paddingId);
        _giveToRecipient(offeredId, recipient);
        _giveToRecipient(paddingId, recipient);

        // Enter a maintenance window before the sale. Sale, listing and request all execute in this test transaction.
        window();
        uint256 gasStart = gasleft();
        recipient.sell(offeredId, 1);
        vm.prank(keeper);
        sys.game.sync();

        {
            uint256 cheapListing;
            for (uint256 i; i < sys.poolOwner.listedCount(); ++i) {
                uint256 id = sys.poolOwner.listedAt(i);
                (uint256 tokenId,,,,,) = sys.poolOwner.cListings(id);
                if (tokenId == offeredId) cheapListing = id;
                assertTrue(tokenId != paddingId, "unregistered padding was listed");
            }
            assertTrue(cheapListing != 0, "cheap Ape was not listed");
            (uint128 referenceCost, uint128 cashCost,,,,) = sys.poolOwner.nfts(offeredId);
            assertEq(referenceCost, sys.poolOwner.MIN_REF_COST(), "cheap Ape reference was not floored");
            assertEq(cashCost, 1, "cheap Ape cash cost changed");
            (,,,,, uint256 price,,) = pool.listings(cheapListing);
            assertEq(price, sys.poolOwner.scheduleOf(0), "a Check lists at its tier's schedule price, whatever it cost (D003)");
        }
        assertEq(bayc.ownerOf(heldId), address(pool), "older Ape left the protocol draw");

        uint256 requestId;
        {
            (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
            vm.deal(address(recipient), total);
            vm.prank(address(recipient));
            requestId = pool.acquire{value: total}(
                address(recipient), fee, 0, 10_000, pool.inventoryVersion(), vm.getBlockTimestamp() + 1 hours
            );
        }
        assertLt(gasStart - gasleft(), 16_777_216, "sale, listing and request exceed transaction gas cap");
        assertEq(bayc.ownerOf(offeredId), address(pool), "request immediately delivered cheap Ape");
        {
            (,,,, IFWAPool.AcquisitionStatus status) = pool.acquisitions(requestId);
            assertEq(uint8(status), uint8(IFWAPool.AcquisitionStatus.Pending), "request already settled");
        }

        // A later VRF word selecting a Shape leaves the cheap Ape in the pool; the request has no NFT-ID input.
        vm.roll(vm.getBlockNumber() + 3);
        deliverWord(requestId, wordFor(0));
        pool.processAcquisitions(10);
        assertEq(bayc.ownerOf(offeredId), address(pool), "Shape outcome delivered cheap Ape");
        assertEq(bayc.ownerOf(heldId), address(pool), "held Ape left the protocol draw after settlement");
        assertEq(bayc.balanceOf(address(recipient)), 0, "recipient acquired an Ape");
    }
}
