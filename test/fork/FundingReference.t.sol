// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase, IERC721Lite} from "./ForkBase.sol";
import {FundingVault} from "../../src/core/FundingVault.sol";
import {Governed} from "../../src/core/Governed.sol";

/// @notice D83: the vault's funding reference (`referencePrice`: the next Ape's assumed cost, which sets the bid's
///         threshold and ceiling, the vault's shortfall and a donation's reference) follows each purchase price, but
///         one purchase cannot move it below the Ape floor (1 ETH) or more than `maxDropBps` (25%) below the previous
///         reference. `lastPrice` stays the exact price paid.
contract FundingReferenceForkTest is ForkBase {
    function setUp() public {
        deployBayc();
        launchGame(6 ether);
        accrueFees(200 ether);
        sys.vault.sweep(); // a live bid, so a holder can sell at any price up to it
    }

    /// @dev The vault buys the next Ape at `price` (the bid raised to it first).
    function _buyAt(uint256 price) internal {
        riseBidTo(price);
        sellApeAt(nextApeId(), price);
    }

    function _setMaxDrop(uint256 bps) internal {
        FundingVault.BidParams memory p = sys.vault.bidParams();
        p.maxDropBps = bps;
        govern(address(sys.vault), abi.encodeCall(FundingVault.setBidParams, (p)));
    }

    function test_launchValues() public view {
        assertEq(sys.vault.bidParams().maxDropBps, 2_500);
        assertEq(sys.vault.referencePrice(), 6 ether);
        assertEq(sys.vault.lastPrice(), 6 ether);
    }

    /// A consenting 1-wei sale after a 6 ETH Ape: the price paid is recorded exactly, the reference falls only 25%.
    function test_oneWeiSaleMovesTheReferenceOnlyOneStep() public {
        sellApeAt(nextApeId(), 1);
        assertEq(sys.vault.lastPrice(), 1, "the price paid, exactly");
        assertEq(sys.vault.referencePrice(), 4.5 ether, "6 less 25%");
        assertEq(sys.vault.activationThreshold(), 3.375 ether, "75% of the reference");
        assertEq(sys.vault.bidCeiling(), 5.4 ether, "120% of the reference");
        // the bid can still reach a 6 ETH Ape: to the ceiling at the normal meter, then 0.01 ETH per 300 blocks
        uint256 start = block.number;
        assertGe(riseBidTo(6 ether), 6 ether);
        uint256 hoursTaken = (block.number - start) * 12 / 1 hours;
        emit log_named_uint("hours for the bid to reach 6 ETH again", hoursTaken);
        assertLt(hoursTaken, 72, "within three days");
    }

    /// Repeated cheap sales walk the reference down 25% at a time, never below the Ape floor.
    function test_repeatedCheapSalesStopAtTheFloor() public {
        uint256[7] memory want = [uint256(4.5 ether), 3.375 ether, 2.53125 ether, 1.8984375 ether, 1.423828125 ether,
            1.06787109375 ether, 1 ether];
        for (uint256 i; i < want.length; ++i) {
            sellApeAt(nextApeId(), 1);
            assertEq(sys.vault.referencePrice(), want[i]);
        }
        sellApeAt(nextApeId(), 1);
        assertEq(sys.vault.referencePrice(), 1 ether, "held at the floor");
        assertEq(sys.vault.shortfall() <= 1 ether, true);
    }

    /// A genuine falling market, one Ape at each price, is followed exactly (each step is within 25%).
    function test_fallingMarketIsFollowed() public {
        uint256[3] memory prices = [uint256(5 ether), 4 ether, 3 ether];
        for (uint256 i; i < prices.length; ++i) {
            _buyAt(prices[i]);
            assertEq(sys.vault.lastPrice(), prices[i]);
            assertEq(sys.vault.referencePrice(), prices[i], "followed exactly");
        }
    }

    /// A sudden crash (6 to 3 ETH in one purchase) is followed over the next purchases.
    function test_crashIsFollowedOverPurchases() public {
        _buyAt(3 ether);
        assertEq(sys.vault.referencePrice(), 4.5 ether, "one step down");
        _buyAt(3 ether);
        assertEq(sys.vault.referencePrice(), 3.375 ether);
        _buyAt(3 ether);
        assertEq(sys.vault.referencePrice(), 3 ether, "caught up");
    }

    /// A rising market is followed at once.
    function test_risingMarketIsFollowed() public {
        _buyAt(7.2 ether);
        assertEq(sys.vault.referencePrice(), 7.2 ether);
        assertEq(sys.vault.bidCeiling(), 8.64 ether);
    }

    /// The owner may change the step: 100% gives the floor-only rule, 1% a slow follow; nothing outside 1-100%.
    function test_maxDropIsTheOwnersWithinBounds() public {
        FundingVault.BidParams memory p = sys.vault.bidParams();
        vm.startPrank(owner);
        p.maxDropBps = 99;
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.vault.setBidParams(p);
        p.maxDropBps = 10_001;
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.vault.setBidParams(p);
        vm.stopPrank();
        _setMaxDrop(10_000);
        sellApeAt(nextApeId(), 1);
        assertEq(sys.vault.referencePrice(), 1 ether, "100%: straight to the floor");
        _setMaxDrop(100);
        sellApeAt(nextApeId(), 1);
        assertEq(sys.vault.referencePrice(), 1 ether, "the floor still holds");
    }

    /// The floor is the pool owner's Ape floor: raising it raises the lowest reference too.
    function test_floorFollowsTheApeFloor() public {
        _setMaxDrop(10_000);
        sellApeAt(nextApeId(), 1);
        assertEq(sys.vault.referencePrice(), 1 ether);
        bytes memory call = abi.encodeWithSignature("listingParams()");
        (bool ok, bytes memory ret) = address(sys.poolOwner).staticcall(call);
        assertTrue(ok);
        (uint256 a, , uint256 c, uint256 d, uint256 e, uint256 f) =
            abi.decode(ret, (uint256, uint256, uint256, uint256, uint256, uint256));
        govern(
            address(sys.poolOwner),
            abi.encodeWithSignature("setListingParams((uint256,uint256,uint256,uint256,uint256,uint256))", a, 2 ether, c, d, e, f)
        );
        sellApeAt(nextApeId(), 1);
        assertEq(sys.vault.referencePrice(), 2 ether);
    }

    /// A donated Ape is registered at the funding reference, not at a cheap sale's price.
    function test_donationUsesTheReference() public {
        sellApeAt(nextApeId(), 1);
        uint256 id = nextApeId();
        address holder = IERC721Lite(cfg.collection).ownerOf(id);
        vm.startPrank(holder);
        IERC721Lite(cfg.collection).setApprovalForAll(address(sys.vault), true);
        sys.vault.contributeNFT(id);
        vm.stopPrank();
        (uint128 ref, uint128 cash,,,) = sys.poolOwner.nfts(id);
        assertEq(ref, 4.5 ether);
        assertEq(cash, 0);
        assertBooks();
    }
}
