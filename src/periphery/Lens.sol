// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFWAPool} from "../interfaces/IFWA.sol";

interface ILensGame {
    function pool() external view returns (IFWAPool);
    function activated() external view returns (bool);
    function paused() external view returns (bool);
    function retired() external view returns (bool);
    function ready() external view returns (bool);
    function boardSize() external view returns (uint256);
    function liveCount() external view returns (uint256);
    function liveAt(uint256 i) external view returns (uint256);
    function items(uint256 id) external view returns (uint48, uint72, uint72, uint24, uint16, uint16, bool);
    function owedCount() external view returns (uint256);
    function cash() external view returns (uint256);
    function capitalIn() external view returns (uint256);
    function inventoryBacking() external view returns (uint256);
    function inventoryCost() external view returns (uint256);
    function replacementsOwed() external view returns (uint256);
    function turnover() external view returns (uint256);
    function revenue() external view returns (uint256);
    function collectionRevenue() external view returns (uint256);
    function prizeExpense() external view returns (uint256);
    function keeperAllowance() external view returns (uint256);
    function keeperPaid() external view returns (uint256);
    function distributed() external view returns (uint256);
    function toVault() external view returns (uint256);
    function toBurner() external view returns (uint256);
    function profit() external view returns (int256);
    function protectedCash() external view returns (uint256);
    function capitalNeed() external view returns (uint256);
    function distributable() external view returns (int256, uint256);
    function pullsFulfilled() external view returns (uint256);
    function collectionWins() external view returns (uint256);
    function pullsRefunded() external view returns (uint256);
    function pullsExpired() external view returns (uint256);
    function vault() external view returns (address);
    function poolOwner() external view returns (address);
    function burner() external view returns (address);
}

interface ILensVault {
    function tradingFees() external view returns (uint256);
    function contributions() external view returns (uint256);
    function generalBalance() external view returns (uint256);
    function shortfall() external view returns (uint256);
    function lastPrice() external view returns (uint256);
    function referencePrice() external view returns (uint256);
    function acquisitionCount() external view returns (uint256);
    function liveBid() external view returns (uint256);
    function activationThreshold() external view returns (uint256);
    function nextSweepBlock() external view returns (uint256);
}

interface ILensPoolOwner {
    function listedCount() external view returns (uint256);
    function listedAt(uint256 i) external view returns (uint256);
    function custodyCount() external view returns (uint256);
    function exposureBps() external view returns (uint256);
    function listingParams() external view returns (uint256, uint256, uint256, uint256, uint256 targetBps);
    function openCollection() external view returns (uint256);
    function rowsShort() external view returns (uint256);
    function nfts(uint256 tokenId) external view returns (uint128 refCost, uint128 cashCost, uint128, uint8, uint8);
    function heldCount() external view returns (uint256);
}

interface ILensBurner {
    function reserve() external view returns (uint256);
    function ongoingBalance() external view returns (uint256);
    function milestoneBalance() external view returns (uint256);
    function ongoingIn() external view returns (uint256);
    function milestoneIn() external view returns (uint256);
    function ongoingSpent() external view returns (uint256);
    function milestoneSpent() external view returns (uint256);
    function totalBurned() external view returns (uint256);
}

/// @title Lens
/// @notice Read-only aggregation for the site and the keeper. Holds nothing and has no state. Probabilities are
///         computed from FWA's live weights: P(listing) = weight / totalWeight.
contract Lens {
    struct Prize {
        uint256 listingId;
        bool collection;
        uint256 tokenId;
        uint256 price; // FWA listing notional
        uint256 backing; // Shapes: exact ETH redeemable; collection: 0
        uint256 refCost; // collection: reference cost
        uint256 probabilityE18; // chance per pull, 1e18 = 100%
    }

    struct Funding {
        bool activated;
        bool ready;
        bool paused;
        bool retired;
        uint256 tradingFees;
        uint256 contributions;
        uint256 balance; // everything the vault holds
        uint256 shortfall; // how far its Ape budget is from one Ape at the funding reference (surplus share goes here)
        uint256 lastPrice; // the last price paid
        uint256 referencePrice; // what the next Ape is taken to cost (D83)
        uint256 collectionHeld;
        uint256 capitalNeed;
        uint256 liveBid; // the vault's live bid now
        uint256 activationThreshold; // below it, available ETH fills the bid at once
        uint256 nextSweepBlock; // first block a metered sweep may run
        uint256 acquisitions;
    }

    struct Books {
        uint256 turnover;
        uint256 revenue;
        uint256 collectionRevenue;
        uint256 prizeExpense;
        uint256 keeperPaid;
        uint256 keeperAllowance;
        int256 profit;
        uint256 distributed;
        uint256 toVault;
        uint256 toBurner;
        uint256 cash;
        uint256 protectedCash;
        uint256 distributableNow;
        uint256 inventoryBacking;
        uint256 inventoryCost;
        uint256 replacementsOwed;
        uint256 capitalIn;
        uint256 pullsFulfilled;
        uint256 collectionWins;
        uint256 pullsRefunded;
        uint256 pullsExpired;
    }

    struct Buybacks {
        uint256 ongoingBalance;
        uint256 milestoneBalance;
        uint256 milestoneReserve;
        uint256 ongoingIn;
        uint256 milestoneIn;
        uint256 ongoingSpent;
        uint256 milestoneSpent;
        uint256 burned;
    }

    struct Quote {
        uint256 fee;
        uint256 vrf;
        uint256 total;
        uint256 inventoryVersion;
        bool open;
        uint256 exposureBps; // collection exposure now
        uint256 targetBps; // the exposure target
        uint256 apesListed; // collection NFTs in the draw
        uint256 apesWaiting; // collection NFTs in custody, waiting to be listed
        uint256 boardSize; // ordinary rows in play
        uint256 owedRows; // rows waiting for a prize
        uint256 rowsShort; // rows the collection NFTs are waiting for
    }

    function funding(address game) external view returns (Funding memory f) {
        ILensGame g = ILensGame(game);
        ILensVault v = ILensVault(g.vault());
        f.activated = g.activated();
        f.ready = g.ready();
        f.paused = g.paused();
        f.retired = g.retired();
        f.tradingFees = v.tradingFees();
        f.contributions = v.contributions();
        f.balance = v.generalBalance();
        f.shortfall = v.shortfall();
        f.lastPrice = v.lastPrice();
        f.referencePrice = v.referencePrice();
        f.collectionHeld = ILensPoolOwner(g.poolOwner()).heldCount();
        f.capitalNeed = g.capitalNeed();
        f.liveBid = v.liveBid();
        f.activationThreshold = v.activationThreshold();
        f.nextSweepBlock = v.nextSweepBlock();
        f.acquisitions = v.acquisitionCount();
    }

    function books(address game) external view returns (Books memory b) {
        ILensGame g = ILensGame(game);
        b.turnover = g.turnover();
        b.revenue = g.revenue();
        b.collectionRevenue = g.collectionRevenue();
        b.prizeExpense = g.prizeExpense();
        b.keeperPaid = g.keeperPaid();
        b.keeperAllowance = g.keeperAllowance();
        b.profit = g.profit();
        b.distributed = g.distributed();
        b.toVault = g.toVault();
        b.toBurner = g.toBurner();
        b.cash = g.cash();
        b.protectedCash = g.protectedCash();
        (, b.distributableNow) = g.distributable();
        b.inventoryBacking = g.inventoryBacking();
        b.inventoryCost = g.inventoryCost();
        b.replacementsOwed = g.replacementsOwed();
        b.capitalIn = g.capitalIn();
        b.pullsFulfilled = g.pullsFulfilled();
        b.collectionWins = g.collectionWins();
        b.pullsRefunded = g.pullsRefunded();
        b.pullsExpired = g.pullsExpired();
    }

    function buybacks(address game) external view returns (Buybacks memory r) {
        ILensGame g = ILensGame(game);
        ILensBurner br = ILensBurner(g.burner());
        r.ongoingBalance = br.ongoingBalance();
        r.milestoneBalance = br.milestoneBalance();
        r.milestoneReserve = br.reserve();
        r.ongoingIn = br.ongoingIn();
        r.milestoneIn = br.milestoneIn();
        r.ongoingSpent = br.ongoingSpent();
        r.milestoneSpent = br.milestoneSpent();
        r.burned = br.totalBurned();
    }

    function quote(address game) external view returns (Quote memory q) {
        ILensGame g = ILensGame(game);
        IFWAPool p = g.pool();
        ILensPoolOwner o = ILensPoolOwner(g.poolOwner());
        if (address(p) != address(0)) {
            (q.fee, q.vrf, q.total) = p.quoteAcquisitionPrice(1);
            q.inventoryVersion = p.inventoryVersion();
            q.open = p.localPurchasesEnabled();
        }
        q.exposureBps = o.exposureBps();
        (,,,, q.targetBps) = o.listingParams();
        q.apesListed = o.openCollection();
        q.apesWaiting = o.custodyCount();
        q.boardSize = g.boardSize();
        q.owedRows = g.owedCount();
        q.rowsShort = o.rowsShort();
    }

    /// @notice Every prize in the draw now (FWA Active), with its live probability.
    function prizes(address game) external view returns (Prize[] memory out) {
        ILensGame g = ILensGame(game);
        IFWAPool p = g.pool();
        if (address(p) == address(0)) return out;
        ILensPoolOwner o = ILensPoolOwner(g.poolOwner());
        uint256 total = p.totalWeight();
        uint256 nShapes = g.liveCount();
        uint256 nColl = o.listedCount();
        out = new Prize[](nShapes + nColl);
        uint256 k;
        for (uint256 i; i < nShapes; ++i) {
            uint256 id = g.liveAt(i);
            (Prize memory pr, bool active) = _listing(p, id, total);
            if (!active) continue;
            (, uint72 backing,,,,,) = g.items(id);
            pr.backing = backing;
            out[k++] = pr;
        }
        for (uint256 i; i < nColl; ++i) {
            uint256 id = o.listedAt(i);
            (Prize memory pr, bool active) = _listing(p, id, total);
            if (!active) continue;
            pr.collection = true;
            (pr.refCost,,,,) = o.nfts(pr.tokenId);
            out[k++] = pr;
        }
        assembly ("memory-safe") {
            mstore(out, k)
        }
    }

    function _listing(IFWAPool p, uint256 id, uint256 total) internal view returns (Prize memory pr, bool active) {
        (,,, uint256 tokenId, uint256 weight, uint256 price,, IFWAPool.ListingStatus st) = p.listings(id);
        active = st == IFWAPool.ListingStatus.Active;
        pr.listingId = id;
        pr.tokenId = tokenId;
        pr.price = price;
        pr.probabilityE18 = total == 0 ? 0 : weight * 1e18 / total;
    }
}
