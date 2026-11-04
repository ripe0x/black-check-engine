# Keeper

Runs only the jobs the protocol itself must do (D53, D63). While the game runs: `CollectionGame.sync` (booking, owner
proceeds, replacements, Ape listing and repricing, board growth, refunded-prize recovery, distributions, vault funding,
admission; paid by the game: its gas at the transaction's price up to 3 gwei plus a flat fee (0.0002 ETH at launch), within the keeper
allowance captures earn), `activate` once the on-chain readiness check passes, `CollectionBurner.release` for any
delivered Ape win or big prize the burner has not released yet (normally the game does it while booking; the bot scans
the pool owner's `CollectionWon` and the game's `Captured` events; unpaid fallback), `CollectionBurner.process` (`buyback`, once `nextSlice()`'s
`runAt` has passed with ETH to spend: the burner's cadence follows play, and a milestone release makes the next slice
due at once; reimbursed from the slice at the game's keeper formula, at most 5% of it) and `FundingVault.sweep` when the
live bid can take more ETH, below its threshold at once, above it once per cooldown (rewarded by the vault: its gas plus the flat fee
at the game's keeper formula, at most 0.01 ETH, D82; the same sweep first sends the fee overflow, half the fees received since the
last sweep while Apes wait, to the burner; `SWEEP=0` turns it off). While the game is retiring: FWA `processAcquisitions` and `retireStep` (paid like `sync`, within
the allowance). Once it has retired (a migration, or the sunset): `retireStep` (late settlements),
`MigrationAuthority.migrateApes` and `migrateCapital`, `Sunset.flush` (`flushSunset`: sends the Sunset's ETH to the
burner and starts the auction clock if nobody has), `CollectionBurner.releaseRetired` while the burner holds a
milestone reserve, and `buyback`. Job order: `keeper/src/policy.mjs`.

It does not settle players' draws: FWA's randomness callback does, and the site's DrawRouter settles any backlog before
each draw (anyone may call FWA `processAcquisitions`). Players' draws through the DrawRouter also run `sync` and `sweep`
and receive the payments, so keepers are a backstop. Every write is simulated first and skipped if it would revert
(`NoWork`, `TooSoon`, `NotReady`, `PriceMoved`, `NotQualifying`, ...).

Modes: `MODE=primary` acts whenever there is work and the basefee is at most `MAX_GAS_PRICE_GWEI` (3: the game
reimburses gas up to its `maxGasPrice`, 3 gwei at launch, and at the cap above it); `MODE=backup` (default) acts only
after the work has waited `BACKUP_AFTER_SECONDS` (6 h), measured from when this keeper first saw it (for `buyback`,
from `runAt`), or below
`BACKUP_BASEFEE_GATE_GWEI` (1 gwei). Neither mode acts above `GAS_PRICE_LIMIT_GWEI` (10), however old the work, and it
caps every transaction's `maxFeePerGas`: above the game's `maxGasPrice` each call costs the keeper more than it is paid.
Run one primary and at least one backup on separate infrastructure
(docs/RUNBOOK.md "Keepers").

Priority fee: `PRIORITY_FEE_GWEI` (0.02). The game reimburses the gas at the transaction's gas price, priority included,
up to `maxGasPrice`. The game fixes how many requests `sync` and `retireStep` book (`bookPerCall`), so the bot passes no
count. It skips a paid `sync` once the keeper allowance is spent (`keeperAvailable` 0: the call would pay nothing),
and skips light work (under `PLAYER_UPKEEP_GAS`) within `payDelay` of a player's upkeep, which the game does but does
not pay (D82); `UNPAID=1` sends both anyway. `retireStep` is always sent. Other
settings: `POLL_SECONDS`, `UNPAID` (0; 1 also sends `sync` once the allowance is spent),
`LOG_LOOKBACK_BLOCKS` and `LOG_CHUNK_BLOCKS` (the scan for unreleased wins), `DEPLOYMENT` (deployments/<env>.json),
`CHAIN_ID`.

```
cd keeper && npm install && npm run check
RPC_URL=... KEEPER_PRIVATE_KEY=... DEPLOYMENT=../deployments/mainnet.json MODE=primary POLL_SECONDS=12 npm start
```

Gas limit: the bot sends every job with 30% above its gas estimate. Do the same in any other keeper. The payment is
made at the end of the call, outside any `try`, and if one of `sync`'s isolated steps fails with less than 1/8 of the
gas it started with left, the whole call reverts (`OutOfGas`): a tight gas limit cannot skip work and still be paid; it
only fails.

Never commit a key; pass it as a runtime secret. The keeper wallet needs a little ETH for gas; the game's payments
repay it.
