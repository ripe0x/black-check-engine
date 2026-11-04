# Founder review (grouped): the rebased system

Branch `claude/wizardly-shannon-440owk`, tracking PR ripe0x/black-check-engine#1. Nothing deployed, broadcast, spent or
published. The pre-rebase review is in git history (tag `rc2`).

## Decisions

| # | Decision | Outcome |
| --- | --- | --- |
| D012 | Authority over migration, fee routing and value | Council timelock (Safe proposes, 7 days, guardian cancels); the owner keeps pause, bounded settings and the instant sunset into buybacks. Approved |
| D013 / D016 | Coin market | Collection-games' mechanics with modelled values: tick 173,000 (about 30.7 ETH), 5% each way after the fixed 69% curve, buybacks held until a Check is won, no $LAYER share. Approved by delegation |
| D014 | FWA venue | V2 (creation reopened at block 26,335,860); community pools as the tested migration target. Approved |
| D015 | Remaining choices | Seaport adapter kept; Sunset adopted; keeper pay with caps; daily decay off. Approved |
| D017 | Independent review | C-1 and M-1 fixed; L-1 (the caller picks which eligible Checks to pair for a free composition) is **open for your optional review** |

## Values required before any mainnet deployment

Immutable: coin name and ticker (the deployment refuses the placeholders), opening tick (173,000), the opening curve.
Council keys: the council Safe, its signers and threshold, the guardian. Council-settable later: the price schedule
(placeholder 80-Check 0.25 ETH x units), listing rule, buyout prices. Owner-settable: composition pace and coin
burns (placeholders until the coin trades), bid and keeper parameters within their bounds.

## Gates outside the code

1. Name and ticker (invariant 9). 2. Council membership, threshold and guardian (independence is offchain). 3. Legal
review of paid chance draws and the coin's mechanics. 4. Independent human audit of docs/AUDIT_SCOPE.md (every changed
line is unaudited; collection-games' rounds cover only its base). 5. FWA keeping V2 creation open on the day
(`poolCreationEnabled` is checked by the deploy).

## Proven (real mainnet contracts on a fork at block 26,337,000)

- The collection-games base, imported unchanged, passed 269/281 at its own block (the 12 others only failed writing
  receipts after passing every assertion).
- The Checks system passes its whole suite under the deployment build (via-IR, sizes under EIP-170); see STATUS.
- Survival counted from FWA's own numbers matches the game's ledger draw for draw; decay to the floor; schedule changes
  both ways.
- Composition of real Checks with a coin burn or for free after the grace; a Black Check from 64 real singles in one
  transaction at 8.35M gas; ETH and coin buyouts; an Edition sold and migrated into custody.
- The council timelock: schedule, 7-day wait, guardian cancel, execute; every value power refuses the owner.
- Migration from FWA V2 to a real community pool with the Check, its capital and its survival carried (community
  factory switches opened locally only).

## Assumptions (not proven)

- Economics: activation needs about 2.6 ETH of fees (7-22 ETH of first-hour volume by when traders come); an 80-Check
  floor of about 0.25 ETH; player demand and coin volume are assumptions (sim/results/checks_market.md).
- FWA's factory owner does not turn V2 against the game (edge, cooldown, switches); the purchase gate closes safely if
  the edge rises.
- The council is independent of the owner and acts within its 7 days.

## Open risks

- The schedule lags the market by at least 7 days: a rally underprices Checks until the council moves it; a crash
  overprices them (the vault never pays above 120% of it).
- About 30 ETH of opening depth: thin early market; buybacks move the price visibly.
- `CollectionPoolOwner` has under 1 KB of size headroom under via-IR.
- No production successor for the community factory yet (needed only if a migration is proposed).

## Untested or partly tested

- The site's wallet writes (compose, buy, approve) have not been driven against a deployment; the site typechecks and
  builds.
- The keeper's composition job is unit-tested; its live run is part of the rehearsal.
- Real Chainlink VRF timing (words are delivered by impersonation in tests).
- No independent human audit.

## Actions only you can authorize

Any mainnet deployment or broadcast, buying FWA or Checks, launching the coin market, choosing council keys and the
guardian, publishing the site, merging the PR.
