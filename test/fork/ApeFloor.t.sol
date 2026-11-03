// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase, IERC721Lite, IPacksView} from "./ForkBase.sol";
import {CollectionPoolOwner} from "../../src/core/CollectionPoolOwner.sol";
import {Governed} from "../../src/core/Governed.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";

interface IFloorShapes {
    function redeem(uint256 id) external;
}

interface IFloorVault {
    function sellToProtocol(uint256 id, uint256 price) external;
}

/// @dev A funded player contract: pays its own draws and receives its own prizes, so every wei of a campaign is
///      reconciled against one balance (a pranked EOA receives prizes while the test pays, a false ledger).
contract FloorPlayer {
    function sell(address collection, address vault, uint256 id, uint256 price) external {
        IERC721Lite(collection).setApprovalForAll(vault, true);
        IFloorVault(vault).sellToProtocol(id, price);
    }

    function buy(IFWAPool pool, uint256 fee, uint256 total, uint256 version, uint256 deadline)
        external
        returns (uint256)
    {
        return pool.acquire{value: total}(address(this), fee, 0, 10_000, version, deadline);
    }

    function redeemShape(address shapes, uint256 id) external {
        IFloorShapes(shapes).redeem(id);
    }

    function redeemPack(address packs, uint256 id) external {
        IPacksView(packs).redeem(id);
    }

    receive() external payable {}
}

/// @notice D82: an Ape's notional has an absolute ETH floor (`minNotionalWei`, 1 ETH at launch), whatever it cost. An
///         Ape bought below it opens at the floor with its cash cost unchanged; every Ape decays (gameplay, time) to
///         exactly the floor; a published notional never rises, including when the owner raises the floor.
contract ApeFloorForkTest is ForkBase {
    uint256 constant FLOOR = 1 ether;
    address alice = makeAddr("floor.alice");

    function setUp() public {
        deployBayc();
        launchGame(6 ether);
    }

    function _listingOf(uint256 tokenId) internal view returns (uint256 id) {
        for (uint256 i; i < sys.poolOwner.listedCount(); ++i) {
            uint256 l = sys.poolOwner.listedAt(i);
            (uint256 t,,,,) = sys.poolOwner.cListings(l);
            if (t == tokenId) return l;
        }
        revert("not listed");
    }

    function _notional(uint256 id) internal view returns (uint256 n) {
        (, uint128 x,,,) = sys.poolOwner.cListings(id);
        n = x;
    }

    function _fwaPrice(uint256 id) internal view returns (uint256 price) {
        (,,,,, price,,) = pool.listings(id);
    }

    function _fwaWeight(uint256 id) internal view returns (uint256 weight) {
        (,,,, weight,,,) = pool.listings(id);
    }

    function _processAt(uint256 turnover) internal {
        vm.prank(address(sys.game));
        sys.poolOwner.processCollection(turnover);
    }

    function _setFloor(uint256 wei_) internal {
        CollectionPoolOwner.ListingParams memory p = sys.poolOwner.listingParams();
        p.minNotionalWei = wei_;
        govern(address(sys.poolOwner), abi.encodeCall(CollectionPoolOwner.setListingParams, (p)));
    }

    /// @dev Sells Ape `id` to the vault for `price` and lists it.
    function _sellAndList(uint256 id, uint256 price) internal returns (uint256 listing) {
        accrueFees(10 ether);
        sys.vault.sweep();
        sellApeAt(id, price);
        window();
        syncAll();
        listing = _listingOf(id);
    }

    function test_launchFloorIsOneEth() public view {
        assertEq(sys.poolOwner.listingParams().minNotionalWei, FLOOR);
    }

    /// A 1-wei sale: the Ape opens at the 1 ETH floor at FWA (not at 0.01 ETH), its cash cost stays 1 wei.
    function test_oneWeiApeOpensAtTheFloor() public {
        uint256 tokenId = nextApeId();
        uint256 id = _sellAndList(tokenId, 1);
        (uint128 ref, uint128 cash,,,) = sys.poolOwner.nfts(tokenId);
        assertEq(cash, 1, "cash cost is what was paid");
        assertEq(ref, sys.poolOwner.MIN_REF_COST(), "the exposure reference keeps its dust floor");
        assertEq(_notional(id), FLOOR, "opens at the floor");
        assertEq(_fwaPrice(id), FLOOR, "FWA lists it at the floor");
        assertBooks();
    }

    /// A 0.5 ETH sale (below the floor): opens at 1 ETH; its cash cost stays 0.5 ETH.
    function test_halfEthApeOpensAtTheFloor() public {
        uint256 tokenId = nextApeId();
        uint256 id = _sellAndList(tokenId, 0.5 ether);
        (uint128 ref, uint128 cash,,,) = sys.poolOwner.nfts(tokenId);
        assertEq(cash, 0.5 ether);
        assertEq(ref, 0.5 ether);
        assertEq(_fwaPrice(id), FLOOR);
    }

    /// An ordinary Ape opens at its cost and decays with gameplay to exactly the floor, where FWA lists it.
    function test_sixEthApeDecaysToExactlyTheFloor() public {
        uint256 id = sys.poolOwner.listedAt(0);
        assertEq(_notional(id), 6 ether, "opens at its cost");
        uint256 credited = sys.poolOwner.creditedTurnover();
        _processAt(credited + 20 ether); // 0.1 ETH per ETH: 2 ETH of decay
        assertEq(_notional(id), 4 ether);
        _processAt(credited + 1_000 ether); // far past the floor
        assertEq(_notional(id), FLOOR, "stops at the floor");
        assertEq(_fwaPrice(id), FLOOR);
        assertEq(sys.poolOwner.notionalOf(id), FLOOR);
        _processAt(credited + 2_000 ether);
        assertEq(_notional(id), FLOOR, "and stays there");
    }

    /// Time decay also stops at the floor.
    function test_timeDecayStopsAtTheFloor() public {
        CollectionPoolOwner.ListingParams memory p = sys.poolOwner.listingParams();
        p.dailyDecayBps = 1_000; // 10% of cost a day: 0.6 ETH for a 6 ETH Ape
        govern(address(sys.poolOwner), abi.encodeCall(CollectionPoolOwner.setListingParams, (p)));
        uint256 id = sys.poolOwner.listedAt(0);
        uint256 credited = sys.poolOwner.creditedTurnover();
        vm.warp(block.timestamp + 5 days);
        _processAt(credited);
        assertEq(_notional(id), 3 ether, "6 - 5 x 0.6");
        vm.warp(block.timestamp + 30 days);
        _processAt(credited);
        assertEq(_notional(id), FLOOR, "stops at the floor");
        assertEq(_fwaPrice(id), FLOOR);
    }

    /// Gameplay and time decay together stop at the floor.
    function test_combinedDecayStopsAtTheFloor() public {
        CollectionPoolOwner.ListingParams memory p = sys.poolOwner.listingParams();
        p.dailyDecayBps = 500;
        govern(address(sys.poolOwner), abi.encodeCall(CollectionPoolOwner.setListingParams, (p)));
        uint256 id = sys.poolOwner.listedAt(0);
        uint256 credited = sys.poolOwner.creditedTurnover();
        vm.warp(block.timestamp + 2 days); // 0.6 ETH
        _processAt(credited + 10 ether); // 1 ETH
        assertEq(_notional(id), 4.4 ether);
        vm.warp(block.timestamp + 20 days);
        _processAt(credited + 40 ether);
        assertEq(_notional(id), FLOOR);
    }

    /// The setter takes 0.01 to 100 ETH and nothing outside.
    function test_floorBounds() public {
        CollectionPoolOwner.ListingParams memory p = sys.poolOwner.listingParams();
        vm.startPrank(owner);
        p.minNotionalWei = 0.01 ether - 1;
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.poolOwner.setListingParams(p);
        p.minNotionalWei = 100 ether + 1;
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.poolOwner.setListingParams(p);
        p.minNotionalWei = 0;
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.poolOwner.setListingParams(p);
        p.minNotionalWei = 0.01 ether;
        sys.poolOwner.setListingParams(p);
        p.minNotionalWei = 100 ether;
        sys.poolOwner.setListingParams(p);
        vm.stopPrank();
        assertEq(sys.poolOwner.listingParams().minNotionalWei, 100 ether);
    }

    /// A floor raised above a published notional leaves it where it is (never rises); a later listing opens at the
    /// new floor; a floor lowered again lets the decayed Ape fall further.
    function test_floorChangesNeverRaiseAPublishedNotional() public {
        uint256 id = sys.poolOwner.listedAt(0);
        uint256 credited = sys.poolOwner.creditedTurnover();
        _processAt(credited + 1_000 ether);
        assertEq(_notional(id), FLOOR);
        _setFloor(2 ether);
        _processAt(credited + 1_001 ether);
        assertEq(_notional(id), FLOOR, "grandfathered at its published notional");
        assertEq(sys.poolOwner.notionalOf(id), FLOOR, "never above what it published");
        assertEq(_fwaPrice(id), FLOOR);
        // a new Ape bought for 1.5 ETH opens at the raised floor
        uint256 newId = _sellAndList(nextApeId(), 1.5 ether);
        assertEq(_fwaPrice(newId), 2 ether, "opens at the new floor");
        // lowering the floor lets both fall further, as far as the exposure target allows (beyond it the reprice
        // waits for the board to grow, and `rowsShort` asks for the rows)
        _setFloor(0.5 ether);
        _processAt(credited + 3_000 ether);
        assertEq(sys.poolOwner.notionalOf(id), 0.5 ether, "free to fall to the lower floor");
        assertEq(sys.poolOwner.notionalOf(newId), 0.5 ether);
        assertLe(_notional(id), FLOOR, "never above what it published");
        assertLe(_notional(newId), 2 ether);
        if (_notional(id) > 0.5 ether || _notional(newId) > 0.5 ether) {
            assertGt(sys.poolOwner.rowsShort(), 0, "held back by the target, which asks for rows");
        }
        assertBooks();
    }

    /// FWA's weight follows the published notional only: a 1-wei Ape and a 6 ETH Ape at the same 1 ETH notional weigh
    /// the same, and a reprice happens only once the drop reaches a 5% step (or the floor).
    function test_fwaWeightAndRepriceSteps() public {
        uint256 big = sys.poolOwner.listedAt(0);
        uint256 credited = sys.poolOwner.creditedTurnover();
        _processAt(credited + 2 ether); // 0.2 ETH: 3.3% of 6 ETH, below a 5% step
        assertEq(_fwaPrice(big), 6 ether, "no reprice below a step");
        _processAt(credited + 3 ether); // 0.3 ETH: exactly 5%
        assertEq(_fwaPrice(big), 5.7 ether, "repriced at a step");
        _processAt(credited + 1_000 ether);
        uint256 cheap = _sellAndList(nextApeId(), 1);
        assertEq(_fwaPrice(big), FLOOR);
        assertEq(_fwaPrice(cheap), FLOOR);
        assertEq(_fwaWeight(cheap), _fwaWeight(big), "same notional, same weight");
    }

    /// The audit's sequence (identity-assurance): a holder sells its Ape for 1 wei and draws to win it back. The cheap
    /// Ape now lists at 1 ETH, not 0.01 ETH, so its odds are a hundredth of what they were; every wei the player
    /// spends and redeems is reconciled. A fixed, non-adaptive word sequence: not a live attacker's choice of words.
    function test_cheapSellerRepeatedDrawsAgainstTheFloor() public {
        uint256 cheapId = nextApeId();
        FloorPlayer player = new FloorPlayer();
        address holder = IERC721Lite(cfg.collection).ownerOf(cheapId);
        vm.prank(holder);
        ITransferFrom(cfg.collection).transferFrom(holder, address(player), cheapId);
        accrueFees(10 ether);
        sys.vault.sweep();
        player.sell(cfg.collection, address(sys.vault), cheapId, 1);
        window();
        syncAll();
        uint256 listing = _listingOf(cheapId);
        assertEq(_fwaPrice(listing), FLOOR, "the cheap Ape lists at the floor");
        emit log_named_uint("cheap Ape weight", _fwaWeight(listing));
        emit log_named_uint("total weight", pool.totalWeight());

        vm.deal(address(player), 10 ether);
        uint256 paid;
        uint256 redeemed;
        uint256 draws;
        bool wonBack;
        for (uint256 i; i < 60; ++i) {
            if (!canPull(address(player))) {
                window();
                syncAll();
                if (!canPull(address(player))) break;
            }
            (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
            uint256 req = player.buy(pool, fee, total, pool.inventoryVersion(), block.timestamp + 1 hours);
            paid += total;
            ++draws;
            vm.roll(block.number + 3);
            deliverWord(req, uint256(keccak256(abi.encode("fixed-seed-nonadaptive", i))));
            pool.processAcquisitions(1);
            (,,, uint256 lid,) = pool.acquisitions(req);
            (address c,,, uint256 tid,,,,) = pool.listings(lid);
            uint256 before = address(player).balance;
            if (c == cfg.shapes) player.redeemShape(cfg.shapes, tid);
            else if (c == sys.packs) player.redeemPack(sys.packs, tid);
            else if (c == cfg.collection && tid == cheapId) wonBack = true;
            redeemed += address(player).balance - before;
            sys.game.upkeep(20);
            if (wonBack) break;
        }
        assertEq(address(player).balance, 10 ether - paid + redeemed, "player ETH ledger");
        emit log_named_uint("draws", draws);
        emit log_named_uint("won back", wonBack ? 1 : 0);
        emit log_named_uint("gross paid wei", paid);
        emit log_named_uint("backing redeemed wei", redeemed);
        // the vault's funding reference is a separate, still-open rule (owner decision pending)
        assertEq(sys.vault.lastPrice(), 1, "lastPrice still follows the 1-wei sale");
        assertBooks();
    }
}

interface ITransferFrom {
    function transferFrom(address from, address to, uint256 id) external;
}
