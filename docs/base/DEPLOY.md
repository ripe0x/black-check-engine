# Mainnet deployment

Nothing in this repository has been broadcast to any live network. These are the exact steps for the owner. Commands
assume Foundry and Node 22, an archive RPC (`RPC_URL`), and signing through a hardware wallet or keystore
(`FORGE_WALLET_ARGS="--ledger --sender 0x…"`), never a key in a file.

## Owner-supplied prerequisites vs protocol-funded capital

| Item | Amount | Supplied by |
| --- | --- | --- |
| Owner address (`OWNER`): the one administrator of every contract through `Admin` (D57); proposes migrations and fee recipients (72-hour notice), can trigger the sunset | — | owner (a hardware wallet or a multisig; transferable later in two steps, or renounced) |
| Deployment gas (≈ 54.4M gas: the round 8 dry run's estimate at block 26,330,569 for every contract incl. the LayerTap, the Draw Packs instance and renderer and the Sunset; the older 36M in docs/receipts/gas.json `deploy_system_all_contracts` predates the current set; use the dry run's estimate on the day) | ≈ 0.054 ETH at 1 gwei · 0.27 at 5 · 1.09 at 20 | deploying wallet |
| FWA pool creation fee | **50,000 FWA delivered** = ~51,015 of the owner's FWA through the relay (2.02%, measured), or ≈ 0.164 ETH through the buy route (fork block price) | owner's FWA wallet |
| Pool creation gas | ~10M gas: 0.010 ETH at 1 gwei · 0.05 at 5 | owner's FWA wallet |
| Market launch | 0 ETH (single-sided; `launch` accepts no ETH, D38); ~0.35M gas | owner |
| First collection NFT (the bid fills to 100% of `REF_PRICE_WEI` at once), the 50-row board of Shapes and Draw Packs (1.59 ETH backing + 76 Shapes mint fees = 1.666 ETH), operating reserve (0.5 ETH, D79), opening keeper pay (within the 0.2 ETH allowance, D82; listing the board costs about 0.05-0.14 ETH: keepers are paid from the game's cash, which the vault refills, at the latest at activation) | NFT + 2.166 ETH, plus the listing pay (≈ 2.27 ETH besides the Ape) | **protocol: trading fees** (the opening curve's first hour; or optional contributions) |
| Board growth, the next Apes, buybacks | — | protocol |

## Deploy-time decisions (see IMPLEMENTOR_DECISIONS "Needs owner review")

`OWNER` (the administrator); coin name/symbol; `REF_PRICE_WEI`, the reference price: **the live BAYC floor on the
day** (6 ETH placeholder; the live bid's first activation threshold is 100% of it, `firstThresholdBps`, so the opening
fees can buy the first Ape at once; after each purchase it is 75% of the funding reference; and until the first purchase sets a
new reference it is the price the vault must be able to pay before the game stops sending it a share of surplus,
`shortfall()`); `MAX_PRICE_WEI`, an optional emergency cap on any acquisition (0 = none, the default; if set, the deploy script refuses one below
`REF_PRICE_WEI`); both changeable later (`FundingVault.setBidParams`, D57). Opening tick (opening
fully diluted value; fixed in `LaunchConfig`: 173,000 (≈ 32.6M coins per ETH, ≈ 30.7 ETH FDV, about $69k at $2,242 ETH; D70); each +6,931 ticks halves the price).
Nothing is funded at deployment: keeper pay comes from the game, within the 0.2 ETH opening allowance (a limit, not a
deposit: what keepers actually earn listing the board, about 0.05-0.14 ETH, is funded with it; D82).

## Launch values (`script/LaunchConfig.sol`, D64, D65; all owner-adjustable after deployment unless marked fixed)

| Group | Values |
| --- | --- |
| Trading fees | `buyFeeBps` / `sellFeeBps` 500 / 500 (≤ 10%, `setFees`). Opening curve, **fixed** in the hook: 69% on buys and sells at the pool's initialisation, 1 point less a minute (linear per second), down to the ordinary fee at about minute 64 |
| Board | the 50-row pattern, interleaved: 24 × 0.01 Shape, 16 × 0.02 Pack, 3 × 0.03 Pack, 1 × 0.04 Pack, 3 × 0.05 Shape, 1 × 0.1 Shape, 1 × 0.15 Pack, 1 × 0.5 Shape (1.59 ETH backing, 76 Shapes, 1.666 ETH at cost); `initialBoardSize` 50; `listBatch` 3, `maxPerCall` 8, `bookPerCall` 20 |
| Pricing and keepers | markup 10%, `opsBps` 1% (D82); keeper pay gas up to 3 gwei + 70,000 overhead + 0.0002 ETH flat fee (D79), and within `payDelay` of a player's upkeep a paid `sync` of light work does the work unpaid (D82; a no-work call reverts `NoWork`); opening allowance 0.2 ETH (D82) |
| Settings | reserve 0.5 ETH (the largest prize, D79); `minLiveBps` 70%; continuity share 35%; `maxOutstanding` 10; `maxEdgeBps` 5%; `maxCooldown` 30 days (D82), `maintenanceInterval` 5 minutes; `minDistribution` 0.01 ETH |
| In-flight bound | `maxInFlight` (K) 10 (D82), FWA's own per-pool limit: with FWA's 5-draw batches at most 14 requests unsettled; lower it (`setMaxInFlight`) if refunds matter more than throughput (worst case re-measured: 2 of 10 refunded, `test_launchInFlightBoundWorstCaseDrift`) |
| Ape listings | open `max(100% of cost, the floor)`, floor `minNotionalWei` 1 ETH (D82; a cheaper Ape opens at 1 ETH), decay 0.1 ETH per ETH of gameplay, no time decay (`dailyDecayBps` 0, D78), reprice step 5%, exposure target 20% |
| Live bid | first threshold 100% of `REF_PRICE_WEI` (`firstThresholdBps` 10,000, a vault constructor argument); then 75% of the funding reference; 1 ETH per 300 blocks (D82); ceiling 120% of the funding reference, 0.01 ETH per sweep above it (D82); `maxDropBps` 2,500 (25%, D83: one acquisition lowers the funding reference by at most this); `maxPrice` 0 |
| Fee overflow (`overflowBps`) | 5,000: 50% of fees to the burner while the live bid is at its fill target, capped at what the vault holds beyond the game's capital, the board growth, the bid and one more Ape at the funding reference (D65) |
| Burner | milestone share 100% (D74); tiers: an Ape exit releases the whole reserve, a big prize nothing (D74); cadence: 0.05 ETH + 0.005 ETH per draw + 1% of the bucket, at most 1 ETH, every 60 minutes × 20 / (20 + draws), at least 10; impact 3%, deviation 2%. Hard bounds in the contract: slice ≤ 1 ETH, spacing ≥ 10 minutes, impact ≤ 5%, deviation ≤ 3% |

## Order

1. **Prepare** `script/env/mainnet.env` (values only: `OWNER`, `COIN_NAME`, `COIN_SYMBOL`, `REF_PRICE_WEI`,
   `MAX_PRICE_WEI`). Verify every external address against `script/LaunchConfig.sol` and live state:
   - BAYC `0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D`; Shapes `0x6fe9193276bf7abcbee44ab7afd717d637d6faf0`;
   - FWA factory `0xF5A3A153164791AB579C3d9ba5DBECf7cDfd300c`, implementation `0xEaa4d032908A9734a2c7939c0D211c35ad51eb31`;
     `poolCreationEnabled()` must be true (FWA switched it off at block 26,329,277 on 2026-11-02 and will switch it
     back on for this deploy, D89)
     (`cast call <factory> "implementation()(address)"` must match), FWA token `0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845`;
   - v4 PoolManager `0x000000000004444c5dc75cB358380D2e3dE08A90`; CREATE2 proxy `0x4e59b44847b379578588920cA78FbF26c0B4956C`;
   - `cast call <factory> "poolCreationFee()(uint256)"` = 50,000e18; `inventoryChangeCooldown`, `edgeBps` within range.
2. **Dry run**: `script/deploy.sh mainnet` (simulation only; runs the full postflight). Expect "deployed; postflight
   passed" and its estimated gas.
3. **Broadcast** (owner, deliberately): `I_AM_THE_OWNER=yes FORGE_WALLET_ARGS="--ledger --sender 0x…" script/deploy.sh
   mainnet --broadcast`. `script/Deploy.s.sol` runs `script/DeploySystem.sol` with `script/LaunchConfig.sol`, which
   deploys, in order: `Admin` (owner = `OWNER`); the MigrationAuthority; ProtocolLiquidity and the coin (address
   predicted, all supply to ProtocolLiquidity); CollectionBurner (buyback cadence, milestone tiers, 100% milestone
   share); FundingVault (the live bid from `REF_PRICE_WEI` / `MAX_PRICE_WEI`, first threshold 100% of the reference,
   fee overflow share); the LayerTap (fixed to artcoins' $LAYER burn router, D90); the hook (salt mined for its permission bits,
   created through the CREATE2 proxy); the Draw Packs renderer and ShapePacks instance (admin = owner, minimum two units;
   compiled via-IR as in its own repository); CollectionPoolOwner; CollectionGame (board pattern, pricing, settings,
   keeper pay and the 0.2 ETH opening allowance; it lays out the 50-row opening board); the Sunset (the built-in end
   of the game: no owner, everything to the burner); the SeaportAdapter (the vault's one marketplace adapter); Lens;
   DrawRouter (stateless player entry point, D53); then one-shot wiring (liquidity → hook; burner → hook, game, pool
   owner; vault → game, pool owner, adapter; pool owner → game; MigrationAuthority → game, pool owner, vault, hook,
   Sunset) and `Admin.protect` (the collection, Shapes and Draw Packs can never be swept, D62). Every governed contract
   reads its owner from `Admin`. It runs the postflight (below) and writes `deployments/mainnet.json`: `chainId`,
   `block`, `owner`, `deployer`, `collection`, `admin`, `migration`, `liquidity`, `token`, `burner`, `vault`, `hook`,
   `poolOwner`, `game`, `sunset`, `adapter`, `lens`, `drawRouter`, `packs`, `packRenderer`, `layerTap`.
4. **Verify source**: `forge verify-contract <addr> <path>:<Name> --chain mainnet --constructor-args $(cast abi-encode …)`
   for each contract (optimizer 200 runs, solc 0.8.28, cancun, `bytecode_hash none`, no metadata); `ShapePacks` and
   `ShapePackRenderer` with `--via-ir --num-of-optimizations 20` (the `packs` compiler profile in foundry.toml).
5. **Re-run postflight** any time: `DEPLOYER=0x… DEPLOY_ENV=mainnet forge script script/Postflight.s.sol:Postflight
   --sig "check()" --rpc-url $RPC_URL` (read only; with the same environment as the deployment).
6. **FWA pool** (owner, from the wallet holding FWA): FWA blocks wallet-to-contract transfers, so the relay converts
   the owner's FWA inside one Uniswap v4 unlock:
   ```
   POOL_OWNER=<deployments.poolOwner> ROUTE=relay FWA_IN_WEI=51100000000000000000000 \
     forge script script/FwaFee.s.sol:FwaFee --rpc-url $RPC_URL --broadcast $FORGE_WALLET_ARGS
   ```
   It deploys a stateless relay, approves it for `FWA_IN_WEI`, relays (reverts unless ≥ 50,000 FWA arrive) and calls
   `createPool`. Quote `FWA_IN_WEI` again on the day: simulate without `--broadcast`; increase if it reverts with
   `InsufficientOutput`. Alternative: `ROUTE=buy ETH_IN_WEI=<≈ 0.17e18>`. Check: `pool()` set, `pool.owner()` = pool
   owner, `pool.purchaseOperator()` = pool owner, FWA purchases disabled, pool owner FWA balance 0.
7. **Keepers**: start one primary and one backup keeper (keeper/README.md) with `DEPLOYMENT=../deployments/mainnet.json`.
   Once the game is live, players' draws through the DrawRouter also run the upkeep (unpaid, D76, D77); keepers are the
   backstop.
8. **Open the market** (owner transaction, last; it reverts `NoFwaPool` until step 6 has created the FWA pool, D91):
   `ProtocolLiquidity.launch()` (no argument, no ETH value) opens at the tick fixed at
   deployment, 173,000 (≈ 32.6M coins per ETH, ≈ 30.7 ETH FDV, about $69k at $2,242 ETH; D70). Before it, if
   the BAYC floor has moved far since deployment, correct the first threshold: `FundingVault.setActivationThreshold`
   (100% of the floor; docs/RUNBOOK.md "Owner procedures"). The opening curve starts at this block's timestamp: buys and
   sells pay 69%, one point less a minute, down to 5% at minute 64 (`CollectionHook.openingFee()`). The owner accepted
   that a sell fee this high may get the coin labelled a honeypot by wallet scanners for a while (docs/RUNBOOK.md
   "Launch hour").
9. **Funding mode**: nothing to do. Fees accrue; sweeps (keepers, sellers, players' draws; rewarded) fill the live bid to
   the threshold, the full reference price, at once; a holder accepts it (`FundingVault.sellToProtocol(id, price)`) or
   someone donates; the threshold is then 75% of the funding reference, and above it sweeps meter 1 ETH per 300 blocks (D82). The
   vault funds the board and reserve once it holds them; keepers mint and list its 50 prizes (7 `sync`
   calls of about 6.5M gas, paid from the opening allowance: sim/results/keepers.md) and the NFT;
   any keeper activates when `ready()` (activation first draws from the vault the reserve the opening keeper pay took). Optional: ETH
   contributions (`FundingVault.contribute`) shorten funding; they are irrevocable and confer nothing.
10. **Site**: build locally with `NEXT_PUBLIC_DEPLOYMENT=mainnet` (publishing is a separate owner decision). Set
   `NEXT_PUBLIC_IPFS_GATEWAY` to a dedicated IPFS gateway (ending in `/ipfs/`): the site reads each Ape's art from its
   `tokenURI`, and public gateways such as ipfs.io rate-limit hard enough that images fail to load.

## Postflight (automatic in steps 3 and 5)

`DeploySystem.postflight` reads back: administration (`Admin.owner()` = `OWNER` with no pending transfer; every
governed contract reads that `Admin`; `deployer() == 0` everywhere, no deployer power left); **the MigrationAuthority**
(72-hour `DELAY`, no migration or fee recipient pending, not started, its sunset successor = the deployed Sunset, wired
to the game, pool owner, vault and hook, each of which names it as migrator); the Sunset's routes (burner, collection,
pool owner, game); supply, allocation (all in liquidity or launched, none with the deployer), 18 decimals; hook fees
(5% / 5%), 10% cap, the opening curve's constants (`LAUNCH_FEE_BPS` 6,900, `LAUNCH_DECAY_BPS_PER_MINUTE` 100), not
launched before the liquidity, single exempt sender (the burner), **fee recipient = vault** at deployment (on a later
re-run, any contract: only the MigrationAuthority can change it); liquidity and burner references, the configured
milestone share (75%), the cadence's largest slice and shortest spacing, and the tiers' first-exit share and big-prize
threshold; the vault's collection, pool manager, burner, game, pool owner and Seaport adapter; the live bid's parameters
as configured (75% threshold, 1 ETH per 300 blocks (D82), 120% ceiling, cap, `maxDropBps` 2,500 (D83); `referencePrice` and
`lastPrice` both at the reference, and the first threshold at
100% of it, until the first purchase replaces them); the fee overflow share (`overflowBps()`, "fee overflow"); configured
collection, Shapes, FWA factory and pinned implementation; the Ape listing parameters (opening, minimum, decay, step, 20%
target) and the in-flight bound (10, D82); the game's references, pattern, pricing, board parameters and keeper pay; the pool
owner's Draw Packs instance (its Shapes, its `MIN_PACK_VALUE` = 2 units, its admin = the owner); the board size; the
protected collections. After step 6 it also confirms the FWA pool's owner and purchase operator. "No unintended minting
or withdrawal paths" is structural (no such functions); the fork tests in `test/fork/Governance.t.sol` and the invariants
demonstrate it.

## Rehearsal

`FORK_URL=<archive rpc> script/rehearse-anvil.sh` runs the deployment and steps 6-9 on a local anvil fork with
real BAYC, FWA, Shapes, Uniswap and VRF contracts and the keeper bot, funded by trading alone (keeper/src/local-trading.mjs:
traders through Uniswap's Universal Router over the opening curve and after it; no vault contribution anywhere): the live bid swept and an
Ape sold to it, the keeper filling the board (paid from the opening allowance) and activating, draws through FWA and the
DrawRouter (which runs the upkeep unpaid, D76, D77), a new board pattern set by the owner (applied to each row as it
is next listed), two more Apes, buybacks, the postflight, keeper pay on real transactions, the trading-fee recipient
changed on its own (owner proposal, 72 hours, execution by anyone; the game plays on), and a complete migration to a
successor (owner proposal, 72 hours, execution by anyone, which points the fees at the successor, settlement,
hand-over) (`rehearsal.log`, docs/receipts/rehearsal.log). The sunset is tested on the fork (`test/fork/Sunset.t.sol`).
Result recorded in docs/FINAL_REPORT.md.

**Local dev chain.** Every local deploy gives the test wallets in `PLAYERS` (space-separated; default ripe0x.eth,
`0xCB43…17F9`) 1000 ETH on the fork. `script/local.sh` forks mainnet on anvil's default port (8545) with anvil's chain id (31337), runs
the rehearsal's deployment through activation (steps 1-5) and leaves anvil running with the local randomness service
(`keeper/src/local-vrf.mjs`, log `local-vrf.log`): nobody runs Chainlink VRF on a fork, so it delivers a random word for
every pending draw as the coordinator (impersonated), with the gas FWA's VRF service needs to hand the word to the pool
(its callback limit plus 1/63 and a reserve; with less it stores the word and defers). It runs on chain 31337 only.
Serve the site against it with `NEXT_PUBLIC_DEPLOYMENT=anvil npm --prefix site run dev`; the site signs only on that
chain and refuses an anvil record with any other chain id. The rehearsal's own defaults (mainnet's chain id, port
8546, the whole lifecycle, fixed words) are unchanged.

## Migration and sunset (later, if ever)

docs/MIGRATION.md and docs/RUNBOOK.md "Migration" and "Sunset". Nothing to deploy for either now: a migration's
successor is a separate, separately reviewed system; the Sunset is deployed with the system.
