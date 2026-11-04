# Architecture

One Ape-specific coin (Ape Draw, ADRAW) and its game (D56): the coin, its Uniswap v4 market and hook, protocol
liquidity and the buy-and-burn contract (which also holds the milestone reserve); the funding vault, FWA V2 pool owner,
game ledger and Draw Packs instance; and the end-of-life contracts: the MigrationAuthority, which can move the game (not
the coin) to a successor pool system or end it into the Sunset, and is the only way trading fees change destination
(D55, D63, docs/MIGRATION.md), and the Sunset, which turns everything it receives into buybacks. One owner, recorded in
the `Admin` contract, administers everything at once within broad bounds (D57, docs/ADMIN.md); no administrative call
withdraws custody assets.

## Contracts

### Permanent (custody, accounting, hard rules)

| Contract | Holds | Role | Size |
| --- | --- | --- | --- |
| `Admin` | — | Records the one owner: two-step `transferOwnership` / `acceptOwnership`, `renounceOwnership`. Every governed contract checks `admin.owner()`, so one transfer (or a renounce) moves (or ends) administration of all of them. | 1.3 KB |
| `CollectionToken` | — | Fixed-supply ERC-20 (1B, 18 dp), minted once to ProtocolLiquidity; holder burn; permit. No owner. | 2.5 KB |
| `CollectionHook` | — | v4 hook. 5%/5% ETH fee to the fee recipient (the vault at launch; only the MigrationAuthority can change it: after 72 hours' notice, or into the Sunset at once); fee bps by the owner, hard cap 10%; an immutable opening curve on buys and sells from the pool's initialisation, 69% falling one point a minute (linear per second) to the ordinary fee (minute 64 at 5%; 69% is also the absolute clamp); exact-output buys pay the same share of the gross ETH; one immutable exempt sender (the burner); block-open price for the burner. | 7.4 KB |
| `ProtocolLiquidity` | the v4 positions | Opens the market once (owner) with every coin single-sided; accepts no ETH. No removal function. | 5.5 KB |
| `FundingVault` | ETH (fees, contributions, the game's surplus share) | Fee intake; irrevocable ETH/NFT contributions; one balance; the live bid for holders' NFTs (Permanent Collection's metered model: `sweep`, a first threshold of 100% of the reference price, then 75% of each clearing price; then at most 0.05 ETH per 300 blocks; docs/SPEC.md "The bid"); the fee overflow (D65: at a sweep, while the live bid is at its fill target, half of the trading fees received since the last sweep go to the burner, never the game's capital, its growth, the bid's ETH or one more Ape at the last price); marketplace fills through the Seaport adapter fixed at wiring, with custody postconditions; capitalises the game (its capital and the board growth its Apes wait for come before the bid); reports its `shortfall` of one Ape, which caps the game's surplus share; once the game has retired, the hand-over of its whole balance to the successor or the Sunset (authority only). No withdraw. | 12.6 KB |
| `CollectionPoolOwner` | collection NFTs, Shapes and Draw Packs before listing | Creates and permanently owns the FWA pool; FWA purchase operator; mints each prize (a Shape, or a Draw Pack of the fewest Shapes adding up to its value) with the game's ETH and lists it in the same call; narrow owner actions; lists every collection NFT held (batches), shared gameplay credit and one decay rule (with an owner-set daily decay, off at launch: D78), the exposure target and the rows it needs (`rowsShort`), per-listing outcome records (`settleListing`); hand-over of NFTs to the successor or the Sunset once the game has retired (authority only). No generic execute, no sale of its own. | 22.1 KB |
| `CollectionGame` | game ETH (working capital) | The ledger: walks FWA's request sequence, books every pull once, prices and pays for replacement prizes (markup 0-100%), the board pattern (`setPattern`, applied to each row the next time it is listed) and its size (grows on demand for the Apes, or `setBoardSize`; no row limit), admission, activation, keeper pay (gas plus a flat fee, within an allowance earned from captures), distributions (a share to the vault while it is short of one Ape, the rest to the burner), the burner's milestone release for each Ape win and each big prize it books, retirement (MigrationAuthority only). | 23.6 KB |
| `CollectionBurner` | committed buyback ETH | Locks `milestoneBps` (100% at launch, D74) of the game's surplus in a reserve released in tiers to the milestone bucket on wins FWA shows delivered (`release`, anyone; no owner path): a big prize (a Shape or Pack listed at 0.5 ETH or more) 15% of it, an Ape exit 60%, a second Ape exit within 24 hours the rest; all of it once the game has retired; the rest, the vault's fee overflow and ETH from anyone else are ongoing. A cadence that follows play: an ongoing slice of 0.05 ETH + 0.005 ETH per FWA draw since the last + 1% of the bucket, spaced 60 minutes × 20 / (20 + draws), at least 10 minutes; milestone ETH first, 1 ETH every 10 minutes, the first at once; impact cap and same-block price check; hard bounds no owner can pass (slice ≤ 1 ETH, spacing 10 minutes-30 days, impact ≤ 5%, deviation ≤ 3%); burns everything it buys; reimburses each slice's keeper from that slice at the game's keeper formula (≤ 5%). | 11.7 KB |
| `MigrationAuthority` | nothing (never receives assets) | The only way the game ends or moves and the only caller of the hook's `setFeeRecipient`: a migration (owner proposal, 72 hours, successor's code hash pinned, then anyone executes; trading fees follow the successor), a new fee recipient on its own (same notice; only before any migration or the sunset has started), or the sunset (owner, instant and final: no later proposal of either kind). Once V1 has retired, permissionless batched transfers of the NFTs and the vault's ETH straight to the successor (D55, D57, D63). | 4.7 KB |
| `Sunset` | the Apes and ETH a sunset hands over | The built-in end of the game. No owner. A public Dutch auction of every Ape from 150% of its recorded cost down to 25% over 30 days; the auction price paid (any excess refunded to the buyer), the vault's capital and trading fees go to the burner (`buy`, `flush`, which also starts the clock if nobody has). Nothing can go to the owner or anyone else. | 2.5 KB |
| `DrawRouter` (periphery) | nothing between calls | The site's draw: settles draws waiting in FWA's queue, buys for the caller, then runs the game's `upkeep` (`sync` unpaid, D77) within a gas budget the site sets from a measurement (heavy work is left to keepers) and the vault's `sweep`, and returns all change to the caller (the game's `upkeep` pays nobody, D77; the sweep reward goes to the vault, D76). `redeemAndDraw` first takes and redeems the caller's won Shapes and Packs (with the caller's approval) and draws with that ETH (D75). No owner, no state, no privileges; replaceable without governance (D53, D59, D60). | 4.5 KB |

**Draw Packs** (`ShapePacks` 17.7 KB and `ShapePackRenderer` 9.3 KB, from ripe0x/shape-packs, `draw-packs` branch at
3a463f7, compiled through src/vendor/PacksBuild.sol; one instance per game, minimum two units). First-party code, in
the audit scope as such (D63). A Pack is an ERC-721 that holds Shapes (the fewest adding up to its value); its owner
alone can open it (Shapes out), redeem it (ETH out through Shapes) or unseal it. Its admin (the owner's address, set at
deployment and held by ShapePacks itself, not read from `Admin`) controls presentation only; it has no path to
contents. The pool owner mints Packs for itself and lists them like Shapes; a winner receives the Pack outright.
Security boundaries: docs/SECURITY.md "Draw Packs".

One owner administers every governed contract (`Governed` checks `admin.owner()`; no roles, no timelock, D57): bounded
parameters, the board pattern and size, pricing and keeper pay, the bid and the fee overflow, the milestone share and
tiers, the buyback cadence, pause/resume, opening the market once; and, through the MigrationAuthority, proposing a migration or a new trading-fee recipient (72 hours' public
notice, the code hash pinned, then anyone executes; a new fee recipient only before any migration has started) and the
sunset (instant and final: its only destination is buybacks, and no proposal of either kind can follow it). The
owner cannot redirect trading fees directly: the hook accepts a new recipient only from the MigrationAuthority. There
is no holder veto and no separate renounce; a renounce of `Admin` leaves every contract running on its last settings
and ends migration and the sunset with every other owner function.

### Settings, not modules (D59, D63)

There are no policy modules. The board pattern (`setPattern`), its size (`setBoardSize`, grow only), markup and keeper
allowance rate (`setPricing`), listing batch (`setBoardParams`), keeper pay (`setKeeperParams`) and the continuity share
(`setSettings`) are bounded settings in the game; the bid's parameters and the fee overflow live in the vault
(`setBidParams`, `setOverflowBps`; the metering and the overflow's condition and cap are vault code); the buyback cadence and
the milestone share and tiers live in the burner (`setCadence`, `setTiers`, `setMilestoneBps`; the hard bounds and
the release verification are burner code); the Ape listing rule and exposure target live in the pool owner (`setListingParams`; the rule is
pool-owner code: a published notional never rises); board growth on demand is game code driven by the pool owner's
`rowsShort`. The one executing component outside the permanent contracts is the vault's marketplace adapter:

| Adapter | Decides | Bounded by | Size |
| --- | --- | --- | --- |
| `SeaportAdapter` (optional; fixed at wiring) | fills one Seaport order | vault: ≤ the live bid less the finder fee, NFT in custody and ETH returned in the same call | 3.6 KB |

## Asset flows

```
traders ──swap──► Uniswap v4 pool ──5% fee (ETH; 69% at launch, 5% from minute 64)──► FundingVault ◄── ETH / NFT contributions (irrevocable)
                  (fee recipient at launch; changed only by the MigrationAuthority: 72 h notice, or the Sunset at once)
                                                        │
              ┌─────────────────────────────────────────┼──────────────────────────────┐
              ▼ sellToProtocol / fillOrder              ▼ fundGame (capital need only)   ▼ migrateCapital (once retired)
   holder ◄─ETH─┘  NFT ─► CollectionPoolOwner      CollectionGame                   successor, or Sunset
                          (custody) ─listNFT─► FWA pool ◄── players pay ticket + VRF fee
                                                  │  ├─ prize ──► winner (Shape, Draw Pack or collection NFT)
                                                  │  └─ owner proceeds ──► PoolOwner ──► CollectionGame
   FundingVault ── sweep: fee overflow, 50% of the fees since the last sweep while the bid is at its fill target; never
                   the game's capital, its growth, the bid or the next Ape at the last price ──► CollectionBurner (ongoing)
   Shapes / Draw Packs ◄──mint (backing + fees)── PoolOwner ◄── prize cost ── CollectionGame
   CollectionGame ── keeper pay (gas + a flat fee, within the allowance) ──► caller of sync / retireStep (a player's draw calls `upkeep`: unpaid, D77)
   CollectionGame ── distributable surplus ─┬─ 35%, at most the vault's shortfall of one Ape ──► FundingVault
                                            └─ rest ──► CollectionBurner ─┬─ 100% reserve (locked, D74) ── release on a delivered win:
                                                                          │     an Ape pull releases all of it (D74);
                                                                          │     a big prize nothing (all once retired)
                                                                          │     ──► milestone bucket
                                                                          └─ 25% ongoing (also the fee overflow and ETH from anyone else)
   CollectionBurner ── slices ──► buy & burn the coin (each slice's keeper reimbursed ≤ 5%):
                       milestone first, 1 ETH every 10 min (the first at once); ongoing 0.05 ETH + 0.005 ETH per draw + 1% of the bucket,
                       every 60 min × 20 / (20 + draws), at least 10 min
   retirement: CollectionGame ── all ETH ──► FundingVault
   migration:  PoolOwner ── NFTs ──► successor;  FundingVault ── all ETH ──► successor;  trading fees ──► successor
   sunset:     PoolOwner ── NFTs ──► Sunset ── Dutch auction ETH ──► CollectionBurner
               FundingVault ── all ETH ──► Sunset;  trading fees ──► Sunset;  Sunset ── flush ──► CollectionBurner
```

Every outflow has one authorised destination:

- **FundingVault**: a seller (only after the NFT is in custody), the adapter fixed at wiring (only inside `fillOrder`),
  the caller of `sweep` or `fillOrder` (reward or finder fee, each ≤ 0.01 ETH), the game (`capitalNeed` only), the
  burner (the fee overflow, only inside `sweep`, never out of the game's capital, its growth, the bid or the next Ape), the successor
  or the Sunset (only through the MigrationAuthority, after the game retired).
- **CollectionPoolOwner**: ETH to Shapes and Draw Packs (minting, exactly the game's payment for the prizes it lists);
  NFTs to FWA (listing), back to itself (withdrawal, recovered refund), to winners (FWA delivery), to the successor or
  the Sunset (MigrationAuthority only, after the game retired); ETH (proceeds, burned Shapes' and redeemed Packs'
  backing) only to the game.
- **CollectionGame**: the pool owner (prize cost, spent on mints in the same call), the caller of `sync` or
  `retireStep` (keeper pay: always within the allowance, and never out of cash owed to replacements; while retiring,
  when nothing is owed, from any cash but still within the allowance), the vault (surplus share, retirement return), the burner (surplus).
- **CollectionBurner**: the PoolManager (swap; coins are burned in the same call) and the keeper of each slice (≤ 5% of
  it).
- **Sunset**: the burner (all ETH but a buyer's refunded overpayment); Apes only to auction buyers.
- **MigrationAuthority**: nothing (it directs the pool owner's and the vault's hand-over and sets the hook's fee
  recipient).
- **ProtocolLiquidity**: nothing (no removal; it accepts no ETH; launch rounding dust of the coin is burned).
- **DrawRouter**: the caller (every wei left after the draw: FWA's change and what redeemed prizes paid beyond the
  draws' cost); the vault (the sweep reward from a player's upkeep, D76).

## Lifecycle

1. **Deploy** (`script/Deploy.s.sol`): all contracts (the Sunset and the Seaport adapter included), one-shot wiring,
   deployer powers revoked, postflight.
2. **FWA pool** (`script/FwaFee.s.sol`): the owner's FWA reaches the pool owner via `FwaFeeRelay`; anyone calls
   `createPool`. The pool owner becomes FWA's permanent owner and purchase operator; purchases are disabled.
3. **Market** (owner): `ProtocolLiquidity.launch()` at the tick fixed at deployment (173,000 (≈ 32.6M coins per ETH, ≈ 30.7 ETH FDV, about $69k at $2,242 ETH; D70)); the opening fee curve runs from 69% on buys and sells
   down to the 5% ordinary fee over 64 minutes.
4. **Funding mode** (no deadline): fees accrue; sweeps fill the live bid to 100% of the reference price at once (so the
   opening fees can buy the first NFT) and then meter ETH in (0.05 ETH per 300 blocks); a holder accepts it (or
   someone donates) for the first NFT; the vault then funds the whole board and reserve at once (1.666 ETH and 1 ETH);
   keepers (paid within the game's 1 ETH opening allowance, D79) mint and list the 50-prize board (Shapes and Draw Packs)
   and the NFT.
5. **Activation** (`CollectionGame.activate`, anyone, once): only when the on-chain readiness check passes; it first
   refills from the vault the reserve the opening keeper pay took.
6. **Operation**: `sync` books, replaces, lists every NFT held, reprices them as gameplay is credited, grows the board
   as they need it, admits and pays out (run by keepers, and by players' draws through the DrawRouter, which also sweep
   the bid); the vault keeps buying NFTs with what the game does not need; surplus tops the vault up to one Ape at the
   last price and otherwise goes to the burner, which buys and burns at a pace that follows play; while the bid is at
   its fill target and the vault holds the next Ape beyond it, half the trading fees go to the burner too. Until a migration or the sunset starts, the owner
   may point trading fees at another recipient (proposal + 72 hours, then anyone executes) while the game runs on.
7. **Migration** (owner proposal + 72 hours, successor's code pinned, then anyone executes; docs/MIGRATION.md): FWA
   pool retired, settlement continues, Shapes burned and Packs redeemed to ETH, all ETH back to the vault
   (`retireStep`); then the NFTs and the vault's capital go straight to the successor, and trading fees follow it from
   execution (a pending fee-recipient proposal is cancelled; only a later successor proposal moves them); the coin, its market and the burner carry on.
8. **Or sunset** (owner, instant, final): the same unwinding, into the Sunset: each Ape is auctioned (150% down to 25%
   of its cost over 30 days), and the price paid, the vault's capital and the trading fees go to the burner; the burner's
   reserve is released (`releaseRetired`) and bought back like the rest.

## Why these boundaries

- FWA's pool owner can never change and only the owner can list, so the custodian had to be permanent and narrow. The
  game ledger is a separate permanent contract (Draw Shapes' FwaGame was 23.5 KB; both parts are below the 24,576-byte
  limit: CollectionGame 24,182 B, 394 B under; CollectionPoolOwner 21,151 B).
- The exposure target and the never-rising notional are enforced by the contract that owns the NFTs.
- Settings instead of modules (D63): the board, pricing and keeper pay are bounded values inside the ledger, so no
  outside contract sits between the ledger and its assets. The marketplace adapter is the one executing component; it
  is fixed at wiring, and the vault checks custody and spending around it.
- The bid's metering is vault code: whatever its parameters, it is ETH actually forwarded, never above what the vault
  may spend after the game's own capital, and it never rises with time alone.
- One `Admin` contract instead of an owner per contract, so one two-step transfer or one renounce covers the whole
  system and no governed contract can be left behind.
- The milestone release has no owner path: its triggers (a delivered big prize or collection win, read from FWA, each
  listing once) are burner code; the owner sets only the share locked (`milestoneBps`) and the tiers (`setTiers`),
  which change when the reserve is bought back, not whether. The buyback cadence is the owner's within constants no
  owner can pass (slice ≤ 1 ETH, spacing ≥ 10 minutes, impact ≤ 5%, deviation ≤ 3%).
- Trading fees change destination only through the MigrationAuthority, with 72 hours' public notice and the
  recipient's code pinned, so fees cannot be redirected without warning, and once a migration has started they follow
  the successor. The sunset is the one instant path, because its successor has no owner and can only send ETH to the
  burner; it is final (no proposal of either kind afterwards), and keeper pay during retirement stays within the
  allowance left, so nothing but buybacks can reach what it is handed.
- The game ledger is permanent (not replaceable): replacing it would let a new contract redirect proceeds and Shape
  backing (docs/IMPLEMENTOR_DECISIONS.md D16).
- Nothing loops over every NFT or row in a routine call (D59): Ape outcomes are recorded per listing, listing and
  repricing work in batches from a cursor, the owed rows are a list; a pattern change applies lazily and recosts only
  the rows already owed.
