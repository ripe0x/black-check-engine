# Decision log and founder review queue

Keep work moving without repeatedly interrupting the founder. Escalate only decisions with meaningful product, artistic, economic, security, or governance consequences.

## REVIEW: material choices for founder

### D001: A Black Check needs a quarter of all Checks that can ever exist
Status: REVIEW
Importance: High
Why it came up: Phase 0 fork reads (block 26,302,000). Checks has minted 12,474 Originals and 3,556 Editions remain
unmigrated, so at most 16,030 80-Check units can ever exist. A Black Check consumes 4,096 of them (25.6%). No Black
Check has ever been made. 85 tokens have reached the single-Check tier (docs/receipts/single-check-ids.txt).
Desired outcome: an eventual Black Check stays a credible, play-driven goal without promising it.
Options considered: (a) keep the goal and source high tiers: buy existing singles, 4s and 5s when priced well, so the
engine composes from rare inputs instead of from 80s; (b) keep the goal as stated and build from 80s, which needs
~4,096 Originals, many times the planned ~20; (c) re-frame Black Check as a long-term aspiration and make lower-tier
composites (a single Check: 64 units) the realistic headline.
Recommended choice: (a) plus honest framing from (c). Acquisition counts tiers by units, and the UI and docs state
that a Black Check needs 64 singles.
Tradeoff: high-tier Checks are scarce and illiquid, so acquisition prices are uncertain; composition from 80s alone
mostly produces 40s and 20s in any realistic budget.
Action taken: none yet. Phase 3 simulation will size the budget each route needs; E5 measures the 64-single
`infinity` call on real singles.
Reversibility: messaging and acquisition policy only; no code committed.
Owner action: Optional review.

### D002: Count a draw as survived when FWA allocated a prize, not when delivery completed
Status: REVIEW
Importance: Medium
Why it came up: Building the survival cursor against the real FWA clone (E3). The spec says DeliveryRefunded earns no
credit and DeliveryPending must be resolved first. FWA leaves a failed delivery pending until the winner calls
`refundFailedDelivery` after 7 days, and only the winner can; it may never happen.
Desired outcome: survival means a Check stayed in the pool through real, paid selections, and nobody can fake it.
Options considered: (a) count at processing when FWA allocated a prize (Fulfilled, DeliveryPending, DeliveryRefunded);
(b) the spec as written: block the cursor on DeliveryPending and skip DeliveryRefunded, so one stuck delivery can stop
counting for every Check indefinitely; (c) skip unresolved deliveries and never revisit them.
Recommended choice: (a). The selection is final at processing; delivery concerns only the winner. Delivery failure is
not reproducible with Checks or Shapes (plain `transferFrom`, well inside FWA's 150k stipend), so (a) and (b) differ
only in a path nobody can trigger cheaply, and (a) has no liveness hole.
Tradeoff: in the theoretical failed-delivery case, a refunded draw still counts as survived.
Action taken: first a per-sequence cursor, now derived from FWA's active count (C010), which counts exactly the
same draws: every allocation removes one active listing at processing. Fork-tested in `test/fork/Lifecycle.t.sol`
(E3, E4, E8) and `Custody.t.sol`.
Reversibility: the alternative needs a per-sequence cursor again (~29k gas per draw).
Owner action: Optional review.

### D003: Price listings from a timelocked tier schedule instead of signed market quotes
Status: REVIEW
Importance: High
Why it came up: Phase 2 custody design. There is no trustless onchain price for a Check. The spec's PricingGuard
(two signers attesting market quotes) adds a new trusted party and an offchain service, and a signer pair that
colludes with a player can still list a rare Check cheaply and win it.
Desired outcome: no owner, keeper or signer can make a valuable Check cheap to win; notionals still follow the market
over time.
Options considered: (a) a per-tier notional schedule that only the timelock (council + 7 days) can change, with
decay applied by rule from verified draws; (b) signer-attested quotes with expiry (spec); (c) acquisition cost as the
only anchor (fails for composites and appreciation).
Recommended choice: (a). Every Check at a tier lists at the same published notional; Shapes list at their exact
backing. Market moves reach the schedule through a public 7-day proposal, and the guardian can halt draws if the
market jumps faster than that.
Tradeoff: notionals lag the market by at least 7 days; a sharp Checks rally underprices prizes until the schedule
moves (subsidy risk, to be sized in Phase 3). Individual Checks with special art are priced as their tier.
Action taken: `Engine.tierNotional`, `setSchedule` (timelock only), `listChecks`/`listShapes` take no price;
`test/fork/Custody.t.sol` A6.
Reversibility: an engine upgrade could add a quote path later.
Owner action: Required before finalization.

### D004: List Shapes at backing + 10%, not exact backing
Status: REVIEW
Importance: Medium
Why it came up: Phase 3 model (`sim/model.py`). Replacing a won Shape costs its backing plus the 0.001 ETH Shapes
mint fee, 10% on a 0.01 ETH Shape, while the owner keeps only 2.5% over the harmonic mean per draw.
Desired outcome: Shapes are honest filler prizes whose replacement the game pays for itself.
Options considered: (a) notional = backing × (1 + markup), markup timelocked, default 10%; (b) exact backing (Phase 2
code), operating P&L −12 ETH over two years in the base case; (c) drop small Shapes and keep only ≥ 0.05 ETH ones,
fewer cheap prizes and faster Check turnover.
Recommended choice: (a). Base-case operating P&L +13 ETH. Players still win redeemable ETH; a Shape's expected value
to a player is 1/1.155 of its share of the fee instead of 1/1.05.
Tradeoff: Shape draws are slightly worse for players.
Action taken: `Engine.shapeMarkupBps` (timelock setter, max 50%), `listShapes` price = backing × (1 + markup);
`test/fork/Custody.t.sol` A6.
Reversibility: timelocked parameter.
Owner action: Optional review.

### D005: Keep the decay floor near the player break-even bound (85% of schedule)
Status: REVIEW
Importance: High
Why it came up: Phase 3 exact FWA math. When a Check's notional falls below its market value, draws gain expected
value; with 20 Checks among 57 listings, players break even with every Check at 87.5% of value. Deeper decay pays a
subsidy on each Check won and invites arbitrage draws.
Desired outcome: long survivors become more winnable (the spec's decay promise) without turning the pool into a
giveaway.
Options considered: (a) floor 85%, 0.2% per survived draw; (b) deep decay to 25% (subsidy 25 ETH over two years
and arbitrage draws); (c) no decay (subsidy ≈ 0, but survivors never gain odds).
Recommended choice: (a), reviewed with the schedule. Decay then mostly shifts odds among prizes.
Tradeoff: a long-surviving Check gains at most ~1/0.85 = 18% more weight, a modest effect.
Action taken: modelled ("Recommended" scenario, subsidy 4.4 ETH, P(single) 27%). Decay is not in the engine yet
(Phase 4).
Reversibility: timelocked parameters.
Owner action: Required before finalization.

Use this template:

### D001: Short question
Status: REVIEW | AWAITING OWNER DECISION | APPROVED | REJECTED | SUPERSEDED
Importance: High | Medium
Why it came up: Specific implementation constraint with reproducible evidence.
Desired outcome: Product experience or economic/security property to preserve.
Options considered: Two or three credible paths, including changing or removing unnecessary assumptions.
Recommended choice: One choice and rationale.
Tradeoff: What changes for players, holders or protocol.
Action taken: Reversible implementation or isolated experiment.
Reversibility: Cost to change later.
Owner action: Optional review | Required before finalization | Required before real execution.

Flag a decision without automatically halting unrelated work. Routine technical decisions belong in commit messages or brief closed notes.

## CLOSED: autonomous choices
Record important noncontroversial implementation choices with evidence and commit identifiers.

- C001 Toolchain: Foundry (forge 1.8.1), solc 0.8.28, evm cancun, optimizer 200. Dependencies pinned as submodules:
  forge-std 7fdf81f, solady v0.1.26, OpenZeppelin Contracts v5.1.0. Same compiler and libraries as the sibling
  ripe0x/collection-games project, so its fork-tested FWA code can be reused.
- C002 Fork environment: Ethereum mainnet block 26,302,000, RPC `MAINNET_RPC_URL` defaulting to the Tenderly public
  gateway (archive reads work; `eth_getProof` does not, so code hashes are computed locally).
- C003 Primary evidence: verified sources vendored read-only under `external/` (Checks Originals, Checks Editions
  proxy, Shapes and BLKCHK from Sourcify; FWA factory, clone and VRF service from collection-games, which fetched them
  from Blockscout with bytecode parity). Runtime code hashes are asserted in `test/fork/Pins.t.sol`.
- C004 Survival episodes are FWA listing IDs. An episode starts only when the queue is empty and the cursor is caught
  up (FWA then activates the listing immediately). Repricing keeps the listing ID and the episode; withdrawal, a win or
  relisting ends it. Evidence: E3, E4, E8.
- C005 Maintenance (composition, decay repricing) runs only with an empty FWA queue. When draws are in flight the
  controller first switches FWA purchases off (`setBool`, which leaves `inventoryVersion` and quotes alone); the queue
  drains within `selectionTimeoutBlocks` (30) plus permissionless processing. No custom pause layer. Evidence: E4.
- C006 Players buy directly from FWA (`acquire`/`acquireBatch`); no protocol draw router, so there is no router to
  bypass. A purchase operator is not needed for pausing. Revisit only if a gate on in-flight requests is required.
- C007 Newly migrated Originals are listed only after their epoch is revealed (51 blocks after mint). Evidence: E7.
- C010 Survival is derived, not iterated: the controller is its pool's only depositor and never stages listings, so
  every prize allocation removes exactly one of its active listings (FWA `_settleAndRemove`, verified source).
  Allocations = listed − withdrawn − `activeListingCount()`. Same semantics as the draw-by-draw cursor (D002), O(1),
  no keeper gas per draw. `SurvivalCursor` removed. Evidence: `test/fork/Lifecycle.t.sol` E3 asserts the active-count
  identity on the real pool; `Custody.t.sol` exercises it through the engine.
- C008 Governance from stock parts: OpenZeppelin `TimelockController` (council the only proposer, guardian an
  extra canceller, open execution, self-administered, 7-day delay) and an ERC1967/UUPS engine whose upgrades, role
  changes, schedule and controller changes are timelock-only. Operator powers: halt only. Guardian: halt, resume,
  cancel. Evidence: `test/fork/Custody.t.sol`.
- C009 One upgradeable `Engine` holds custody and lifecycle (vault and engine merged). Splitting them would not
  reduce trust, since an upgrade of either could move assets. Per-pool `FwaV2Controller`s stay immutable because FWA
  pool ownership is permanent and one pool per address. Evidence: `test/fork/Migration.t.sol`.

## FOUNDATIONAL COMMITMENTS
Follow the constraints in CLAUDE.md. If a real technical constraint conflicts with one, document it and recommend the simplest alternative while advancing independent work.
