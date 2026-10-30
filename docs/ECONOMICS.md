# Economics (Phase 3)

Model: `sim/model.py` (stdlib Python, 60 seeded runs per scenario, 2 years). Results: `sim/results/phase3.md`.
A model, not evidence of real behavior. FWA's fee, selection and owner split are reproduced from the verified
source and match the fork receipts (E2). Market anchor: Checks Originals floor about 0.25 ETH (late October 2026,
NFT Duck and OKX listings; recheck before any decision).

## What the mechanics imply

1. **Draws are close to zero-sum.** FWA charges 1.05 × the harmonic mean of notionals and the owner keeps 1.025 ×.
   If every notional equals its market value, the protocol earns about 2.5% of the harmonic mean per draw and
   players get back about 95% in value, less VRF. The game itself does not fund Checks; coin trading fees do.
2. **Shapes need a markup.** A won Shape costs its backing plus the 0.001 ETH Shapes mint fee to replace: 10% on a
   0.01 ETH Shape, more than the 2.5% margin. At exact backing the base case's operating P&L is −12 ETH over two
   years; at backing + 10% it is +13 ETH (D004).
3. **Decay below about 85% of value turns draws positive-EV.** With 20 Checks among 57 listings, players break even
   when every Check sits at 87.5% of its value (exact formula in `sim/results/phase3.md`). Below that the protocol
   pays a subsidy on every Check won and arbitrage players draw until Checks leave. A floor near that bound keeps
   decay as a shift of odds toward long survivors rather than a giveaway (D005).
4. **Checks leave fast.** At 25 draws a day, 20 Originals are won in about a month without purchases: each 0.25 ETH
   Check carries 25× the selection weight of a 0.01 ETH Shape. Survival thresholds and the purchase rate decide
   how far composition gets before players win the inputs.
5. **A Black Check is out of reach of this design's funding.** It needs 4,096 Original-equivalents (about 1,024 ETH
   at the floor, before any rarity premium), and 64 singles all surviving in the pool. No simulated scenario formed
   one. Best case for a single Check within two years: 27-48% (recommended settings, or low play). See D001.
6. **Purchase depth binds before income.** With a cap of 3 purchases per week, extra coin volume accumulates unspent
   (1,397 ETH unspent at 200 ETH/day). Real listing depth for 80s needs measuring before raising the cap; buying
   faster would lift the market against us.
7. **Keeper gas matters at high gas prices.** The draw-by-draw survival cursor costs ~29k gas per draw; at 20 gwei
   that consumes most of the owner's margin (operating P&L −5 ETH). The controller can derive the same count in
   O(1) from FWA's `activeListingCount` because it is the pool's only depositor (C010). With that, 20 gwei gives
   operating P&L +5.6 ETH; the model now assumes it.

## Proposed launch configuration (for founder review)

| Parameter | Proposal | Why |
| --- | --- | --- |
| Shape notional | backing × 1.10 | covers the 0.001 ETH mint fee and adds margin (D004) |
| Decay | 0.2% of schedule per survived draw (linear), floor 85% | stays above the player break-even bound (D005) |
| Survival threshold | 100 draws per tier, 200 for Black | P(single in 2 years) 27% in the base case |
| Tier schedule | units × floor price, reviewed monthly, 7-day timelock | D003 |
| Purchases | 80s at most 3 per week until depth is measured | thin market |
| Coin fee share | 1% of volume to the protocol (placeholder) | venue and rate are Phase 4 (R12) |

Base-case result with these values: game P&L +11.1 ETH over two years (p10 −2.6, p90 +19.0), subsidy 4.5 ETH,
158 Checks won by players, 169 compositions, median best tier 4 Checks.

## Sensitivities (medians, 2 years)

See `sim/results/phase3.md` for the full table. Highlights: zero coin volume leaves 11 Checks won and no purchases
(the game stops having Checks once the launch inventory is gone); a Checks rally or a 3× jump raises the subsidy to
17-20 ETH because the schedule lags; a crash lowers it to 5 ETH; 20 gwei gas costs about 8.5 ETH of keeper gas over
two years (about 19 ETH with a draw-by-draw cursor).

## Not yet modelled

BLACK buyouts (a burn priced against inventory), ETH buyouts, coin price and liquidity, rarity premia from real
sales, keeper reimbursement policy, FWA parameter changes.
