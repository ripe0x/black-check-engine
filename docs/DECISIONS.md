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

## FOUNDATIONAL COMMITMENTS
Follow the constraints in CLAUDE.md. If a real technical constraint conflicts with one, document it and recommend the simplest alternative while advancing independent work.
