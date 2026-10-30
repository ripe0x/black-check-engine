# Founder review (grouped)

Branch `dev`, local only. Nothing deployed, broadcast, spent, published or pushed.

## Decisions (answered 2026-10-30)

The founder accepted the recommendations for decisions 1-6 and kept the placeholder venue fee and opening price for
the release candidate.

| # | Decision | Outcome |
| --- | --- | --- |
| 1 | D003 Pricing source | Timelocked tier schedule; guardian halts on sharp market moves |
| 2 | D005 Decay depth | Floor 85% of schedule, 0.2% per survived draw |
| 3 | D006 Coin buyouts | Launch disabled; enabled per tier through the timelock once the coin trades with depth |
| 4 | D007 Acquisitions | Standing bid at 90% of schedule, weekly cap |
| 5 | D009 Coin venue | Design accepted; fee 1% and opening tick 161,200 remain placeholders; no opening curve |
| 6 | D001 Black Check framing | A single Check is the realistic headline; a Black Check stays possible, never promised |

Optional reviews still open: D002 (survival counts allocating draws), D004 (Shapes at backing + 10%), D008
(composition window in draws), D010 (buy-and-burn chunk and reserve).

## Values required before any mainnet deployment

Immutable at deployment: the venue fee rate and opening tick (D009 placeholders), coin name and ticker, coin supply.
Timelock-settable after deployment but still placeholders: compose coin burns, coin buyout prices (0, disabled),
weekly bid cap (0.75 ETH), Burner chunk, interval and reserve.

## Gates outside the code

1. **Name and ticker**: must be distinct from Black Check / BLKCHK (placeholder `BLACK`; the deploy script refuses it).
2. **Council**: membership, threshold (3 of 5 tentative) and guardian; independence is an offchain fact.
3. **Legal review** of paid chance draws for NFTs and the coin's buyback and buyout mechanics.
4. **Independent audit** of the scope in docs/AUDIT_SCOPE.md.
5. **Keeper operation and pay** (keepers are unpaid today).

## Proven (real mainnet contracts on a pinned fork, block 26,302,000)

- A contract creates and permanently owns an FWA pool; real draws deliver the chosen prize; owner proceeds match FWA.
- Survival counted from FWA state alone (listed − withdrawn − active count), excluding expired, timed-out and
  refunded draws; pending draws block every maintenance, sale and migration.
- Canonical composition of real tokens: a single from 64 real 80s; a Black Check from 64 real singles (742k gas).
- Edition migration to a contract vault and reveal; standing bid buying real Checks and a real Edition.
- Owner can only halt; upgrades and changes need council + 7 days; the guardian cancels; the residual drain power of a
  council majority is demonstrated, not hidden.
- Migration between two real FWA pools keeps entitlements and survival.
- Coin venue on the real Uniswap v4 PoolManager: whole supply locked, 1% ETH fee reaches the acquisition budget end
  to end; FWA creation fee bought with 0.1303 ETH; surplus released and burned.
- 50 fork tests, 2 fuzz tests, 4 stateful invariants (strict mode), deploy script simulated with postflight.

## Assumptions (not proven)

- Economics from `sim/model.py` (a model): Checks market at ≈0.25 ETH, player demand, coin volume, no rarity premium.
- FWA's factory owner does not change edge, cooldown or global switches against the game.
- The council is independent and acts within 7 days when it must.

## Open risks

- Prices lag the market by at least 7 days; a rally underprices prizes until the schedule moves (subsidy).
- Buy-and-burn without an oracle can lose up to one chunk per interval to MEV.
- With ~20 Originals, Checks leave the pool in about a month at 25 draws a day unless coin fees keep buying.
- No keeper incentive; maintenance depends on someone running it.

## Untested or partly tested

- Wallet-connected writes in the site (rendering and reads were verified at 375px; sends were not).
- Keeper jobs other than listing and fee forwarding were not run live (decision logic unit-tested; contract paths
  fork-tested).
- Real Chainlink VRF timing and gas-price dynamics (VRF words are delivered by impersonation in tests).
- No independent human audit.

## Actions only you can authorize

Any mainnet deployment or broadcast, buying FWA or Checks, launching the coin market, choosing council keys,
publishing the site, pushing this repository.
