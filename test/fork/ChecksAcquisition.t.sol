// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase, IERC721Lite} from "./ForkBase.sol";
import {IChecksOriginals, IChecksEdition} from "../../src/interfaces/IChecks.sol";
import {FundingVault} from "../../src/core/FundingVault.sol";
import {CollectionPoolOwner} from "../../src/core/CollectionPoolOwner.sol";

/// @notice Acquisition of Checks through the vault's live bid (collection-games' mechanism, D015/D016): only
///         80-Check Originals are bought, an Edition sold to the vault arrives as an 80-Check Original (rc2
///         `sellEdition`), no purchase is ever booked above 120% of the council's 80-Check price (D012), and a donated
///         higher tier is recorded at its own schedule price.
contract ChecksAcquisitionForkTest is ForkBase {
    IChecksOriginals checks;
    IChecksEdition editions;

    function setUp() public {
        deployChecks();
        checks = IChecksOriginals(cfg.collection);
        editions = IChecksEdition(cfg.editions);
        launchGame(cfg.refPrice);
        accrueFees(5 ether);
    }

    function _firstOfTier(uint8 tier) internal view returns (uint256) {
        for (uint256 id = 1; id < 16_100; ++id) {
            try checks.ownerOf(id) returns (address o) {
                if (o.code.length == 0 && o != address(0) && checks.getCheck(id).stored.divisorIndex == tier) return id;
            } catch {}
        }
        revert("none");
    }

    /// @dev A live Edition held by an ordinary account (Originals keep their Edition's id once migrated).
    function _liveEdition() internal view returns (uint256) {
        for (uint256 id = 1; id < 16_100; ++id) {
            try editions.ownerOf(id) returns (address o) {
                if (o.code.length == 0 && o != address(0)) return id;
            } catch {}
        }
        revert("no live Edition");
    }

    function test_editionSoldMigratesIntoAnOriginalInCustody() public {
        uint256 id = _liveEdition();
        address holder = editions.ownerOf(id);
        uint256 bid = riseBidTo(cfg.refPrice);
        uint256 balance = holder.balance;
        vm.startPrank(holder);
        IERC721Lite(cfg.editions).setApprovalForAll(address(sys.vault), true);
        sys.vault.sellEdition(id, bid);
        vm.stopPrank();
        assertEq(holder.balance - balance, bid, "paid the bid");
        assertEq(checks.ownerOf(id), address(sys.poolOwner), "an Original with the Edition's id, in custody");
        (uint128 ref, uint128 cash, uint8 tier,, CollectionPoolOwner.NftState st,) = sys.poolOwner.nfts(id);
        assertEq(tier, 0, "an 80-Check");
        assertEq(cash, bid);
        assertEq(ref, bid);
        assertEq(uint8(st), uint8(CollectionPoolOwner.NftState.Custody));
        vm.expectRevert();
        editions.ownerOf(id); // Checks burned the Edition
        window();
        syncAll();
        assertEq(sys.poolOwner.custodyCount(), 0, "listed like any 80");
    }

    function test_onlyEightyChecksAreBought() public {
        uint256 forty = _firstOfTier(1);
        address holder = checks.ownerOf(forty);
        uint256 bid = riseBidTo(cfg.refPrice);
        vm.startPrank(holder);
        IERC721Lite(cfg.collection).setApprovalForAll(address(sys.vault), true);
        vm.expectRevert(FundingVault.NotFloorTier.selector);
        sys.vault.sellToProtocol(forty, bid);
        vm.stopPrank();
        assertEq(checks.ownerOf(forty), holder);
    }

    /// D012: whatever the owner sets the bid to, nothing is booked above 120% of the council's 80-Check price.
    function test_noPurchaseAboveTheScheduleCap() public {
        FundingVault.BidParams memory p = sys.vault.bidParams();
        p.ceilingBps = 0; // the owner removes the bid's own ceiling
        p.maxSweepWei = 100 ether;
        govern(address(sys.vault), abi.encodeCall(FundingVault.setBidParams, (p)));
        govern(address(sys.vault), abi.encodeCall(FundingVault.setActivationThreshold, (2 ether)));
        uint256 cap = cfg.schedule[0] * 12_000 / 10_000;
        riseBidTo(1 ether);
        assertGt(sys.vault.bidBalance(), cap, "the ETH in the bid exceeds the cap");
        assertEq(sys.vault.liveBid(), cap, "the bid shown stops at the cap, so taking it is never refused");
        uint256 id = nextCheckId();
        vm.expectRevert(abi.encodeWithSelector(FundingVault.AboveBid.selector, cap));
        this.sellAt(id, cap + 1);
        sellCheckAt(id, cap); // at the cap: fine
        assertEq(checks.ownerOf(id), address(sys.poolOwner));
    }

    function sellAt(uint256 id, uint256 price) external {
        sellCheckAt(id, price);
    }

    /// A donated 40 is recorded at the 40 tier's price, not the 80-Check reference.
    function test_donatedHigherTierRecordedAtItsSchedule() public {
        uint256 forty = _firstOfTier(1);
        address holder = checks.ownerOf(forty);
        vm.startPrank(holder);
        IERC721Lite(cfg.collection).setApprovalForAll(address(sys.vault), true);
        sys.vault.contributeNFT(forty);
        vm.stopPrank();
        (uint128 ref, uint128 cash, uint8 tier,,,) = sys.poolOwner.nfts(forty);
        assertEq(tier, 1);
        assertEq(ref, cfg.schedule[1]);
        assertEq(cash, 0);
        window();
        syncAll();
        assertEq(sys.poolOwner.custodyCount(), 0, "listed at the 40 tier's price");
    }
}
