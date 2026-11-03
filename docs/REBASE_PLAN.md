# Rebase plan: Checks Survival Protocol on the Collection Games base

Date: 2026-11-03. **Owner decisions recorded the same day: D012 option (b), more locked down; D013 as
recommended; D014 stay on V2 (FWA reopened V2 creation at block 26,335,860); D015 the remaining choices as
recommended. Sections 5 and 8 below are now decided, not open.** Inputs: this repository at `rc2` (6b00eed, docs at 075b67d) and `ripe0x/collection-games` at 409ca75
(D92, eight audit rounds). Nothing in this plan has been built yet. Owner direction: collection-games is the base to
build from. Work in this repository began before collection-games was finished.

## 1. Recommendation in one paragraph

Rebuild the protocol on collection-games' contracts, scripts, keeper, site, tests and process. Keep from this
repository only what is specific to Checks and already proven: the Checks and Editions integration and its fork
experiments, survival derived in O(1) from FWA state (C010), composition and Black Check formation, the
tier-schedule pricing and the per-tier bid (D003, D007), ETH and coin buyouts (D006), the code-hash pin tests, and
the council, timelock and guardian deployment pattern. Two things must not come across unchanged. First,
collection-games' single-owner trust model breaks founder invariants 10 and 11 (section 5); it needs an owner
decision before it reaches production code. Second, FWA switched off V2 pool creation on 2026-11-02 (section 3).
Retire `Engine`, `FwaV2Controller`, `Venue*`, `Burner` and `Coin` once the ported equivalents pass, and do not keep
two implementations running side by side (CLAUDE.md, engineering rule 6).

## 2. Where the two repositories stand

| | black-check-engine (this repo) | collection-games |
| --- | --- | --- |
| Product | Checks survival and composition game, own coin (placeholder BLACK) | Ape game for BAYC (ApeBall / APEBALL), own coin |
| Last work | rc2, 2026-10-30; one external audit (rc1) | D92, 2026-11-02; fresh-discovery audit plus final rounds 1-8 |
| Contracts | 8 (`Engine` UUPS 654 lines, `FwaV2Controller`, `Coin`, `VenueHook`, `VenueLiquidity`, `Burner`, `FwaFeeBuyer`, OZ timelock) | 16 permanent and periphery contracts (`Admin`, `Governed`, `FundingVault`, `CollectionPoolOwner`, `CollectionGame`, `CollectionToken`, `CollectionHook`, `ProtocolLiquidity`, `CollectionBurner`, `MigrationAuthority`, `Sunset`, `DrawRouter`, `FwaFeeRoutes`, `SeaportAdapter`, `LayerTap`, `Lens`) plus Draw Packs |
| Trust | Council (3 of 5) proposes through a 7-day timelock, guardian can cancel, operator can only halt; the Engine can be upgraded | One owner (`Admin`), acts at once within bounds; migration and fee-recipient changes on 72 hours' notice with code pinned; instant Sunset into buybacks |
| Tests | 60 fork tests, 2 fuzz, 4 strict invariants; fork block 26,302,000 | about 30 fork suites, invariants, scenarios (50 to 100 Apes, throughput, long run), size and tx-gas-cap suites; fork block 26,284,000 |
| Same dependency pins | forge-std 7fdf81f, solady acd959a, v4-core 59d3ecf, v4-periphery 60cd938, solc 0.8.28 cancun | same, plus shapes 1b84c10 and shape-packs 3a463f7; no via-IR except Packs |

The dependency pins match, so porting needs no library migration. OpenZeppelin comes from `lib/shapes` in
collection-games and from its own submodule here. Keep the separate submodule because `TimelockController` needs it.

## 3. A fact that changes the baseline: FWA V2 pool creation was off, then reopened

**Update (D014):** read-only calls to the V2 factory show `poolCreationEnabled` false from block 26,329,277 and true
again from block 26,335,860 (2026-11-03 17:46:23 UTC). At the latest block read (26,337,042) `betaAccess` is false and
`edgeBps` is 500. The venue is V2. The text below is the original analysis.


collection-games D89 records that FWA deployed new "community pool" contracts (factory `0x8919…477C`, block
26,328,828) and switched off V2 pool creation at block 26,329,277. Existing V2 pools still run. FWA's founder plans to
reopen V2 creation for the ApeBall deploy. A community pool pays its owner only the base price, and FWA keeps the
whole edge. collection-games estimated its game margin would fall from about 11% to about 8.7% of each ticket. Its
port to community pools sits at commit 72d5179, which was reverted and never audited: 264 of 274 tests passed, with
FWA's switches opened inside the local fork only.

Consequences for this project:

- Every fork test here is pinned before the switch-off, so nothing in this repository proves a pool can be created
  today. The deploy routine must check `poolCreationEnabled()` before it does anything else, as collection-games
  DEPLOY.md does.
- This also helps us. Invariant 11 calls for migration to a genuinely new FWA implementation, and
  `Migration.t.sol` currently uses a labelled `NextGenControllerMock`. The community pool factory is real,
  differently built FWA code. A V2 → community-pool migration on a fork after block 26,330,000 replaces the mock with
  real evidence.

## 4. Area-by-area comparison and what to do

"Adopt" means take collection-games' code and design and adapt them to Checks. "Keep" means keep this repository's
approach. "Decide" means an owner decision is needed (section 7).

| Area | Here today | collection-games solution | Action |
| --- | --- | --- | --- |
| FWA purchase gate | `canPurchase` refuses 5 addresses only | Live gate (D36): in-flight bound that assumes a full batch, a maximum FWA edge, a minimum number of Shapes, an exposure cap after the worst case of unsettled requests; refuses every system contract as purchaser (D67, D81 `isSystem`); fits FWA's 100k-gas stipend; fails closed | **Adopt.** Add Checks and Editions to the refusal list. This closes the open assumption that FWA's factory owner does not raise the edge |
| Draw booking and accounting | Engine collects owner proceeds; survival is derived, with no per-request ledger | `CollectionGame` walks FWA's request sequence, books each pull once, books revenue at the lower-bound edge and trues it up (D40), and recounts owed replacements after a Shapes fee change (R3-3) | **Adopt** `CollectionGame` close to unchanged; the collection NFT is Checks. Keep C010 survival as a separate counter (section 6) |
| Shapes and Packs | Shapes restocked at recorded backing, listed at backing + 10% (D004) | Board pattern, grow-only size, a dedicated Draw Packs instance, Packs made of the fewest Shapes, at most 4 Shapes per Pack (D85), markup and allocation frozen per listing | **Adopt.** This meets invariant 7 (Shapes and optional Packs) fully. D004's +10% becomes the board markup setting |
| Keeper pay | None (open item) | Gas plus a flat fee within an allowance earned from captures (D79); players run light upkeep for free through the DrawRouter (D77, D82); the owner fixes how much one call books (D80); a guard reverts the whole call when a step runs out of gas, so paid work is never skipped (D63) | **Adopt.** This closes the "keepers are unpaid" gate |
| Player draw path | Direct FWA purchase | `DrawRouter`: settles waiting draws, draws, runs upkeep within a measured gas budget, `redeemAndDraw` pays with winnings in one transaction, bound to its game and pool (D79, B-F4) | **Adopt** |
| Transaction gas cap | Not measured | `TxCap.t.sol` holds every maintenance call under 90% of EIP-7825's 16,777,216 gas; per-call ceilings were measured, not guessed (D61, D81, D85) | **Adopt.** Add Checks cases: withdrawing 64 singles, `infinity`, a compose batch, a reprice batch |
| Contract size | via-IR, no size test | `Sizes.t.sol` freezes size headroom; no via-IR | **Adopt** the test. Measure whether via-IR is still needed once the Engine is gone |
| Coin | Solady ERC-20, `burnFrom`, unrestricted | `CollectionToken`: transfers restricted to the canonical pool (D71, net signed allowance D79), allowlist of at most 50 (D84), URC-5 venue policy, ERC-7572 metadata (D86), `unrestrict` once | **Adopt** the code. Restriction and allowlist are **Decide** items: they change how holders can use the coin. Composition and coin-buyout burns still work because burns always pass |
| Coin market and hook | 1% flat ETH fee to acquisitions, no opening curve (D009), fixed opening tick | Fixed 69% opening curve falling one point a minute, exact-output fees charged on gross, opening tick fixed at construction and range-checked by postflight (B-F6), block-open price exposed to the burner, market opens only once the FWA pool exists (D91) | **Adopt** the mechanics; D91 and the fixed tick are safety items. Fee rate and curve are **Decide** (D009 was approved without a curve) |
| Buy-and-burn | `Burner`: chunk bounded so a sandwich cannot pay (D011 H1), daily release above a reserve (D010) | `CollectionBurner`: same-block price check and impact cap (≤ 5% impact, ≤ 3% deviation), slices ≤ 1 ETH, cadence keyed to play, milestone reserve released only on wins FWA shows as delivered, keeper reimbursed from the slice | **Adopt.** Milestone trigger: a Check won (or a Check at or above a set tier). Values are **Decide** (they replace D010) |
| Acquisition | Standing bid per tier at 90% of the schedule, weekly cap, `sellCheck`, `sellEdition` (D007) | `FundingVault` live bid (metered sweep, threshold, ceiling with a slow climb, `referencePrice` that resists 1-wei sales D83), Seaport adapter hardened against appended consideration and contract orders (D70), contributions, stray-NFT claims | **Keep** the per-tier schedule bid: it is approved, and pricing from the schedule already avoids D83's problem. **Adopt** the vault's structure (one balance, contributions, metering, custody postconditions). The Seaport adapter is optional (**Decide**, D007 chose no marketplace orders) |
| Decay | 0.2% of schedule per survived draw, floor 85% (D005) | Gameplay-credit decay plus an optional daily decay (D78), absolute floor (D82), never raises a published notional, exposure target, reprices only with nothing unsettled (D82) | **Keep** the D005 rule and values (approved). **Adopt** the guards: never raise, exposure target, nothing-unsettled restock and reprice, batches under the gas cap. Offer the daily decay switched off, as in D78 |
| Upgrade and migration | UUPS Engine; new controller through the timelock; inventory migrated with survival carried | Permanent contracts, no proxy. `MigrationAuthority`: proposal, 72 hours, successor code-hash pinned, permissionless batched hand-over; separate fee-recipient notice; instant final `Sunset` (Dutch auction 150% → 25% over 30 days, every wei to buy-and-burn) | **Adopt** the structure. **Decide** who proposes (section 5). Successor checklist from D66/D67: no proxy, no admin-settable payout |
| Administration | Council plus timelock for everything sensitive, operator halts | `Admin` single owner, two-step transfer, renounce; `sweepNFT` only for unprotected tokens (D62); every owner power listed with its worst case (SECURITY.md) | **Adopt** `Admin`, `Governed`, protected-token sweep and the powers table. **Decide** the split between instant and timelocked powers (section 5) |
| FWA creation fee | `FwaFeeBuyer` (already ported from collection-games) | `FwaFeeRoutes`: buyer plus `FwaFeeRelay` (owner's FWA through the transfer lock) | **Adopt** the file (it is a superset). Irrelevant if a community pool is used (no creation fee) |
| $LAYER share | None | 1% of each post-curve fee to artcoins' $LAYER burn (D87-D90) | **Decide.** Recommendation: leave it out. It is an artcoins relationship, not a Checks requirement, and it adds an instant owner power |
| Deploy and ops | One routine plus postflight, simulation by default, name gate, rehearsal script | The same pattern, extended: postflight checks every setting, every launch board row, purchaser exclusions, approvals, names; `DEPLOY_ENV` must match the chain; `I_AM_THE_OWNER=yes` required inside the script (D81, D85); local dev chain with a VRF keeper (`script/local.sh`, `keeper/src/local-vrf.mjs`); `ForkBase` pins the gas price | **Adopt.** Keep the name gate (invariant 9) |
| Keeper bot | Simulate then send, dry run by default, 7 unit tests | Primary and backup modes, a gas-price ceiling, skips calls that would pay 0, retries milestone releases | **Adopt.** Add Checks jobs: reprice, compose fallback after the grace window, staged Black formation |
| Site | Minimal Next.js: home, checks, collect, compose, trust | Full play flow: live odds, all-in cost, verified wins, redeem-and-draw, governance feed. Safety: deployment record bundled with the site, pool keys built locally (B-F4/B-F5), rounding in the user's favour done in integer arithmetic (D81, D85), draw retry safety (F6-2, F7-3) | **Adopt** as the base. Port the compose, collect and survival views from here |
| Simulation | `sim/model.py` (17 scenarios) | `pool.py`, `launch.py`, `burner.py`, `keepers.py`, `maintenance.py`, `sessions.py`, `economics.py`; throughput measured on the fork (`Throughput.t.sol` → table) | **Adopt** the structure. Port the Checks-specific parts of `model.py` (tiers, composition, survival thresholds) into `pool.py` |
| Docs and audit process | DECISIONS, STATUS, RISKS, THREAT_MODEL, AUDIT_SCOPE, FOUNDER_REVIEW | ADMIN (powers and worst cases), MIGRATION, SECURITY, RUNBOOK, DEPLOY, LAUNCH_CHECKLIST; a sealed fresh-eyes audit prompt for each candidate, then a focused follow-up; audit ledger; Slither triage; NOTICE.md with file provenance | **Adopt** ADMIN, MIGRATION, RUNBOOK, DEPLOY, LAUNCH_CHECKLIST, NOTICE.md and the audit cadence. Keep the DECISIONS, STATUS and FOUNDER_REVIEW structure that CLAUDE.md requires |

## 5. Conflicts with the founder invariants (must not be adopted silently)

collection-games made these choices for the Ape game at its owner's direction (D54, D57, D79). This project's
CLAUDE.md invariants say otherwise:

1. **Invariant 10 (no unilateral drain) and 11 (independent upgrade authority plus a timelock).** In
   collection-games the single owner proposes the successor, and 72 hours later anyone executes the hand-over of all
   NFTs and vault ETH to that contract. The owner can therefore move everything to code it controls, with notice but
   with no independent check. SECURITY.md says so plainly. The independent migration signer (D55) was removed in D57.
2. **Instant powers that can reach value indirectly.** These are in collection-games as accepted risks:
   - markup 0-100% with no floor (zero markup lets anyone play at the protocol's expense)
   - keeper `maxGasPrice` and `gasOverhead` unbounded (whoever calls first can take the keeper allowance)
   - bid threshold up to 100% of what can be spent (overpays a colluding seller up to the acquisition budget)
   - `setLayer` pointing up to 5% of fees at any contract
   - the coin allowlist (lets chosen addresses host fee-free trading)

   These are exactly the "indirect extraction via legitimate owner powers" paths that `.claude/agents/security-reviewer.md`
   puts first.

Recommended resolution (decision D012, AWAITING OWNER DECISION):

- **Structure from collection-games:** permanent contracts, no proxies, `MigrationAuthority` with code pinning and
  permissionless batched execution, a separate fee-recipient notice, `Sunset`. This removes this repository's main
  residual risk, that a council majority can upgrade the Engine to anything (THREAT_MODEL), and replaces it with a
  public, code-pinned migration.
- **Authority from this repository:** the migration and fee-recipient proposer is the council through the
  `TimelockController` (7 days, guardian can cancel), not `Admin.owner`. The owner keeps the instant `Sunset`, which
  can only send value to buybacks (consistent with invariant 10), pause, and routine bounded settings.
- **Bounds restored as constants** on every instant power that can move value: a markup floor, keeper gas-price and
  flat-fee caps, a bid ceiling in relation to the schedule, no `setLayer` (or only behind the timelock), allowlist
  changes behind the timelock. collection-games already built and tested most of these before D57 removed them (the
  D54 table in its FINAL_REPORT §3f).

If the owner prefers collection-games' model, invariants 10 and 11 must be formally amended in CLAUDE.md first, and
the change must be disclosed in the same way as collection-games' SECURITY.md "Administration".

## 6. What carries over from this repository (Checks-specific, proven)

| Item | Source | Where it goes |
| --- | --- | --- |
| `IChecks`, Editions migration, `composite`, `infinity`, art fix 51 blocks later | `src/interfaces/IChecks.sol`, `test/fork/{Lifecycle,BlackCheck,Editions}.t.sol` | interfaces as they are; tests rebased on the collection-games `ForkBase` |
| Survival in O(1): `listed − withdrawn − activeListingCount`, entry offset per listing (C010, D002) | `FwaV2Controller.allocated/survived` | counters in the pool owner. Every list, withdraw and recover path updates them, including Shapes and Packs board traffic. Invariant: the counters match FWA |
| Tier schedule pricing, `ethPrice`, decay per survived draw, floor (D003, D005) | `Engine._notional`, `reprice`, `setSchedule` | pool owner listing rule, replacing the Ape gameplay-credit rule |
| `compose`, `composeCost`, grace window for the free fallback (D008), `formBlack`, relist with a fresh episode | `Engine.compose/formBlack/_relist` | a new permanent `ChecksComposer`, wired once. The pool owner exposes only `composite(keep, burn, swap)` and `infinity(ids)` on the immutable Checks address, callable only by the composer. No generic call |
| ETH and coin buyouts (D006, coin buyouts off at launch), `sellCheck`, `sellEdition`, per-tier bid with weekly cap (D007) | `Engine.buyWith*`, `sellCheck/sellEdition/_payBid` | buyouts in `ChecksComposer` (or a `ChecksDesk`, if size requires it); the bid in `FundingVault` |
| Code-hash pins of Checks, Editions, Shapes, FWA | `test/fork/Pins.t.sol` | kept and extended to Draw Packs and the community pool factory |
| Stateful invariants on the real pool (budget backing, custody vs records, survival bound, coin only burns) | `test/fork/Invariant.t.sol` | merged into the collection-games invariant handler |
| Council, timelock and guardian deployment | `test/fork/SystemBase.sol`, `script/DeploySystem.sol` | proposer for `MigrationAuthority` (if D012 is accepted) |
| Name gate (refuses BLACK, BLKCHK, "Black Check") | `DeploySystem.postflight` | collection-games postflight |
| Approved values: D001, D003, D005, D006, D007, D009 placeholders | DECISIONS.md | `LaunchConfig` |

Size budget: `CollectionGame` is 24,182 B (394 B headroom) and `CollectionPoolOwner` 22,125 B. Adding the survival
counters and the two Checks calls to the pool owner must fit. The Ape decay code being replaced (gameplay credit,
`decayClock`) frees some room. If it does not fit, move Draw Packs makeup (`_makeup`, `_denominations`) into a library
before anything else. A size spike is step 1 of phase R3.

## 7. Phased plan

Each phase ends with its tests passing, STATUS updated and a commit. Phases R1-R3 do not depend on D012-D014. R6
and R7 build the recommended option behind its decision and record it under REVIEW until decided.

**R0. Baseline and decisions (docs only).** Record this plan and D012-D014 in DECISIONS. Tag `rc2` as the archive of
the old architecture. Verify the FWA factory state on-chain read-only (`poolCreationEnabled`, community factory
code hash). Exit: decisions logged; FWA facts pinned with block numbers.

**R1. Import the base.** Copy collection-games at 409ca75 into a new branch of this repository (`src`, `script`,
`test`, `keeper`, `site`, `sim`, `external`, submodules shapes and shape-packs, `foundry.toml`), with NOTICE.md
recording the provenance of each file, as collection-games did with Draw Shapes. Run its suite unchanged on a
local anvil fork at its block 26,284,000. Exit: the imported suite passes here with the same counts, recorded with
exact commands. This proves the base before any change.

**R2. FWA pins and venue (V2, D014).** Add a fork profile after block 26,335,860, where V2 creation is open and
`betaAccess` is off, and pin the deployed code of the V2 factory and clone again there. Port 72d5179's community-pool
adapter as a second pool-owner path, used only for migration tests. Keep the deploy precheck
`poolCreationEnabled()`. Exit: a real V2 pool created and drawn on the new block with no switches opened locally,
and a test that the precheck refuses at a block inside 26,329,277-26,335,859.

**R3. Checks custody and survival.** Size spike. Pool owner listing rule becomes tier schedule × survival decay
(D005). Survival counters (C010) with their invariant. Purchase gate refuses Checks and Editions; exposure is
computed on schedule notionals. Checks become the collection NFT in `CollectionGame`, with captures booked as in
D15. Port Lifecycle, Editions and Pins. Exit: real Checks listed, drawn, won and decayed on the fork; survival equals
the old suite's expected values; Sizes and TxCap pass.

**R4. Composition and Black formation.** `ChecksComposer` with `compose`, `composeCost`, `formBlack` and the
grace-window fallback (D008); coin burn and composition happen atomically; withdrawals only with nothing unsettled;
staged withdrawal of 64 singles within the gas cap; relist with a fresh episode. Port BlackCheck and the
composition parts of Custody. Exit: a real 64-single `infinity` from custody on the fork; TxCap covers the heaviest
compose and formation steps; a failed attempt burns nothing.

**R5. Acquisition and buyouts.** `FundingVault` bid becomes per tier from the schedule with a weekly cap (D007);
`sellCheck` and `sellEdition`; buyouts with ETH and with coin (disabled at launch). The Seaport adapter is not
built (D015). Exit: the old Market tests ported; vault conservation invariant includes buyouts.

**R6. Coin, market, buy-and-burn.** `CollectionToken`, `CollectionHook`, `ProtocolLiquidity` and `CollectionBurner`
with this project's values: name gate, placeholder name, fee and curve per D013, milestone reserve released on a
Check won. Market opens only after the FWA pool exists (D91). Exit: the old Venue and Deploy coverage on the new
contracts; burner sandwich tests at the new bounds.

**R7. Governance, migration, Sunset.** `Admin` plus the approved D012 split: council timelock as
`MigrationAuthority` proposer for migrations and fee recipients; constant bounds on every instant power that can move
value (markup floor, keeper gas-price, overhead and flat-fee caps, bid ceiling against the schedule); coin allowlist
and `unrestrict` through the timelock; no $LAYER share. Sunset auctions Checks from their schedule price. Real migration V2 →
community pool with survival carried (replaces `NextGenControllerMock`). Owner-cannot-drain suite: every owner
function called by a hostile owner leaves the custody and value invariants intact. Exit: Governance, Migration and
Sunset suites; ADMIN.md powers table with the worst case of each; independent security review
(`security-reviewer` agent) of this phase.

**R8. Periphery and ops.** DrawRouter; Lens with Checks views (survival, eligibility, compose cost); keeper Checks
jobs; site on the collection-games base with compose, collect and trust pages ported; `LaunchConfig`, postflight,
`deploy.sh`, `rehearse-anvil.sh`, local dev chain; sims ported. Exit: rehearsal end to end with compose and
formation steps; keeper and site checks pass.

**R9. Delete and verify.** Remove `src/core/Engine.sol`, `src/fwa/`, `src/venue/`, `src/treasury/Burner.sol`,
`src/token/Coin.sol` and their tests (archived at the `rc2` tag). Full suite, strict invariants, Slither triage, gas
and size receipts, rehearsal. Refresh AUDIT_SCOPE, FOUNDER_REVIEW and a sealed fresh-eyes audit prompt in the
collection-games format. Exit: an `rc3` candidate; nothing deployed.

## 8. Decisions for the founder (decided 2026-11-03; see DECISIONS.md D012-D015)

| # | Question | Recommendation | Blocks |
| --- | --- | --- | --- |
| D012 | Trust model: collection-games' single owner, or its structure with council and timelock authority over migration and fee routing | Structure from collection-games, authority from here; restore constant bounds on value-reaching instant powers (section 5) | R7 production form |
| D013 | Coin market: keep D009/D010 (1% flat, no curve, unrestricted, daily release), or adopt collection-games' 5% fee, 69% opening curve, transfer restriction plus allowlist, and buybacks locked until a Check is won | Adopt the mechanics, choose values in the economics model. No $LAYER share. Restriction only with `unrestrict` reachable through the timelock | R6 values |
| D014 | FWA venue: V2 (FWA must reopen creation; about 11% margin) or community pools (no creation fee, about 8.7%) | V2 if FWA reopens it for this deploy; the community pool as the tested migration target either way | Deploy, not the build |

Outcomes: D012 (b), more locked down; D013 as recommended, values still to come from the model; D014 V2. D015,
as recommended: no Seaport adapter; the Sunset adopted; keeper pay on collection-games' structure with constant caps;
the daily decay built but off; D002 and D008 kept; D004 and D010 superseded.

## 9. Risks of the rebase

- **Size.** Both large collection-games contracts are close to EIP-170. Mitigated by the R3 spike and moving Checks
  logic into `ChecksComposer`.
- **Audit carry-over.** collection-games' audit rounds cover its contracts with Ape settings. Every changed line here
  is unaudited, and the R9 audit must cover the diff against 409ca75, not only new files.
- **Fork evidence and FWA's switch-off.** Until FWA reopens V2 creation, a deploy cannot be proven at the live
  block. Tests that open FWA's switches locally must be labelled as such.
- **Toolchain gas readings.** collection-games D70 saw gas figures change between forge 1.5.1 and 1.8.1. Record the
  forge version with every gas receipt.
- **Public RPC timeouts.** collection-games invariants failed on HTTP 408 from the public gateway. Run suites against
  a local anvil fork.
