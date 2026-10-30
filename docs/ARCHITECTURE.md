# Architecture

Current as of Phase 4. Contracts are not audited and not deployed.

```
                    council (Safe, proposer) ──► TimelockController (7 days, self-admin) ◄── guardian (cancel)
                                                          │ upgrades, controller, schedule, params, roles
                                                          ▼
 players ──ETH──► FWA V2 pool ◄──owns── FwaV2Controller ◄──engine-only── Engine (UUPS proxy) ◄── keepers / anyone
     ▲  prizes        (FWAClone)          (immutable)                     │ custody: Checks, Shapes, ETH
     └────────────────────────────────────────────────────────────────────┤ operator: halt only
                                                                          ├─► Checks (canonical composite/infinity/mint)
 collectors ──ETH / coin──► buyWithEth / buyWithCoin                      ├─► Shapes (restock mint)
 sellers ──Check / Edition──► sellCheck / sellEdition (standing bid)      └─► Coin.burnFrom (composition, coin buyout)
```

## Contracts

| Contract | File | Role |
| --- | --- | --- |
| `Engine` | src/core/Engine.sol | Custody and lifecycle. Lists, decays, composes, sells, buys, restocks, migrates. UUPS; only the timelock upgrades or reconfigures it |
| `FwaV2Controller` | src/fwa/FwaV2Controller.sol | Permanent owner of one FWA V2 pool; engine-only; derives survival in O(1) (C010) |
| `Coin` | src/token/Coin.sol | Fixed-supply ERC20 placeholder with `burnFrom` |
| `TimelockController` | OpenZeppelin v5.1.0 | Council proposals, 7-day delay, guardian cancel, open execution |
| `VenueLiquidity`, `VenueHook` | src/venue/ | Coin market on Uniswap v4: whole supply locked single-sided; flat ETH fee to acquisitions (D009) |
| `Burner` | src/treasury/Burner.sol | Ownerless buy-and-burn of released game surplus (D010) |
| `FwaFeeBuyer` | src/periphery/FwaFeeBuyer.sol | Buys FWA's pool-creation fee with ETH into the controller |
| Deployment | script/DeploySystem.sol | The single deployment routine and postflight used by tests and scripts |

## Lifecycle of a Check

1. **Enters custody**: bought at the standing bid (`sellCheck`, or `sellEdition`, which migrates an Edition to an
   80-Check Original), or sent in. A Check that was won and comes back starts with no history.
2. **Listed** (`listChecks`, anyone): only revealed Originals at tiers with a schedule price; FWA notional =
   schedule × decay share. The controller lists only into an empty FWA queue, so the listing is live at once.
3. **Survives draws**: every draw that allocates any prize while the Check stays listed counts one survived draw
   (D002, C010).
4. **Decays** (`reprice`, anyone, empty queue): notional falls by `decayBpsPerDraw` of the schedule per survived
   draw, linearly, to `floorBps` (D005); changes under `repriceStepBps` wait. A schedule change through the timelock
   moves prices up or down; earned decay is kept.
5. **Composes** (`compose`, `formBlack`, anyone, empty queue): both inputs past their tier threshold. A free choice
   of survivor or visual burns `composeBurn[tier]` coin; after `graceDraws` more draws the deterministic outcome is
   free (D008). The survivor is relisted at its new tier with a fresh history.
6. **Leaves**: won by a player (FWA delivers it), bought for ETH at schedule × (1 + markup), bought by burning the
   tier's coin price (disabled at launch, D006), or burned inside canonical composition.

## Money

| Flow | Source | Destination | Bound |
| --- | --- | --- | --- |
| Draw fees | players | FWA; owner share → controller → engine (`collect`) | FWA formula |
| ETH buyouts | collectors | `acquisitionBudget` | published price |
| Coin fees | `VenueHook` (flat ETH fee each way) | `acquisitionBudget` via `forward` → `fundAcquisitions` | immutable rate |
| Standing bid | `acquisitionBudget` | sellers | schedule × `bidBps`, `bidWeeklyCap` per week |
| Shape restock | game capital (balance − budget) | Shapes contract | only for won Shapes, at recorded backing |
| Surplus | game capital above budget + `gameReserve` | `Burner` (buys coin on the venue, burns it) | daily release; `maxPerBurn` per interval |

Not built yet: keeper pay. The FWA creation fee is bought with ETH through `src/periphery/FwaFeeBuyer.sol`.

## Upgrade and migration

- Engine upgrades: council proposes, 7 days, anyone executes; the guardian can cancel. A council majority can
  upgrade to anything (disclosed residual trust, docs/THREAT_MODEL.md).
- New FWA version or new pool: deploy a new controller, `setController` through the timelock. The old pool stops
  taking draws; pending draws settle there; anyone migrates inventory with survival carried; old proceeds remain
  collectable.

## Constraints from the real dependencies

- FWA: pool ownership is permanent and one pool per address; listing changes need an empty queue; repricing and
  withdrawal lock while any draw is unsettled; the factory owner controls edge, cooldown and global switches.
- Checks: `composite` needs the caller to own both tokens; `infinity` takes exactly 64 singles (742k gas);
  Editions migrate through `mint`, which needs the Checks contract approved on Editions; art fixes 51 blocks later.
- Shapes: mint fee 0.001 ETH per Shape on top of backing.
