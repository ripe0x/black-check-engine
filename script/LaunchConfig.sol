// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeploySystem} from "./DeploySystem.sol";
import {CollectionGame} from "../src/game/CollectionGame.sol";
import {FundingVault} from "../src/core/FundingVault.sol";
import {CollectionPoolOwner} from "../src/core/CollectionPoolOwner.sol";
import {CollectionBurner} from "../src/treasury/CollectionBurner.sol";
import {ChecksDesk} from "../src/checks/ChecksDesk.sol";

/// @notice Launch configuration of the Checks game. Every launch value lives here (or in the environment file), never
///         in `src/`. `_collectionConfig` is collection-games' template (its values carry the Ape game's decisions,
///         docs/base/IMPLEMENTOR_DECISIONS.md); `_checksConfig` applies this project's decisions (docs/DECISIONS.md).
abstract contract LaunchConfig is DeploySystem {
    address internal constant MAINNET_CHECKS = 0x036721e5A769Cc48B3189EFbb9ccE4471E8A48B1;
    address internal constant MAINNET_EDITIONS = 0x34eEBEE6942d8Def3c125458D1a86e0A897fd6f9;
    address internal constant MAINNET_SHAPES = 0x6fE9193276bF7aBCbEE44AB7aFd717d637D6FAf0;
    address internal constant MAINNET_FWA_FACTORY = 0xF5A3A153164791AB579C3d9ba5DBECf7cDfd300c;
    address internal constant MAINNET_FWA_IMPL = 0xEaa4d032908A9734a2c7939c0D211c35ad51eb31;
    address internal constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant MAINNET_FWA_TOKEN = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address internal constant MAINNET_SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    address internal constant MAINNET_LAYER_BURNER = 0x2eDBdF011768d8cd4Ef537658b41440900C52000; // artcoins' $LAYER BurnRouter

    /// @dev The 50-row opening board (D64, A4: D45 halved, without the 1 ETH Shape and the 0.06 Pack): 24 x 0.01 ETH
    ///      Shape, 16 x 0.02 Pack, 3 x 0.03 Pack, 1 x 0.04 Pack, 3 x 0.05 Shape, 1 x 0.1 Shape, 1 x 0.15 Pack, 1 x 0.5
    ///      Shape: 1.59 ETH of backing. A backing
    ///      that is a Shapes denomination is one Shape; any other is a Draw Pack of the fewest Shapes adding up to it
    ///      (0.02 = 2 x 0.01, 0.15 = 0.1 + 0.05; CollectionPoolOwner.makeup). Rows are interleaved (each next row
    ///      goes to the tier furthest behind its share) so any prefix, and the growth that repeats the pattern as the
    ///      collection NFTs need rows (D59), keeps the board's mix. The owner can replace the board later
    ///      (`CollectionGame.setPattern`: a new pattern applies to each row the next time it is listed).
    function _boardPattern() internal pure returns (uint256[] memory p) {
        uint256[10] memory values = [
            uint256(0.01 ether), 0.02 ether, 0.03 ether, 0.04 ether, 0.05 ether, 0.06 ether, 0.1 ether, 0.15 ether,
            0.5 ether, 1 ether
        ];
        uint256[10] memory counts = [uint256(24), 16, 3, 1, 3, 0, 1, 1, 1, 0];
        p = _interleave(values, counts);
    }

    /// @dev Orders `counts[i]` rows of `values[i]` so every prefix keeps each tier near its share.
    function _interleave(uint256[10] memory values, uint256[10] memory counts) internal pure returns (uint256[] memory p) {
        uint256 total;
        for (uint256 i; i < 10; ++i) {
            total += counts[i];
        }
        uint256[10] memory placed;
        p = new uint256[](total);
        for (uint256 k; k < total; ++k) {
            uint256 best;
            uint256 bestScore = type(uint256).max;
            for (uint256 i; i < 10; ++i) {
                if (placed[i] == counts[i]) continue;
                uint256 score = (2 * placed[i] + 1) * 1e18 / counts[i];
                if (score < bestScore) (best, bestScore) = (i, score);
            }
            p[k] = values[best];
            ++placed[best];
        }
    }

    /// @notice The template every collection starts from. The bid's reference price must be set per collection.
    function _collectionConfig(address owner, address collection, string memory name, string memory symbol)
        internal
        pure
        returns (Config memory c)
    {
        c.owner = owner;
        c.collection = collection;
        c.shapes = MAINNET_SHAPES;
        c.fwaFactory = MAINNET_FWA_FACTORY;
        c.fwaImplementation = MAINNET_FWA_IMPL;
        c.poolManager = MAINNET_POOL_MANAGER;
        c.seaport = MAINNET_SEAPORT; // the vault's one marketplace adapter fills Seaport 1.6 orders
        c.name = name;
        c.symbol = symbol;
        c.supply = 1_000_000_000 ether;
        // the opening price (D70, owner): about 32.6M coins per ETH, an opening FDV of about 30.7 ETH (≈ $69k at a
        // $2,242 ETH); fixed at deployment so the owner's launch call cannot pick another (final audit B-F6)
        c.startTick = 173_000;
        // ordinary trading fees, each way (D64, A1; owner-adjustable up to 10%). The opening curve is fixed in the hook:
        // 69% on buys and sells at launch, one point less a minute, down to these (about minute 64)
        c.buyFeeBps = 500;
        c.sellFeeBps = 500;
        c.boardPattern = _boardPattern();
        c.initialBoardSize = 50; // D64, A4: the 50-row pattern once
        c.listBatch = 3; // rows waiting that make a replacement window due (with FWA cooldown 0)
        c.maxPerCall = 8; // prizes listed per maintenance call: every call under EIP-7825's 16,777,216 gas (D61, test/fork/TxCap.t.sol)
        c.bookPerCall = 20; // requests booked per sync or retireStep, under the same cap with a full listing batch (test/fork/TxCap.t.sol)
        c.markupBps = 1_000; // D64, A2: 10% over each prize's cost
        c.opsBps = 100; // D82: keeper allowance earned per capture, 1% of its cost (all its Shapes' mint fees included)
        c.settings = CollectionGame.Settings({
            reserveTarget: 0.5 ether, // D79: the largest prize (0.5 ETH); a buffer, not solvency: won prizes and draws in flight are protected apart
            maintenanceInterval: 5 minutes,
            minLiveBps: 7_000, // D64, A4: admission stays open with up to 15 of 50 rows waiting
            maxOutstanding: 10,
            maxEdgeBps: 500,
            maxCooldown: 30 days, // D82: an FWA cooldown alone never closes purchases (the live-rows rule covers a slow relist)
            minDistribution: 0.01 ether,
            continuityShareBps: 3_500 // D64, A5: of each distribution to the vault, while it is short of one NFT at the last price
        });
        c.maxInFlight = 10; // D82: FWA's own limit of requests awaiting randomness per pool (D65 had 3: fewest refunds)
        // the live bid (docs/SPEC.md "The bid", D59): Permanent Collection's funding-driven model. Below the activation
        // threshold (75% of the last clearing price) available ETH enters the bid at once; above it at most 1 ETH per
        // 300 blocks (~24 ETH a day, D82: the owner's choice over D59's 0.05); above 120% of the last acquisition price
        // only 0.01 ETH per 300 blocks (~0.24 ETH a day), so a bid nobody accepts climbs slowly but never stops (D60,
        // D61, D82). All owner-adjustable.
        c.bid = FundingVault.BidParams({
            thresholdBps: 7_500,
            maxSweepWei: 1 ether, // D82
            minBlocksBetweenSweeps: 300,
            maxPrice: 0, // optional emergency cap; 0 = none (a rising floor then needs no update)
            ceilingBps: 12_000, // relative ceiling: 120% of the last acquisition price, moving with every acquisition
            slowSweepWei: 0.01 ether, // D82: above it, 0.01 ETH per 300 blocks (0 would make it a hard stop)
            maxDropBps: 2_500 // D83: one acquisition lowers the funding reference by at most 25%
        });
        // fee overflow (D64, D; trigger D65): off at launch (D72), so fees from a hot start stay in the vault for later
        // Apes. The owner may turn it on (0-100%, from the next sweep): while the bid is full, that share of each
        // trading fee goes to buybacks, never the bid's ETH or one more Ape at the last price.
        c.overflowBps = 0;
        // the $LAYER share (D90, owner): the hook takes 1% of each trading fee after the launch curve and pays it to a
        // LayerTap, which forwards it to artcoins' $LAYER burn router (it can only buy and burn $LAYER)
        c.layerBps = 100;
        c.layerBurner = MAINNET_LAYER_BURNER;
        c.refPrice = 0; // per collection: the live floor at deploy (OWNER)
        c.firstThresholdBps = 10_000; // D64, A6: the first bid fills to 100% of the floor at once (opening fees buy the first NFT)
        c.packsName = "Balls"; // D82
        c.packsSymbol = "BALLS";
        c.packMinUnits = 2; // a 0.02 ETH Pack is the smallest
        // buybacks (D64, C; D74): all of the game's surplus sent to the burner is locked in its milestone reserve, so
        // gameplay's buy-and-burn builds up for the Ape pull that releases it (tiers below). Ongoing buybacks (the
        // sunset's proceeds, donations) follow play:
        // 0.05 ETH an hour when idle, 0.005 ETH more per draw and the spacing halved every 20 draws, down to 10
        // minutes, plus 1% of what waits; released ETH goes 1 ETH every 10 minutes. All owner-adjustable within the burner's hard bounds.
        c.milestoneBps = 10_000;
        c.cadence = CollectionBurner.Cadence({
            baseSliceWei: 0.05 ether,
            perDrawWei: 0.005 ether,
            backlogBps: 100, // + 1% of the ongoing bucket a slice: a fee-overflow backlog is spent (sim/results/burner.md)
            maxSliceWei: 1 ether,
            idleSpacing: 60 minutes,
            minSpacing: 10 minutes,
            drawsToHalve: 20,
            maxImpactBps: 300,
            maxDeviationBps: 200
        });
        // D74: only an Ape pull sets the pot off, and it releases all of it (burned 1 ETH every 10 minutes at most); a big
        // Shape or Pack releases nothing. Owner-adjustable (`setTiers`).
        c.tiers = CollectionBurner.Tiers({
            bigPrizeWei: 0.5 ether,
            bigPrizeBps: 0,
            firstExitBps: 10_000,
            exitWindow: 24 hours
        });
        // keepers (D63, D79): the game pays each useful maintenance call its measured gas at the transaction's gas price
        // (capped per gas, never refused) plus a flat fee, within an allowance earned from captures
        c.keeper = CollectionGame.KeeperParams({
            maxGasPrice: 3 gwei, // gas reimbursed at the transaction's price up to this
            gasOverhead: 70_000, // gas outside the game's own measurement (intrinsic, calldata, the payment)
            flatFee: 0.0002 ether, // D79: on top of the gas, per useful call, so third-party keepers have a reason to run
            payDelay: 5 minutes // D79: light work right after a player's draw is left to the next draw (unpaid)
        });
        // keeper pay before any capture: a limit, not a deposit (pay comes out of game cash as it is earned, which the
        // vault refills). D82: 0.2 ETH covers listing the 50-row board (~45M gas: about 0.05 ETH at 1 gwei, 0.14 ETH at
        // the 3 gwei cap)
        c.openingAllowance = 0.2 ether; // D82
    }

    /// @notice Checks Originals. The coin's name and symbol are placeholders the postflight refuses (invariant 9): a
    ///         deployment sets its own.
    function _checksConfig(address owner, address councilSafe, address guardian) internal pure returns (Config memory c) {
        c = _collectionConfig(owner, MAINNET_CHECKS, "Placeholder Coin", "BLACK");
        // D012: the council Safe proposes through a 7-day timelock; the guardian cancels
        c.councilSafe = councilSafe;
        c.guardian = guardian;
        c.councilDelay = 7 days;
        c.editions = MAINNET_EDITIONS;
        // D003: price per tier, council-settable. 80-Check floor 0.25 ETH (late October 2026) x Original units, no
        // rarity premium: 80, 40, 20, 10, 5, 4, 1 and Black = 1, 2, 4, 8, 16, 32, 64 and 4,096 units
        c.schedule = [uint256(0.25 ether), 0.5 ether, 1 ether, 2 ether, 4 ether, 8 ether, 16 ether, 1_024 ether];
        // D005: 0.2% of the schedule price per survived draw, down to 85%; reprice on 5% moves; D015: no daily decay
        c.listing = CollectionPoolOwner.ListingParams({
            decayBps: 20,
            floorBps: 8_500,
            stepBps: 500,
            targetBps: 2_000,
            dailyDecayBps: 0
        });
        // D008: 100 survived draws to compose (200 for singles into a Black Check); the free deterministic outcome
        // 50 draws later; coin burned for a free choice (placeholders until the coin trades)
        c.compose = ChecksDesk.ComposeParams({
            drawsToCompose: [uint32(100), 100, 100, 100, 100, 100, 200],
            graceDraws: 50,
            composeBurn: [
                uint256(1_000 ether), 2_000 ether, 4_000 ether, 8_000 ether, 16_000 ether, 32_000 ether, 1_000_000 ether
            ]
        });
        // D006: ETH buyouts at schedule + 25%; coin buyouts disabled at launch (the council enables tiers later)
        uint256[8] memory none;
        c.buyout = ChecksDesk.BuyoutParams({ethMarkupBps: 2_500, coinPrice: none});
        c.refPrice = 0.25 ether; // the 80-Check floor: the first bid's reference
        // D013, D016: no $LAYER share (an artcoins arrangement, not a Checks requirement)
        c.layerBps = 0;
        c.layerBurner = address(0);
        // D016 (sim/results/checks_market.md): collection-games' market values hold for Checks. Opening tick 173,000
        // (about 30.7 ETH fully diluted: a 1 ETH buy moves the price 6.3%; a buyback slice within the 3% impact bound
        // is about 0.46 ETH, so a Check win's pot burns in one or two slices), 5% each way after the fixed opening
        // curve, every gameplay buyback held until a Check is won and then released whole (c.milestoneBps, c.tiers)
    }
}
