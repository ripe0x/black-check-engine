// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "../fork/ForkBase.sol";
import {Handler} from "./Handler.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {FundingVault} from "../../src/core/FundingVault.sol";
import {CollectionBurner} from "../../src/treasury/CollectionBurner.sol";

interface IERC721O {
    function ownerOf(uint256) external view returns (address);
}

/// @notice Protocol invariants under random sequences on the pinned fork (docs/SECURITY.md "Invariants").
contract InvariantsForkTest is ForkBase {
    Handler handler;
    uint256 supply0;
    uint256 safe0;

    function setUp() public {
        deployBayc();
        launchGame(6 ether);
        pastOpeningCurve();
        handler = new Handler(sys, pool, swapper, cfg.collection, cfg.poolManager);
        supply0 = sys.token.totalSupply();
        safe0 = owner.balance;
        targetContract(address(handler));
    }

    /// 1. Supply never increases.
    function invariant_supplyNeverIncreases() public view {
        assertLe(sys.token.totalSupply(), supply0);
    }

    /// 3, 4, 5. Every ETH movement of the game reconciles; distributions never exceed realised profit.
    function invariant_booksAndDistributions() public view {
        assertBooks();
        assertLe(sys.game.distributed(), handler.maxProfitSeen() + 1, "distributed above realised profit");
        assertEq(sys.game.toVault() + sys.game.toBurner(), sys.game.distributed());
        assertLe(sys.game.keeperPaid(), sys.game.keeperAllowance(), "keeper pay within the allowance");
    }

    /// 7. Every distribution reached the vault (its share) or the burner: nothing else receives surplus.
    function invariant_surplusOnlyToVaultAndBurner() public view {
        assertEq(sys.vault.surplusIn(), sys.game.toVault());
        assertEq(sys.burner.reserveIn() + _burnerFromGame(), sys.game.toBurner());
    }

    /// The burner's ongoing inflow from the game: its ongoing bucket counts the game's share, the vault's fee overflow
    /// (D64) and any donation; the handler donates nothing.
    function _burnerFromGame() internal view returns (uint256) {
        return sys.burner.ongoingIn() - sys.vault.overflowOut();
    }

    /// 8, 9. Milestone releases only for verified collection wins, at most once each.
    function invariant_milestoneOnlyOnWins() public view {
        assertLe(sys.burner.exitReleases(), sys.game.collectionWins());
        assertLe(sys.burner.exitReleases(), sys.poolOwner.wonCount());
        assertLe(sys.burner.releases() - sys.burner.exitReleases(), sys.game.pullsFulfilled(), "big prizes are won draws");
        assertEq(sys.burner.milestoneIn(), sys.burner.reserveIn() - sys.burner.reserve(), "released = reserved - held");
    }

    /// 10. Every registered NFT is in exactly one place: custody, the FWA pool, a winner, or a buyer.
    function invariant_nftCustody() public view {
        uint256 held = sys.poolOwner.custodyCount() + sys.poolOwner.listedCount();
        assertEq(held + sys.poolOwner.wonCount(), sys.poolOwner.registeredCount());
        for (uint256 i; i < sys.poolOwner.custodyCount(); ++i) {
            assertEq(IERC721O(cfg.collection).ownerOf(sys.poolOwner.custodyAt(i)), address(sys.poolOwner));
        }
        for (uint256 i; i < sys.poolOwner.listedCount(); ++i) {
            uint256 id = sys.poolOwner.listedAt(i);
            (uint256 tokenId,,,,) = sys.poolOwner.cListings(id);
            address owner_ = IERC721O(cfg.collection).ownerOf(tokenId);
            if (owner_ == address(pool)) continue;
            // won and delivered by FWA, not yet recorded by a sync: it must be with that listing's purchaser
            (,, address purchaser,,,,, IFWAPool.ListingStatus st) = pool.listings(id);
            assertEq(uint8(st), uint8(IFWAPool.ListingStatus.Settled), "a listed NFT left the pool only by winning");
            assertEq(owner_, purchaser, "delivered to the winner");
        }
    }

    /// 11. Collection exposure against the full board never exceeds the target (listing and decay keep it there).
    function invariant_exposureTarget() public view {
        uint256 n = sys.game.boardSize() + sys.poolOwner.listedCount();
        uint256 active = pool.activeListingCount();
        // exposureBps is measured against the active count; scale it to the full board
        assertLe(sys.poolOwner.exposureBps() * active, sys.poolOwner.listingParams().targetBps * n + n);
    }

    /// 19. The purchase gate's promise, from live FWA state: even after every unsettled request has settled (each
    ///     removing one listing), collection exposure is within its 50% ceiling. Holds with no keeper, batches
    ///     included.
    function invariant_liveExposureAfterInFlightSettle() public view {
        uint256 n = pool.activeListingCount();
        uint256 u = pool.unsettledAcquisitionCount();
        if (sys.poolOwner.openCollection() == 0 || n <= u) return;
        assertLe(sys.poolOwner.exposureSum() * 10_000, sys.poolOwner.MAX_EXPOSURE_BPS() * (n - u) * 1e18);
        assertLe(u, sys.poolOwner.gateHeadroom(), "in flight within maxInFlight - 1 + one batch");
    }

    /// 2, 14, 17, 18. Nothing reaches the owner; the burner keeps no coins; the sunset holds nothing while the game
    ///         runs.
    function invariant_noLeaks() public view {
        assertEq(address(sys.sunset).balance, 0);
        assertEq(owner.balance, safe0, "owner received nothing");
        assertEq(sys.token.balanceOf(address(sys.burner)), 0, "bought coins are burned");
        assertEq(handler.adversarialSuccesses(), 0, "an unauthorised call succeeded");
    }

    /// 12. No listed collection NFT's notional ever rises.
    function invariant_commitmentsNeverWorsen() public view {
        assertEq(handler.notionalIncreases(), 0);
    }

    /// 20. Burner conservation: every ETH it received is still in the reserve or a bucket, spent on the coin, or
    ///     reimbursed to the keeper of the slice it paid for; its balance equals the reserve and its buckets.
    function invariant_burnerConservation() public view {
        CollectionBurner b = sys.burner;
        assertEq(
            b.reserveIn() + b.ongoingIn(),
            b.reserve() + b.ongoingBalance() + b.milestoneBalance() + b.ongoingSpent() + b.milestoneSpent()
                + b.keeperPaid()
        );
        assertEq(address(b).balance, b.reserve() + b.ongoingBalance() + b.milestoneBalance());
    }

    /// 17. The vault's ETH is exactly its inflows less its outflows (D64 adds the fee overflow to the burner).
    function invariant_vaultConservation() public view {
        FundingVault v = sys.vault;
        assertEq(
            address(v).balance + v.acquisitionSpend() + v.finderFees() + v.sweepRewards() + v.gameCapitalSent()
                + v.migratedOut() + v.overflowOut(),
            v.tradingFees() + v.contributions() + v.surplusIn() + v.returnedFromGame()
        );
    }

    /// 16. The FWA pool owner never changes.
    function invariant_poolOwnerFixed() public view {
        assertEq(pool.owner(), address(sys.poolOwner));
        assertEq(sys.poolOwner.game(), address(sys.game));
    }

    /// 24. Without an executed migration or sunset nothing migrates: V1 stays live, fees go to the vault, and no
    ///     stranger or owner call reaches a migration hook.
    function invariant_migrationLocked() public view {
        assertEq(sys.hook.feeRecipient(), address(sys.vault), "fee route");
        assertFalse(sys.migration.started(), "V1 live");
        assertFalse(sys.game.retiring(), "not retiring");
        assertEq(handler.adversarialSuccesses(), 0, "no adversarial call succeeded");
    }

    /// D79: the operating reserve always covers the largest prize on the board, and keeper pay never exceeds the
    /// owner's flat fee bound per call (the pay itself is checked against the allowance above).
    function invariant_reserveCoversLargestPrize() public view {
        (uint256 reserveTarget,,,,,,,) = sys.game.settings();
        assertGe(reserveTarget, sys.game.maxBacking(), "reserve below the largest prize");
        assertLe(sys.game.keeperParams().flatFee, 0.1 ether, "flat fee within its bound");
    }
}
