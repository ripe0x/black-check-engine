# Architecture

Current as of the rebase (docs/REBASE_PLAN.md, phases R1-R7). Built on ripe0x/collection-games 409ca75; the
pre-rebase implementation (UUPS `Engine`) is archived at tag `rc2`. Not audited, not deployed.

```
 council Safe ──propose──► TimelockController (7 days; guardian cancels; anyone executes) ── Admin.council
 owner (operator) ─────────────────────────────────────────────────────────────────────── Admin.owner
     │ bounded settings, pause, instant sunset (buybacks only)        │ schedule, listing rule, buyout prices,
     │                                                                │ coin allowlist/unrestrict, $LAYER share,
     ▼                                                                ▼ migration and fee-recipient proposals
 players ──ETH──► DrawRouter ──► FWA V2 pool ◄──owns── CollectionPoolOwner ◄── ChecksDesk (compose, Black, buyouts)
                                    │ prizes          (Checks, Shapes, Packs;     ▲
                                    ▼                  survival, decay, gate)      │ coin burns, ETH buyouts
                              CollectionGame (ledger: booking, board, keeper pay, surplus split)
                                    │ surplus                     ▲ capital
                                    ▼                             │
 traders ──► CollectionHook (5%, opening curve) ──fees──► FundingVault (live bid: 80-Checks, Editions, Seaport)
                                                                  │
                     CollectionBurner (milestone reserve released on a Check won; bounded slices) ◄── surplus
 MigrationAuthority (council proposal + 72 h, code pinned) ──► successor │ Sunset (Dutch auction → buy-and-burn)
```

## Contracts

| Contract | Origin | Role in the Checks game |
| --- | --- | --- |
| `Admin`, `Governed` | collection-games, council added (D012) | The owner (operator, two-step, renounceable) and the council timelock (only the council replaces itself) |
| `TimelockController` | OpenZeppelin v5.5.0 (Shapes' vendored copy) | The council: council Safe proposes, 7 days, guardian cancels, anyone executes, self-administered |
| `CollectionPoolOwner` | collection-games, changed for Checks (C016) | Permanent FWA V2 pool owner and custody of Checks, Shapes and Packs. Tier read from Checks; council price schedule per tier (D003); survival = listed - withdrawn - active (C010, D002); decay per survived draw to a floor (D005); exposure target; live purchase gate; desk-only compose, Black formation and release |
| `ChecksDesk` | rc2 `Engine` (new contract) | Composition (coin burn for a choice, free deterministic outcome after the grace, D008), Black Check formation from 64 singles, ETH buyouts (schedule + markup, at least 10%) and coin buyouts (council prices, off at launch, D006). Holds nothing |
| `CollectionGame` | collection-games, bounds added | The ledger: books every draw once, the Shapes and Packs board and its growth, keeper pay (capped, D012), markup at least 5%, surplus split |
| `FundingVault` | collection-games, changed | Trading fees and contributions; the live bid buys 80-Check Originals only, Editions migrate through `sellEdition`, Seaport fills; nothing booked above 120% of the 80 price (D012) |
| `CollectionToken`, `CollectionHook`, `ProtocolLiquidity` | collection-games | Fixed-supply coin restricted to its pool (allowlist and unrestriction: council), `burnFrom` for the desk; 5% fee after the fixed 69% opening curve; single-sided launch at tick 173,000 (D016); owner or council opens it, only after the FWA pool exists |
| `CollectionBurner` | collection-games | Buy-and-burn; every gameplay buyback held until a Check is won, then released whole (D016) |
| `MigrationAuthority`, `Sunset` | collection-games, proposer changed | Council-proposed migration or fee recipient, then 72 hours, code pinned, anyone executes; the owner's instant sunset auctions every Check and sends every wei to buy-and-burn |
| `DrawRouter`, `Lens`, `SeaportAdapter`, `FwaFeeRoutes`, `LayerTap` | collection-games | Player draws with upkeep; views; hardened marketplace fills; FWA creation fee; the dormant $LAYER tap |
| Draw Packs | ripe0x/shape-packs 3a463f7 | Pack prizes of the fewest Shapes |

## Lifecycle of a Check

1. **Arrives**: sold to the vault's live bid (80-Check Originals only), an Edition sold and migrated (`sellEdition`),
   a Seaport fill, or a donation. Registered with its tier.
2. **Listed** at its tier's schedule price, in batches, within the exposure target; a tier without a price waits.
3. **Survives draws**: each draw that allocates any prize while it stays listed counts one, from FWA's own counts.
4. **Decays** 0.2% of its schedule price per survived draw, to 85% (D005); a council schedule change reprices up or
   down keeping earned decay. Optional daily decay, off at launch.
5. **Composes** (desk): two eligible Checks of a tier at most 5, after `drawsToCompose`; a free choice burns coin, the
   deterministic outcome is free after the grace (the keeper runs it). The survivor returns for a new episode.
   64 eligible singles form a Black Check (8.35M gas measured).
6. **Leaves**: won (FWA delivers it; the burner releases the milestone reserve), bought with ETH or coin through the
   desk, burned in composition, or handed to a successor or the Sunset after retirement.

## Authority (D012)

The owner cannot move custody, redirect fees, change what Checks are worth, or approve new code. Those powers are the
council timelock's, and a migration additionally waits the MigrationAuthority's 72 hours with the successor's code
pinned. Owner settings that can reach value are bounded by constants. The disclosed residual trust: a council
majority, after 7 days that the guardian can cancel, and 72 more hours in public, can migrate to code of its choosing.
