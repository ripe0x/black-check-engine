# Black Check Coin — technical feasibility determinations
**Date:** 2026-10-29  
**Status:** Source-level feasibility review; **not** a completed mainnet-fork integration test or security audit.  
**Supersedes:** The three open technical implementation gates in functional spec v0.1.

## Executive decisions

| Gate | Feasibility | Implementation decision | What remains unverified |
|---|---|---|---|
| 1. Trustless survival counting | Feasible **with a simplified metric**, based on onchain FWA records | Use **successful draws survived**, not exact historical risk-weighted probability for launch | Confirm latest FWA clone ABI and execute live-implementation fork tests |
| 2. Withdraw, compose, relist | Contract paths exist; **conditionally feasible** | Use FWA controller as sole depositor, pause, drain in-flight draws, withdraw to vault, execute canonical Checks call from vault, relist through controller | End-to-end fork tests; gas bound for 64-single `infinity` |
| 3. Upgradeable protocol without sole-owner drain rights | **Feasible as distributed trust**; cryptographic trustlessness against *all* approved upgrades is not possible | Move from pinned-hash prototype to timelocked upgrades controlled by an **independent** security council; distinct routine operator privileges | Audited roles, no hidden owner-controlled upgrade path, adversarial integration tests |

## 1. Onchain survival counter

FWA's verified standard clone exposes (also documented for the current `0xeaa4...` implementation in the existing FWA integration dossier):
- `requestIdAtSequence(uint64)`, an ordered mapping of draw requests.
- `acquisitions(requestId)`, exposing the request block, selected listing and final status.
- `nextSequenceToProcess`, distinguishing processed from unresolved requests.
- `listings(listingId)`, including listing status, original depositor, NFT and token ID.

This enables permissionless accounting *without* trusting an offchain keeper's asserted count. An arbitrary caller can advance a bounded cursor over the pool's canonical sequence of requests, read each record, and credit only a `Fulfilled` request. `Expired`, `Refunded`, and `DeliveryRefunded` must not count. `DeliveryPending` must be retried or resolved before that sequence is credited. A blocked delivery could delay counting; the design must provide a path to recovery or disclose this liveness limitation. Duplicate cursor processing is forbidden. A controller-owned Check must have a recorded activation episode and cannot earn credit for requests issued before it became active.

**Critical simplification:** Count all *successful pool draws* while the Check was actively exposed in an uninterrupted listing episode. Do **not** implement the originally suggested sum of per-draw winning probabilities as an onchain eligibility condition in V1. FWA's selection weight changes as prizes leave the pool, so exact historical per-NFT exposure needs trustworthy snapshots for each draw. The older clone has no automatic callback into our controller. An indexer can reconstruct those snapshots for display, but its assertions are not a trustless onchain composition rule. Keep risk-weighted survival as a possible future upgrade if a verifiable snapshot path is designed.

**Activation safety:** Require no unresolved draws or staged inventory when starting a Check's new listing episode, or independently prove its active start sequence. Set `enteredAfterSequence = lastIssuedSequence` at admission and reset on every withdrawal, award or composition. Before granting credit, verify the listing is still the exact controlled active listing. Because the FWA clone can only change owner-inventory via the controller, an uninterrupted listing episode is enforceable. The same getters are listed for the current `0xeaa4...` FWA implementation in the existing Collection Games interface. They still require execution testing against that specific deployed implementation and must not be assumed to persist across future FWA versions.

**Important permission boundary:** FWA purchases are public and can bypass a Black Check app router. Its `purchaseOperator` hook runs inside the FWA purchase path and can be used as a fail-closed *global purchase safety gate* when quotes are stale or the system is paused. The hook receives the intended purchaser, not the newly assigned request ID, so it is **not** a receipt callback and cannot directly maintain survival counts. The protocol controller must configure this hook under its restricted governance rules, and must never let a routine operator disable it or replace it with an allow-all policy.

**Decay:** Use the same counted successful draws for discrete notional-repricing checkpoints; the controller can only reprice when FWA's queue is clear. A pre-agreed decaying price curve and separate emergency protection against a rapidly rising NFT market are required. If the owner can change the base quote or decay rate unilaterally, the game remains vulnerable to discounted prize extraction. Restart neither decay nor survival after migration unless the rules explicitly require it; carry the canonical counters in protocol state.

## 2. Checks composition mechanics and FWA workflow

Canonical Checks Originals source confirms:
- `mint(uint256[] tokenIds, address recipient)` burns approved Editions and mints Originals to an arbitrary recipient; the migration contract must have Edition approval.
- `composite(uint256 tokenId, uint256 burnId, bool swap)` demands caller ownership/approval of **both** inputs and the same tier; it burns the second token and advances the first. Supported ladder is `80 → 40 → 20 → 10 → 5 → 4 → 1`.
- `infinity(uint256[] tokenIds)` is a distinct **single call with exactly 64 single Checks**, which consumes 63 and leaves the first token as Black Check. It is not a two-NFT composition.
- `getCheck`, `simulateComposite`, and `simulateCompositeSVG` provide contract-native trait and preview data.

Implementation sequence:
1. Register eligibility and the correct onchain listing episode.
2. Pause new FWA purchases and wait for all unresolved randomness/selection/delivery commitments to resolve; use a permissionless settle/retry path where possible.
3. Withdraw selected Checks with `withdrawListingTo(listingId, vault)`; the controller must be the original FWA depositor and cannot substitute a different receiver.
4. The vault itself calls the canonical `Checks.composite` or `Checks.infinity` function as NFT owner. If a user pays BLACK to direct the action, collect/burn the tokens in the same atomic onchain operation that performs the composite.
5. Reset lineage-specific survival state, record the result, re-list via controller, and reopen purchases after inventory cooldown.

Transactions need not all be atomic across waiting for Chainlink randomness. The *composition plus BLACK burn* should be atomic once the queue is clear. Guard every step against a selected/won/withdrawn input. No minimum Checks count is necessary. High-tier notional decay gives eventual exit probability if draws continue, not a guaranteed finite-time exit.

**Unresolved gas question:** The canonical `infinity` operation loops through 64 tokens and burns 63 in one transaction. Without a fork gas measurement we cannot assert it fits within practical Ethereum mainnet transaction gas limits. This is a launch-critical execution risk for the eventual Black Check. Must fork-test, or explicitly design a canonical-contract-compatible fallback if one exists. Never assume the library `Compositor` solves it: it handles recursive pairwise merges, and `infinity` remains a separate operation.

## 3. Upgrade and custody trust model

The existing V2 PoC has a **fixed runtime-code hash and pinned FWA pool implementation**. It is helpful for identical-code migrations but **does not** support the newly chosen future-version upgradeability. Two-party price quotes alone also do not prevent an owner from exploiting a rapidly changing market after listing. This prototype is not ready for valuable assets.

Chosen direction:
- Upgradeable business logic with a dedicated timelock as the sole upgrade admin.
- Owner may propose improvements or pause ordinary operations, but cannot control timelock execution, threshold signers, role rotation, or upgrade authorization alone.
- Genuinely independent security council (proposed threshold 3-of-5), with disclosed membership, enforces approvals for new implementation code or FWA pool destinations, followed by a seven-day public delay.
- New approved FWA pool must be created and owned by a controller whose permitted methods do not expose arbitrary ETH/NFT calls. Old inventory must be recovered via the original depositor into the treasury before a new controller deposits it.
- Purchaser entitlements, refunds, and in-flight draws must remain claimable from the old FWA pool even after migration.
- Treasury outflows for NFT acquisitions, coin buybacks and direct purchases use bounded, purpose-built adapters; a generic `call` / `delegatecall`, arbitrary address approvals, unconstrained NFT quotes or owner-set token buyout price reintroduce drain risk.
- Test role changes as carefully as code upgrades: if owner can appoint council members, lower thresholds, choose timelock proposer/executor, or cancel guards unilaterally, 'independent approval' is meaningless.

**Precise guarantee:** Owner wallet alone cannot drain assets **if** the deployed access control correctly enforces independent approvals, including via migration. A majority of approved signers or an exploited implementation could still drain assets. A fully upgradeable asset-owning system cannot guarantee immunity against every malicious *approved* upgrade.

## Security tests required before deployment

- An owner cannot withdraw an NFT or treasury ETH through any existing method; a privileged keeper cannot simulate a cheap game win or quote.
- An owner cannot grant themselves upgrade permission through role admin functions, change a timelock's delay unilaterally, replace the council or maliciously set marketplace adapters.
- The same checks hold after a legitimate future-pool implementation upgrade and during overlapping old/new pools.
- Randomness pending, refund-pending, failed NFT delivery, slippage refunds and staging cannot create fabricated successful draws or composition eligibility.
- Randomized orderings of draw, market repricing, quote approval, compose, withdraw, buyout and migrate never let the owner redirect assets.
- Ethereum mainnet fork tests against the exact FWA factory and clone code, plus canonical Checks Originals, including a 64-single `infinity` gas measurement.
- An independent security audit and legal review of paid random draws prior to launch.

## Critical independent finding: existing Black Check protocol

Visualize Value's own repository contains a whitepaper for **Black Check ($BLKCHK)**, dated 2025-10-17, explicitly describing the deployed ERC-20 contract at `0x718477c471b335ee0ca29b9f4b95edd26d2ede54` whose holders can deposit Checks to mint BLKCHK, burn BLKCHK to extract Checks, and compose Checks toward Black. The proposed FWA game adds distinct mechanics but the working name, burn-to-extract concept, and artistic objective overlap substantially. **Choose a distinct name and positioning before publishing or launching**; do not describe Black Check Coin as the first tokenized protocol pursuing a Black Check.

## Source anchors

1. FWA factory and clone deployments: https://v1.fwa.fun/docs/v2-deployments and https://www.fwa.fun/docs/community-pools
2. FWA V2 clone source snapshot, earlier verified implementation: https://github.com/ripe0x/draw-public/blob/main/external/fwa-v2/FWAClone-0x2969749Fa2D9618fF08a63F41Be7bF7d018009d7/userowned/FWAClone.sol
3. Checks canonical source: https://github.com/visualizevalue/checks-contracts/blob/main/contracts/Checks.sol
4. Checks source README: https://github.com/visualizevalue/checks-contracts
5. Existing Black Check paper: https://github.com/visualizevalue/vvhitepapers/blob/main/projects/black-check.md
6. Current FWA getter ABI as previously documented in Collection Games: https://github.com/ripe0x/collection-games/blob/main/src/interfaces/IFWA.sol

## Test environment disclosure

The existing 21 Python security-model tests were rerun on 2026-10-29 and reported passing. These are abstract models, not Solidity/EVM tests. Foundry, Solidity compiler and an Ethereum RPC endpoint are unavailable in this environment. No mainnet-fork run was performed. No ETH was spent and nothing was deployed. The contract-level statements above are static source analysis with explicit assumptions, not an audit certification.