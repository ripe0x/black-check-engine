// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase, IERC721Lite} from "./ForkBase.sol";
import {FundingVault} from "../../src/core/FundingVault.sol";
import {CollectionGame} from "../../src/game/CollectionGame.sol";
import {CollectionPoolOwner} from "../../src/core/CollectionPoolOwner.sol";
import {SeaportAdapter, SeaportTypes} from "../../src/periphery/SeaportAdapter.sol";

/// @dev Seaport's `Order`, for `validate` (the adapter itself only fills `AdvancedOrder`s).
struct SeaportOrder {
    SeaportTypes.OrderParameters parameters;
    bytes signature;
}

interface ISeaportValidate {
    function validate(SeaportOrder[] calldata orders) external returns (bool);
    function getCounter(address offerer) external view returns (uint256);
}

/// @notice Funding mode, contributions, acquisition from holders and through Seaport, and the on-chain activation check.
contract FundingForkTest is ForkBase {
    IERC721Lite bayc;

    function setUp() public {
        deployChecksAt(6 ether);
        bayc = IERC721Lite(cfg.collection);
        createPool();
        openMarket();
    }

    function test_prolongedFundingModeLosesNothing() public {
        accrueFees(2 ether);
        // a year passes with nobody acting: nothing expires, nothing is spent
        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 2_600_000);
        assertEq(address(sys.vault).balance, 2 ether);
        assertEq(sys.vault.generalBalance(), 2 ether);
        assertFalse(sys.game.activated());
        // keepers cannot drain anything: fundGame is refused without an NFT, sync has nothing to do
        vm.expectRevert(FundingVault.NotAllowed.selector);
        sys.vault.fundGame();
        vm.prank(keeper);
        vm.expectRevert(CollectionGame.NoWork.selector);
        sys.game.sync();
        assertEq(address(sys.vault).balance, 2 ether);
        assertEq(sys.game.keeperPaid(), 0, "no keeper paid");
        vm.expectRevert(CollectionGame.NotReady.selector);
        sys.game.activate();
        // nothing entered the bid on its own; a sweep fills it with what is there (below the threshold, at once)
        assertEq(sys.vault.liveBid(), 0);
        sys.vault.sweep();
        assertEq(sys.vault.liveBid(), 2 ether - sys.game.keeperParams().flatFee, "all of it, less the sweep reward");
        assertEq(sys.game.liveCount(), 0, "no Shapes bought during funding");
    }

    function test_ethContributionsCountSeparately() public {
        accrueFees(1 ether);
        address donor = makeAddr("donor");
        vm.deal(donor, 3 ether);
        vm.prank(donor);
        sys.vault.contribute{value: 2 ether}();
        vm.prank(donor);
        (bool ok,) = address(sys.vault).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(sys.vault.tradingFees(), 1 ether);
        assertEq(sys.vault.contributions(), 3 ether);
        assertEq(sys.vault.generalBalance(), 4 ether);
        assertEq(sys.token.balanceOf(donor), 0, "nothing in return");
    }

    function test_nftContributionUsesConservativeReference() public {
        uint256 id = nextCheckId();
        address holder = bayc.ownerOf(id);
        vm.startPrank(holder);
        bayc.setApprovalForAll(address(sys.vault), true);
        sys.vault.contributeNFT(id);
        vm.stopPrank();
        assertEq(bayc.ownerOf(id), address(sys.poolOwner));
        (uint128 ref, uint128 cash,, uint8 source,) = sys.poolOwner.nfts(id);
        assertEq(ref, cfg.refPrice, "reference = the latest clearing price, never donor-chosen");
        assertEq(cash, 0);
        assertEq(source, 1, "donated");
        assertEq(sys.vault.nftContributions(), 1);
        // the donated NFT satisfies the collection requirement: the vault now funds the board
        accrueFees(sys.game.capitalNeed() + listingPayRoom());
        syncAll();
        assertTrue(sys.game.ready());
        sys.game.activate();
        (, uint128 notional,,,,) = sys.poolOwner.cListings(sys.poolOwner.listedAt(0));
        assertEq(notional, cfg.refPrice, "opens at its reference value");
        assertLe(sys.poolOwner.exposureBps(), 1_500);
        // no withdrawal path for the donor or anyone
        vm.prank(holder);
        vm.expectRevert();
        sys.vault.sellToProtocol(id, 1);
    }

    function test_strayNftRegisteredAsDonation() public {
        uint256 id = nextCheckId();
        address holder = bayc.ownerOf(id);
        vm.prank(holder);
        (bool ok,) = cfg.collection.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", holder, address(sys.poolOwner), id)
        );
        assertTrue(ok);
        sys.vault.claimStray(id);
        (uint128 ref,,,,) = sys.poolOwner.nfts(id);
        assertEq(ref, cfg.refPrice);
        vm.expectRevert(CollectionPoolOwner.NotCustody.selector);
        sys.vault.claimStray(id);
    }

    function test_safeTransferOfCollectionNftIsRefused() public {
        uint256 id = nextCheckId();
        address holder = bayc.ownerOf(id);
        vm.prank(holder);
        (bool ok,) = cfg.collection.call(
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", holder, address(sys.poolOwner), id)
        );
        assertFalse(ok, "unsolicited safe transfer refused");
    }

    function test_liveBidAndHolderSale() public {
        accrueFees(20 ether);
        // the first sweep fills the bid to its first threshold: 100% of the reference price (the live floor at deploy,
        // 6 ETH; D64), so the opening fees can buy the first Ape at once
        assertEq(sys.vault.activationThreshold(), 6 ether);
        sys.vault.sweep();
        assertEq(sys.vault.liveBid(), 6 ether);
        // a week with nobody sweeping: it stays where it is
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 50_400);
        assertEq(sys.vault.liveBid(), 6 ether, "no time-based rise");
        // above the threshold, sweeps meter ETH in (keepers, waiting sellers, players' draws)
        sys.vault.sweep();
        uint256 bid = sys.vault.liveBid();
        assertGt(bid, 6 ether, "metered above the threshold");
        assertLe(bid, 6 ether + cfg.bid.maxSweepWei, "one step");
        uint256 id = nextCheckId();
        address holder = bayc.ownerOf(id);
        uint256 before = holder.balance;
        vm.startPrank(holder);
        bayc.setApprovalForAll(address(sys.vault), true);
        vm.expectRevert(abi.encodeWithSelector(FundingVault.AboveBid.selector, bid));
        sys.vault.sellToProtocol(id, bid + 1);
        sys.vault.sellToProtocol(id, bid);
        vm.stopPrank();
        assertEq(holder.balance - before, bid);
        assertEq(bayc.ownerOf(id), address(sys.poolOwner));
        (uint128 ref, uint128 cash,, uint8 source,) = sys.poolOwner.nfts(id);
        assertEq(ref, bid);
        assertEq(cash, bid);
        assertEq(source, 0);
        assertEq(sys.vault.acquisitionSpend(), bid);
        assertEq(sys.vault.lastPrice(), bid, "the price paid is the new reference");
        assertEq(sys.vault.activationThreshold(), bid * 7_500 / 10_000);
        // before activation one NFT is enough: the budget is now zero
        assertEq(sys.vault.acquisitionBudget(), 0);
        assertEq(sys.vault.liveBid(), 0);
        // only the NFT's owner can sell it
        uint256 other = nextCheckId();
        vm.prank(holder);
        vm.expectRevert();
        sys.vault.sellToProtocol(other, 1);
    }

    function test_cannotActivateIncomplete() public {
        // no NFT: the vault will not capitalise the game; activation is refused
        accrueFees(30 ether);
        vm.expectRevert(CollectionGame.NotReady.selector);
        sys.game.activate();
        riseBidTo(6 ether);
        sellCheck(nextCheckId());
        // the vault now funds the whole requirement at once; one sync lists a batch (`maxPerCall`, 8) of the rows
        vm.prank(keeper);
        sys.game.sync();
        assertEq(sys.game.liveCount(), 8);
        assertFalse(sys.game.ready());
        vm.expectRevert(CollectionGame.NotReady.selector);
        sys.game.activate();
        syncAll();
        assertTrue(sys.game.ready());
        sys.game.activate();
        vm.expectRevert(CollectionGame.NotReady.selector);
        sys.game.activate();
    }

    function test_boardNotFundedPiecemeal() public {
        accrueFees(8 ether);
        riseBidTo(6 ether);
        sellCheckAt(nextCheckId(), 6 ether);
        // less than the full requirement remains: the vault sends nothing and no Shape is minted
        uint256 need = sys.game.capitalNeed();
        assertGt(need, sys.vault.generalBalance());
        vm.expectRevert(FundingVault.NotAllowed.selector);
        sys.vault.fundGame();
        assertEq(sys.game.liveCount(), 0);
    }

    /// @dev Lists Ape `id` on Seaport for 4 ETH (3.9 to the seller, 0.1 to `market`), validated on chain.
    function _seaportListing(uint256 id, address market) internal returns (SeaportTypes.AdvancedOrder memory ao) {
        address seller = bayc.ownerOf(id);
        SeaportTypes.OrderParameters memory p;
        p.offerer = seller;
        p.offer = new SeaportTypes.OfferItem[](1);
        p.offer[0] = SeaportTypes.OfferItem(SeaportTypes.ItemType.ERC721, cfg.collection, id, 1, 1);
        p.consideration = new SeaportTypes.ConsiderationItem[](2);
        p.consideration[0] = SeaportTypes.ConsiderationItem(SeaportTypes.ItemType.NATIVE, address(0), 0, 3.9 ether, 3.9 ether, payable(seller));
        p.consideration[1] = SeaportTypes.ConsiderationItem(SeaportTypes.ItemType.NATIVE, address(0), 0, 0.1 ether, 0.1 ether, payable(market));
        p.orderType = SeaportTypes.OrderType.FULL_OPEN;
        p.startTime = block.timestamp - 1;
        p.endTime = block.timestamp + 1 days;
        p.salt = 42;
        p.totalOriginalConsiderationItems = 2;
        SeaportOrder[] memory orders = new SeaportOrder[](1);
        orders[0] = SeaportOrder(p, "");
        vm.startPrank(seller);
        bayc.setApprovalForAll(MAINNET_SEAPORT, true);
        ISeaportValidate(MAINNET_SEAPORT).validate(orders);
        vm.stopPrank();
        ao = SeaportTypes.AdvancedOrder(p, 1, 1, "", "");
    }

    function test_seaportOrderFilledThroughAdapter() public {
        SeaportAdapter adapter = sys.adapter; // the vault's one adapter, fixed at deployment
        assertEq(sys.vault.adapter(), address(adapter));
        accrueFees(20 ether);
        uint256 id = nextCheckId();
        address seller = bayc.ownerOf(id);
        address market = makeAddr("marketplaceFee");
        // the seller lists on Seaport for 4 ETH (3.9 to the seller, 0.1 marketplace fee), validated on chain
        SeaportTypes.AdvancedOrder memory ao = _seaportListing(id, market);
        sys.vault.sweep(); // the live bid fills to its 4.5 ETH threshold
        uint256 sellerBefore = seller.balance;
        uint256 keeperBefore = keeper.balance;
        uint256 vaultBefore = address(sys.vault).balance;
        uint256 bidBefore = sys.vault.bidBalance();
        // the bid covers the 4 ETH order and the finder fee; a keeper fills it and is paid the fee
        vm.prank(keeper);
        uint256 spent = sys.vault.fillOrder(id, 10 ether, abi.encode(ao));
        assertEq(spent, 4 ether, "the listing's price, not the bid");
        assertEq(seller.balance - sellerBefore, 3.9 ether);
        assertEq(market.balance, 0.1 ether);
        assertEq(keeper.balance - keeperBefore, 0.01 ether, "finder fee: 0.5% of the bid, at most 0.01 ETH");
        assertEq(vaultBefore - address(sys.vault).balance, 4.01 ether, "the order price and the fee left the vault");
        assertEq(sys.vault.bidBalance(), bidBefore - 4.01 ether, "taken out of the bid; the rest stays");
        assertEq(sys.vault.lastPrice(), 4 ether, "the price paid, exactly");
        // D83: one purchase lowers the funding reference by at most 25% (6 to 4.5 ETH), the threshold is 75% of it
        assertEq(sys.vault.referencePrice(), 4.5 ether);
        assertEq(sys.vault.activationThreshold(), 3.375 ether, "75% of the funding reference");
        assertEq(sys.vault.contributions(), 0, "returned change is not a contribution");
        assertEq(bayc.ownerOf(id), address(sys.poolOwner));
        assertEq(address(adapter).balance, 0);
        (uint128 ref,,,,) = sys.poolOwner.nfts(id);
        assertEq(ref, 4 ether);
    }

    /// Audit round 3 (D68): ETH the vault receives during a fill that does not come back from the adapter (here a
    /// consideration recipient that pays the vault from inside Seaport; the audit's case was a game payout triggered
    /// there) is booked as what it is, and the NFT is booked at the order's full price.
    function test_otherInflowDuringAFillDoesNotLowerThePrice() public {
        accrueFees(20 ether);
        uint256 id = nextCheckId();
        PaysVaultOnReceive market = new PaysVaultOnReceive(sys.vault);
        vm.deal(address(market), 0.05 ether);
        SeaportTypes.AdvancedOrder memory ao = _seaportListing(id, address(market));
        sys.vault.sweep();
        uint256 c0 = sys.vault.contributions();
        vm.prank(keeper);
        uint256 spent = sys.vault.fillOrder(id, 10 ether, abi.encode(ao));
        assertEq(spent, 4 ether, "the order's price");
        assertEq(sys.vault.lastPrice(), 4 ether);
        (uint128 ref, uint128 cash,,,) = sys.poolOwner.nfts(id);
        assertEq(ref, 4 ether);
        assertEq(cash, 4 ether);
        assertEq(sys.vault.contributions() - c0, 0.05 ether, "the inflow is booked as a contribution");
    }

    /// Audit final (F1, F2, B-F1): the adapter fills only a signed order's own consideration, and none of it may pay
    /// the vault or custody. A fulfiller tip to the caller would take vault ETH beyond the listing's price; ETH paid
    /// back to the vault, directly or through the pool owner's flush, would be booked as NFT cost.
    function test_adapterRejectsTipsAndProtocolRecipients() public {
        accrueFees(20 ether);
        uint256 id = nextCheckId();
        sys.vault.sweep();
        // a tip the caller appends to the validated order, paid to itself
        SeaportTypes.AdvancedOrder memory ao = _seaportListing(id, makeAddr("marketplaceFee"));
        SeaportTypes.ConsiderationItem[] memory c = new SeaportTypes.ConsiderationItem[](3);
        (c[0], c[1]) = (ao.parameters.consideration[0], ao.parameters.consideration[1]);
        c[2] = SeaportTypes.ConsiderationItem(SeaportTypes.ItemType.NATIVE, address(0), 0, 0.4 ether, 0.4 ether, payable(keeper));
        ao.parameters.consideration = c;
        vm.prank(keeper);
        vm.expectRevert(SeaportAdapter.BadOrder.selector);
        sys.vault.fillOrder(id, 10 ether, abi.encode(ao));
        // seller-signed items paying the vault, or custody (whose ETH anyone flushes to the vault)
        address[2] memory protocol = [address(sys.vault), address(sys.poolOwner)];
        for (uint256 i; i < 2; ++i) {
            ao = _seaportListing(id, protocol[i]);
            vm.prank(keeper);
            vm.expectRevert(SeaportAdapter.BadOrder.selector);
            sys.vault.fillOrder(id, 10 ether, abi.encode(ao));
        }
        // a CONTRACT order: its offerer's `generateOrder`, not a signature, decides what Seaport pays
        ao = _seaportListing(id, makeAddr("marketplaceFee"));
        ao.parameters.orderType = SeaportTypes.OrderType.CONTRACT;
        vm.prank(keeper);
        vm.expectRevert(SeaportAdapter.BadOrder.selector);
        sys.vault.fillOrder(id, 10 ether, abi.encode(ao));
        // the plain listing still fills at its price
        ao = _seaportListing(id, makeAddr("marketplaceFee"));
        vm.prank(keeper);
        assertEq(sys.vault.fillOrder(id, 10 ether, abi.encode(ao)), 4 ether);
    }

    /// Audit round 3 (D68): ETH left in the pool owner (here a marketplace order's consideration) is not stranded:
    /// anyone sends it to the vault, where it is a contribution.
    function test_strayEthInThePoolOwnerGoesToTheVault() public {
        vm.deal(address(this), 0.4 ether);
        (bool ok,) = address(sys.poolOwner).call{value: 0.4 ether}("");
        require(ok);
        uint256 c0 = sys.vault.contributions();
        vm.prank(makeAddr("anyone"));
        assertEq(sys.poolOwner.flushStray(), 0.4 ether);
        assertEq(address(sys.poolOwner).balance, 0);
        assertEq(sys.vault.contributions() - c0, 0.4 ether);
    }

    /// Audit (D66): ETH sent to the adapter by anyone else neither blocks a fill priced at or below it nor changes the
    /// price the vault books; it stays in the adapter (the sender's loss), and the vault's books stay exact.
    function test_adapterPrefundCannotBlockOrRepriceAFill() public {
        accrueFees(20 ether);
        uint256 id = nextCheckId();
        address seller = bayc.ownerOf(id);
        SeaportTypes.AdvancedOrder memory ao = _seaportListing(id, makeAddr("marketplaceFee"));
        address griefer = makeAddr("griefer");
        vm.deal(griefer, 5 ether);
        vm.prank(griefer);
        (bool ok,) = address(sys.adapter).call{value: 5 ether}(""); // more than the 4 ETH order
        require(ok);
        sys.vault.sweep();
        uint256 sellerBefore = seller.balance;
        uint256 vaultBefore = address(sys.vault).balance;
        vm.prank(keeper);
        uint256 spent = sys.vault.fillOrder(id, 10 ether, abi.encode(ao));
        assertEq(spent, 4 ether, "the order's price, not less");
        assertEq(seller.balance - sellerBefore, 3.9 ether);
        assertEq(vaultBefore - address(sys.vault).balance, 4.01 ether, "the order price and the finder fee, nothing else");
        assertEq(sys.vault.lastPrice(), 4 ether);
        (uint128 ref, uint128 cash,,,) = sys.poolOwner.nfts(id);
        assertEq(ref, 4 ether);
        assertEq(cash, 4 ether);
        assertEq(address(sys.adapter).balance, 5 ether, "the prefund stays in the adapter");
        assertEq(sys.vault.contributions(), 0);
        assertEq(bayc.ownerOf(id), address(sys.poolOwner));
    }

    /// The adapter must deliver: one that takes the ETH and delivers nothing makes the whole call revert, and no ETH
    /// leaves (the deployed Seaport adapter's code replaced by a liar's, for the test).
    function test_adapterMustDeliver() public {
        accrueFees(20 ether);
        vm.etch(address(sys.adapter), address(new LyingAdapter()).code);
        sys.vault.sweep();
        uint256 bal = address(sys.vault).balance;
        uint256 id = nextCheckId();
        vm.expectRevert(FundingVault.NotDelivered.selector);
        sys.vault.fillOrder(id, 5 ether, "");
        assertEq(address(sys.vault).balance, bal);
    }

    /// Keepers listing the opening board are paid from the game's opening allowance (D63: no KeeperFund, no top-ups from
    /// fees): their gas plus the margin, never more than the allowance; the game's capital need covers it.
    function test_keepersPaidForTheOpeningBoardFromTheAllowance() public {
        uint256 keeperBefore = keeper.balance;
        accrueFees(6 ether);
        riseBidTo(6 ether);
        sellCheck(nextCheckId());
        accrueFees(sys.game.capitalNeed() + listingPayRoom());
        vm.txGasPrice(1 gwei);
        syncAll();
        vm.txGasPrice(0);
        assertGt(keeper.balance, keeperBefore, "keepers paid for listing the opening board");
        assertEq(sys.game.keeperPaid(), keeper.balance - keeperBefore);
        assertLe(sys.game.keeperPaid(), cfg.openingAllowance, "within the opening allowance");
        assertTrue(sys.game.ready(), "ready: the vault covers what the payments took from the reserve");
        sys.game.activate(); // draws it back
        assertEq(sys.game.capitalNeed(), 0);
        assertTrue(sys.game.activated());
        assertBooks();
    }
}

/// @dev Pretends to buy: takes the ETH, delivers nothing, returns the ETH.
/// @dev A consideration recipient that, when paid inside a Seaport fill, sends the vault 0.05 ETH.
contract PaysVaultOnReceive {
    FundingVault immutable vault;

    constructor(FundingVault v) {
        vault = v;
    }

    receive() external payable {
        if (msg.sender != address(vault) && address(this).balance >= msg.value + 0.05 ether) {
            (bool ok,) = address(vault).call{value: 0.05 ether}("");
            require(ok);
        }
    }
}

contract LyingAdapter {
    function execute(address, uint256, address, bytes calldata) external payable returns (uint256) {
        (bool ok,) = msg.sender.call{value: msg.value}("");
        require(ok);
        return 0;
    }

    receive() external payable {}
}
