# Founder review (grouped)

State at commit b608e19, branch `dev`, local only. Nothing deployed, broadcast, spent, published or pushed.
Reply to the numbered decisions in one message; everything else keeps moving without you.

## Decisions required before a release candidate

| # | Decision | My recommendation | What changes if you disagree |
| --- | --- | --- | --- |
| 1 | **D003 Pricing source**: tier schedule set through the 7-day timelock vs signed market quotes | Timelocked schedule; guardian halts on sharp market moves | Add a quote module and its signers (new trusted party) |
| 2 | **D005 Decay depth**: floor at 85% of schedule, 0.2% per survived draw | Keep near the player break-even bound | Deeper decay gives a bigger subsidy (32 ETH over 2 years at 25%) and invites arbitrage draws |
| 3 | **D006 Coin buyouts**: timelocked coin price per tier, launched disabled | Enable per tier only once the coin trades with depth | An oracle hook or no coin buyouts |
| 4 | **D007 Acquisitions**: standing bid at 90% of schedule, weekly cap, vs keeper-run marketplace orders | Standing bid | Build a restricted Seaport adapter |
| 5 | **D009 Coin venue**: fee rate (1% placeholder), opening price (≈100 ETH fully diluted placeholder), opening anti-sniper curve (dropped) | Set the rate and price; decide whether launch sniping matters | Rate and price are immutable at deployment; the curve is a contained addition |
| 6 | **D001 Black Check framing**: it needs 4,096 Original-equivalents (≈1,024 ETH at a 0.25 ETH floor, 25.6% of all units that can exist) | Present a single Check as the realistic headline; buy singles and high tiers when cheap | Messaging only |

Optional reviews: D002 (survival counts allocating draws), D004 (Shapes at backing + 10%), D008 (composition window in
draws), D010 (buy-and-burn chunk and reserve).

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
