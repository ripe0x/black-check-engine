# Threat model and authority

Scope: custody of Checks, Shapes and ETH; upgrades; FWA pool migration. Testing is not an audit.

## Assets

1. Checks held by the engine, listed in an FWA pool, or in FWA delivery escrow.
2. Shapes (and later Packs) with ETH backing.
3. ETH: FWA owner proceeds, Shapes redemptions, coin fees (later), sale proceeds (later).
4. Player entitlements inside FWA: pending draws, refund credits, delivery escrow. These belong to players and are held
   by FWA, never by us.
5. Survival history (draws survived per Check), which gates composition.

## Contracts

| Contract | Mutable | Holds | Who can change it |
| --- | --- | --- | --- |
| `Engine` (UUPS proxy) | Upgradeable | NFTs in custody, ETH | Timelock only (council + 7 days) |
| `FwaV2Controller` (one per FWA pool) | Immutable | Momentarily, NFTs in transit; FWA pool ownership | Nobody. A new pool needs a new controller |
| OZ `TimelockController` | Self-administered | Nothing | Itself (council proposal + delay) |
| Council (Safe multisig, 3 of 5 tentative) | Its own signers | Nothing | Its own threshold |

## Roles and their powers

| Role | Can | Cannot |
| --- | --- | --- |
| Council | Propose any timelock operation; cancel | Execute before the delay |
| Timelock (after delay) | Upgrade `Engine`; approve a new controller; set operator and guardian; set bounded parameters | Act early; act without a council proposal |
| Guardian | Cancel scheduled operations; halt and resume new purchases (a halt stops new draws only; settlement and maintenance continue) | Upgrade, move assets, change parameters |
| Operator (project owner) | Halt new purchases | Resume a guardian halt, upgrade, move assets, set prices, change roles, propose onchain |
| Anyone (keepers) | Advance the survival cursor; list custody NFTs at rule prices; compose eligible pairs; collect proceeds into the engine; migrate listings out of a retired pool; settle FWA queues | Choose recipients, prices or amounts; credit survival |

## Attack paths and the control that stops each

| # | Attack | Control | Test |
| --- | --- | --- | --- |
| A1 | Owner calls an asset-moving function | None exists for the owner; every NFT exit is to FWA via the controller, back to the engine, into canonical Checks composition, or (later) a priced sale | `Custody.t.sol` |
| A2 | Owner upgrades the engine to a drain | `_authorizeUpgrade` is timelock-only; the owner holds no timelock role | `Custody.t.sol` |
| A3 | Owner grants itself a timelock role or shortens the delay | The timelock is its own admin; role grants and `updateDelay` need a proposal + delay | `Custody.t.sol` |
| A4 | Owner points the engine at a malicious "new FWA pool" controller | `setController` is timelock-only | `Custody.t.sol`, `Migration.t.sol` |
| A5 | Anyone calls the controller directly to withdraw or reprice | Every controller action is engine-only; FWA withdrawals go to the engine address fixed at construction | `Custody.t.sol` |
| A6 | Cheap notional on a rare Check, then win it | Notionals come from a timelocked tier schedule (D003); no caller supplies a price | `Custody.t.sol` |
| A7 | Fake survival credit (keeper claims, duplicate reports, pending/refunded draws, staged inventory, relisting) | Survival is derived from FWA state (listed − withdrawn − `activeListingCount`, C010); listings enter only an empty queue, so none stage; relisting starts at zero; nobody reports counts | `Lifecycle.t.sol`, `Custody.t.sol` |
| A8 | A sale, composition or migration cancels or redirects a pending draw | Withdrawal requires FWA's empty queue; FWA keeps every purchaser's refund and delivery rights | `Lifecycle.t.sol`, `Migration.t.sol` |
| A9 | Approvals left for later abuse | The engine never approves; it transfers to the controller right before listing. The controller approves only its own FWA pool | `Custody.t.sol` |
| A10 | Unexpected NFTs or ETH create a sweep path | No sweep exists; strays are quarantined in place | review |
| A11 | Malicious council (majority) or a malicious approved upgrade | Not preventable by code. Mitigated by independent signers, the public 7-day delay, guardian cancel and bounded exposure; disclosed | `Custody.t.sol` (demonstrates the residual power) |
| A12 | FWA factory owner changes edge, cooldown, global switches, or new-pool implementation | Outside our control. The controller pins the expected implementation at pool creation; live settings are read before maintenance; global withdraw-only still lets us exit | Phase 4 |

## Residual trust, stated plainly

1. A council majority, after 7 public days and without a guardian cancel, can upgrade the engine to anything,
   including a drain. A timelock and multisig distribute and delay that power; they do not remove it.
2. Approving a new controller hands it every NFT the engine lists there. The council's review of that controller's
   code (no generic call, recipients fixed to the engine, pinned pool implementation) is the migration's security
   boundary.
3. Council independence is an offchain fact (who holds the keys). The contracts cannot verify it.
4. FWA's code and its factory owner are trusted for listed inventory and player funds.
5. Canonical Checks is trusted for composition and artwork.
