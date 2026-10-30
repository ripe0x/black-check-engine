# Keeper

A permissionless, **untrusted** keeper for a Black Check Engine deployment. It only does jobs the engine already lets
anyone do, each one simulated with `eth_call` first and skipped if the simulation reverts. Nothing here can move value
anywhere a stranger could not, and no job depends on being trusted. Keepers are not paid by this protocol (keeper pay
is not built, docs/ARCHITECTURE.md), so a keeper spends its own gas.

## Jobs

Independent and idempotent, tried in this order each tick (`src/policy.mjs` `jobs`):

1. `pool.processAcquisitions` — settle the FWA queue when its head request has its VRF word or is past its deadline.
   The other maintenance needs an empty queue, so this runs first.
2. `Engine.listChecks` / `listShapes` — revealed Checks / Shapes sitting in custody, unlisted.
3. `Engine.restockShapes` — Shapes FWA delivered to a winner, replaced at the same backing from game capital.
4. `Engine.reprice` — listed Checks whose rule price has moved by at least the step (or reached a boundary).
5. `Engine.compose(keep, burn, false)` — free, deterministic compositions only: both inputs eligible and `graceDraws`
   past their threshold, survivor = more survived draws then lower id. **Never pays coin.**
6. `Engine.formBlack` — 64 ready singles, ids ascending, so the free path applies.
7. `Engine.collect(controller)` — only when the controller holds proceeds (`collect` is a no-op otherwise).
8. `VenueHook.forward()` — send collected venue fees to the acquisition budget.
9. `Engine.releaseSurplus()` and `Burner.burn()` — when their daily / interval gates allow.

Token ids are discovered from the engine's own events (`Listed`, `Unlisted`, `Composed`, `BlackCheck`, `Bought`,
`Acquired`, `Restocked`); the current role of each id is then read from live state, so any event ordering is safe. FWA
batch sizes are bounded to 20 (`FWA_BATCH`, FWA's `MAX_INVENTORY_BATCH`).

## Run

```
cd keeper && npm install && npm test        # unit tests, no network
ENGINE=0x.. npm run once                     # DRY_RUN defaults true: logs the transactions it would send, sends nothing
ENGINE=0x.. HOOK=0x.. BURNER=0x.. DRY_RUN=false KEEPER_PRIVATE_KEY=0x.. RPC_URL=https://mainnet.gateway.tenderly.co npm start
```

## Config (env)

| Var | Default | Meaning |
| --- | --- | --- |
| `RPC_URL` | Tenderly public mainnet | JSON-RPC endpoint |
| `ENGINE` | (required) | Engine proxy address |
| `HOOK`, `BURNER` | unset | enable `forward()` / `burn()` |
| `DRY_RUN` | `true` | log intended sends, send nothing (no key needed) |
| `KEEPER_PRIVATE_KEY` | unset | only read when `DRY_RUN=false`; **never logged, written, or committed** |
| `KEEPER_ADDRESS` | unset | an unlocked local-node account instead of a key (anvil rehearsal) |
| `FROM_BLOCK` | `0` | first block to scan engine events from (set to the deploy block on mainnet) |
| `CHUNK_BLOCKS` | `5000` | log-scan window |
| `FWA_BATCH` | `20` | ids per FWA-bound call |
| `MAX_GAS_PRICE_GWEI` | `0` (off) | hold the tick while basefee is above this |
| `POLL_SECONDS` | `60` | loop interval; `--once` runs a single tick |
| `CHAIN_ID` | `1` | |

## Secrets

The signing key exists only for real sends and comes from `KEEPER_PRIVATE_KEY` at runtime. It is never logged, written
to disk, or committed. Do not create a filled-in `.env`; `.env.example` ships empty. Never run a real send against
mainnet with a key you are testing.

## Rehearsal

`npm test` covers the decision logic offline. The full loop is rehearsed against an anvil fork of mainnet: deploy the
system to the local node, move a revealed Check into the engine by impersonation, then run the keeper in dry-run and
once in send mode against `http://127.0.0.1:8546` using anvil's unlocked dev account (no private key on disk).
