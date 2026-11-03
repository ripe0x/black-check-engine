# Economics

Every model number here is a result under stated assumptions, not a forecast. Sources (all re-run on the D64 code and
launch values unless a section says otherwise): `python3 sim/pool.py` → `sim/results/pool.md` (**the primary model**:
1-100 Apes on the 50-row board, three-year daily runs with the live bid, the opening curve, the fee overflow and D63
keeper pay); `python3 sim/launch.py` → `sim/results/launch.md` (the opening curve, exact constant-product
math); `python3 sim/sessions.py` → `sim/results/sessions.md` (100,000 seeded sessions per row);
`python3 sim/keepers.py` → `sim/results/keepers.md` and `python3 sim/maintenance.py` → `sim/results/maintenance.md`
(D63 keeper pay on the 50-row board); `python3 sim/burner.py` → `sim/results/burner.md` (the buyback cadence);
`test/scenario/Throughput.t.sol` → `docs/receipts/throughput/` and `python3 sim/throughput_table.py` →
`sim/results/throughput.md` (fork); `python3 sim/economics.py` → `sim/results/economics.md|json` (**a secondary model**:
the older D57 single-lead-Ape mechanics with the D64 reference values and, since D65, the launch keeper rule; 96 seeded runs per scenario, 48 per sensitivity
row, 1,000 ETH of gameplay each, gas held constant through a run); `test/fork/Gas.t.sol`, `test/fork/GasPrizes.t.sol`
(`--isolate`) → `docs/receipts/gas.json`, `docs/receipts/gas-prizes.json`; `test/scenario/ManyApes.t.sol` →
`docs/receipts/many-apes-*.json`. Not re-run for D64: `sim/bid.py`, `sim/ceiling.py`, `sim/acquisition.py` (their
mechanisms are unchanged except the first threshold; sections 2a and 10b say what does not apply).
Fork block 26,284,000. No daily pull count is assumed: gameplay is cumulative settled ETH, trading volume a multiple of
it or a daily flow.

**The one constraint to read first (section 8):** with the 10% markup and the keeper allowance (`opsBps`, 1% since D82, 5% when these figures were measured) on the
50-row board, the game pays for its own maintenance only while the average gas price stays at or below **about
0.58 gwei when every draw runs its own upkeep** (one replacement per call, the DrawRouter's pattern) and **about
0.9-1.1 gwei when keepers batch three to ten draws per call** (0.99 gwei at three, 0.91 at five, 1.09 at ten;
sim/results/keepers.md). D82 cut `opsBps` to 1% and `openingAllowance` to 0.2 ETH, so the allowance refills more slowly and these break-even gas prices are now lower, pending a re-run.
Above that keepers are paid only as far as the keeper allowance reaches (gas reimbursed at most at 3 gwei,
`maxGasPrice`), then players' draws through the DrawRouter carry the rest of the upkeep; if nobody runs it, won prizes
are not replaced and the purchase gate closes the game until gas falls. Mainnet gas in 2026 has mostly been
0.1-0.5 gwei, inside both limits.

**D64 (the flywheel build).** Launch values: 5% / 5% fees, the 50-row board (1.666 ETH at cost), 10% markup, a 20%
exposure target, K 4 (K 10 since D82), 70% minimum live rows, a 1 ETH reserve (0.5 since D79), 35% continuity. The opening fee curve (69% on buys and
sells, one point less a minute, 5% from minute 64) replaces the block schedule, and the first bid threshold is 100% of
the reference price, so the opening hour's fees can buy the first Ape at once. The burner locks 75% of the game's
buyback ETH (100% since D74) and releases it in tiers on verified wins; ongoing buybacks follow play. The vault sends half the trading
fees to buybacks while the bid is full (fee overflow; since D65 only ETH beyond the bid and one more Ape, the ETH the
rate-limited bid cannot use; the D64 play meter was removed in D65). D63's mechanisms stand: the game pays keepers gas plus a flat fee (D79; 10% before) within an allowance, splits its own surplus between
the vault and the burner, and the burner holds the milestone reserve.

## 1. Launch parameters

| Parameter | Launch |
| --- | --- |
| Board (D64) | 50 prizes, interleaved: 24 × 0.01 Shape, 16 × 0.02 Pack, 3 × 0.03 Pack, 1 × 0.04 Pack, 3 × 0.05 Shape, 1 × 0.1 Shape, 1 × 0.15 Pack, 1 × 0.5 Shape (D45 halved, without the 1 ETH Shape and the 0.06 Pack); 1.59 ETH backing, 76 Shapes, **1.666 ETH at cost**; `initialBoardSize` 50; the collection NFT listed separately |
| Pack makeup | the fewest Shapes adding up to each Pack's backing (0.02 = 2 × 0.01, 0.15 = 0.1 + 0.05); the smallest Pack is 0.02 |
| Markup / operating allocation | 10% over cost / 1% of each captured prize's cost (D82; frozen at listing), which since D63 is the keeper allowance a capture earns (`opsBps`); the owner may set each 0-100% (D57) |
| Operating reserve | 0.5 ETH (the contract requires at least the largest prize, 0.5 ETH; D79) |
| Minimum live rows | 70%: purchases close while more than 15 of the 50 rows wait for replacement (`minLiveBps`) |
| Ape listings (D59, D64 target) | every Ape held is listed; opens at `max(100% of its price, the floor)`, falls 0.1 ETH per ETH of gameplay credited to it (gameplay shared evenly among the Apes in the draw), never below `minNotionalWei` (an absolute floor, 1 ETH at launch, D82; a cheaper Ape opens at 1 ETH), repriced in 5% steps; the board grows on demand to keep the Apes' share of a draw's value ≤ **20%** (the target), with the purchase gate's headroom of 14 listings (D82); the gate's own ceiling is 50% |
| In-flight limit (K) | **10** requests (D82; was 3 in D65), FWA's own per-pool limit: with FWA's five-draw batches up to 10 − 1 + 5 = 14 can be unsettled (section 6); lower it (`setMaxInFlight`) if refunds matter more than throughput |
| Surplus split (D63) | of each distribution, **35%** to the vault while it is short of one NFT at the funding reference (never more than that shortfall), the rest to the CollectionBurner, which locks **100%** of what the game sends it in its milestone reserve (D74; 75% in the analysis below); once the vault can buy an Ape, everything goes to the burner. No other destination |
| The bid (D59, D64) | Permanent Collection's live bid: real ETH metered into one offer; below the activation threshold available ETH enters at once; the **first threshold is 100%** of the reference price (`firstThresholdBps`; 6 ETH at the 6 ETH placeholder `REF_PRICE_WEI`), after each purchase 75% of the funding reference; above it 1 ETH per 300 blocks (D82; ~24 ETH a day); above 120% of the funding reference only 0.01 ETH per 300 blocks (D82; ~0.24 ETH a day; the relative ceiling, D60, D61); a holder names its price up to the bid, a marketplace fill pays the listing's price plus a finder fee (0.5%, ≤ 0.01 ETH); the funding reference follows the price paid but falls by at most `maxDropBps` (25% at launch, D83) per acquisition and never below the Ape floor, so one cheap sale cannot collapse the bid; sweepers are rewarded their gas plus the flat fee at the keeper formula, capped at 0.01 ETH (D82); no absolute cap (`maxPrice` 0); no inventory limit |
| Fee overflow (D64, trigger D65, D72) | `overflowBps` 0 at launch (owner-adjustable; the analysis below uses 5,000): while the bid is at its fill target, that share (50% at 5,000) of the trading fees received since the last sweep go to the burner, never more than the vault holds beyond the game's needs, the board growth, the bid and one more Ape at the funding reference (section 10b) |
| Trading fee | 5% / 5% (owner, ≤ 10%, `setFees`). **Opening curve** (fixed in the hook): from the pool's initialisation, buys and sells pay max(5%, 69% − 1 point a minute), linear per second; the ordinary fee applies from minute 64 (section 10) |
| Buyback cadence (D64) | `Cadence {baseSliceWei 0.05, perDrawWei 0.005, backlogBps 100, maxSliceWei 1 ETH, idleSpacing 60 min, minSpacing 10 min, drawsToHalve 20, maxImpactBps 300, maxDeviationBps 200}` (section 10a) |
| Milestone tiers (D64; D74) | `Tiers {bigPrizeWei 0.5 ETH, bigPrizeBps 0, firstExitBps 10,000, exitWindow 24 hours}`: an Ape pull releases the whole reserve; a big prize releases nothing (D64 was 15% / 60% / the rest within 24 hours, which the analysis below uses) |
| Board changes | `setPattern` by the owner, at once: each row takes its new prize the next time it is listed; `setBoardSize` grows the board (D46, D57, D63) |
| Opening valuation | tick 173,000 ≈ 30.7 ETH FDV (≈ $69k), single-sided, 0 ETH (D70; was 161,200 ≈ 100 ETH, D38) |
| Keeper pay (D63) | **the game pays each useful `sync` or `retireStep` its measured gas (+70k overhead) at the transaction's gas price, capped at 3 gwei per gas (never refused above it), plus a 0.0002 ETH flat fee (D79; a 10% margin before)**, within its keeper allowance (0.2 ETH at opening, D82, a limit not a deposit, plus 1% of each capture's cost) and never out of cash owed to replacements (during retirement, from any cash, still within the allowance); the burner reimburses its own keeper with the same formula (≤ 5% of a slice) |
| Player path | the site draws through a stateless `DrawRouter`: it settles any draws waiting in FWA's queue (the player pays that gas, ≈ 240k per waiting draw; usually none), buys, then runs `game.sync` within a gas budget (asked for only when the measured upkeep is ≤ 2.5M gas; section 8), and `vault.sweep` (250,000 gas, D64) unpaid: it calls the game's `upkeep` (`sync`'s work, no keeper pay, D77) and sends the sweep reward back to the vault (D76; before them, both went to the player, D53, D59, D60). Keepers do heavy calls and are the backstop |
| No collection NFT in the draw | the game opens with its first NFT; after a win with no replacement, draws continue for Shapes and Packs (D53) |
| Coin | Ape Draw (ADRAW), the Ape game's own coin (D56); its trading fees go to the game's vault; only the MigrationAuthority redirects them, after a 72-hour notice (only before any migration starts; then they follow the successor), or into the sunset, for good (D63) |

## 2. The draw (one 6 ETH Ape at its 6 ETH opening notional, the 50-row board)

FWA weights each listing by 1 / price; the fee is EV × 1.05 with EV = listings / Σ(1/price); the owner receives
`fee − (fee − EV)/2`. Computed from FWA's rule and the actual Pack costs at the 10% markup (sim/pool.py,
sim/results/pool.md), confirmed on the fork (docs/receipts/many-apes-1.json: 0.019000 ETH fresh, 0.018997 decayed).

| | |
| --- | --- |
| FWA fee | **0.019000 ETH** (0.018629 with no Ape in the draw: one Ape at its price adds 2.0%) |
| FWA's VRF fee (paid by the player) | 1.95M gas × gas price: 0.00195 ETH at 1 gwei |
| FWA fee + VRF at 1 gwei | **0.02095 ETH** (sim/results/sessions.md) |
| The player's own transaction gas | ≈ 594,000 gas for `acquire` incl. the purchase gate, ≈ 636,000 through the DrawRouter with no upkeep (docs/receipts/gas.json): ≈ 0.0006 ETH at 1 gwei |
| **What one draw costs the player at 1 gwei** | **≈ 0.0216 ETH** |
| Expected player return (of FWA fee + VRF, 0.5 gwei) | 75.9% with the Ape at its opening; 81.2% at its minimum (25%); 75.6% with no Ape (sim/results/pool.md). Shapes and Packs alone return 77.95% of the FWA fee before VRF (sim/results/economics.md) |
| The Ape per draw | 1 in 16,910 at its opening notional; 1 in 4,228 at its minimum |

An Ape opens at its price, a fair lottery for that Ape, and gameplay improves its odds; with more Apes the chance of
some Ape per draw is higher (section 2a). The 50-row board has half the D45 board's rows, so one Ape at its price is
twice as likely per draw (1 in 35,578 on the 100-row board before D64).

Outcomes per draw (sim/results/sessions.md, the Ape at its opening): 0.01 Shape **70.38%** · 0.02 Pack **23.46%** ·
0.03 Pack **2.93%** · 0.04 Pack **0.73%** · 0.05 Shape **1.90%** · 0.1 Shape **0.32%** · 0.15 Pack **0.21%** ·
0.5 Shape **0.06%** · collection NFT **0.01%**. A prize of 0.05 or more: 2.5% of draws; 0.1 or more: 0.6%. There is no
1 ETH Shape and no 0.06 Pack; the 0.5 Shape is twice as likely as on the D45 board (0.032%) and is the board's big prize
for the milestone tiers (listed at 0.55 ETH with the markup, section 10a).

**What "prize worth at least FWA fee + VRF" means, and what it does not.** At 1 gwei 6.16% of draws return a prize
whose redeemable backing is at least the FWA fee plus FWA's VRF fee (the 0.03 Pack and above, and the Ape;
sim/results/economics.md); at 0.5 gwei 29.62%, because the 0.02 Pack then clears 0.019975 ETH by 0.000025 ETH. It
**excludes the player's own transaction gas and any redemption gas**, so it is **not a chance of net profit**: with
the transaction gas the 0.02 Pack never covers a draw, and a Pack redeem costs ≈ 0.12-0.19M gas more. The 10% markup
moved the 0.02 Pack below the line at 1 gwei; on the D45 board at 5% it cleared it (29.9% of draws then).

| Gas | FWA fee + VRF | prize ≥ FWA fee + VRF | source |
| --- | --- | --- | --- |
| 0.5 gwei | 0.01998 | 29.62% | economics.md, aggressive |
| 1 gwei | 0.02095 | 6.16% | economics.md, reference; sessions.md |
| 2 gwei | 0.02290 | 6.16% | economics.md, conservative |

## 2a. Many Apes (D59 rules, D64 values, D65 K 3 and overflow; sim/results/pool.md)

D82 changed the listing floor to an absolute 1 ETH (`minNotionalWei`), not 25% of each Ape's price, and raised K to 10; the figures below model the former 25%-of-price minimum and K 3, so read "at minimum (25%)" as the old floor.

Every Ape held is in the draw. Gameplay is credited evenly to the Apes in the draw; each ETH credited to an Ape lowers
its notional by 0.1 ETH, down to the floor (`minNotionalWei`, 1 ETH at launch, D82; a 6 ETH Ape reaches it after 50 ETH of
gameplay credited to it). The Apes' share of a draw's expected value is held at or below the **20%** target: a listing
or a decay step that would pass it waits, and the board grows by the Shapes and Packs it needs, paid from the vault.
Gas 0.5 gwei.

| Apes (6 ETH each) | state | ordinary rows | board capital | FWA fee vs no Apes | player return | some Ape per draw | gameplay per Ape win |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | at price / at minimum | 50 / 50 | 1.67 ETH | +2.0% / +2.0% | 75.9% / 81.2% | 1 in 16,910 / 4,228 | 321 / 80 ETH |
| 5 | at price / at minimum | 50 / 102 | 1.67 / 3.36 | +10.0% / +4.6% | 77.3% / 89.1% | 1 in 3,383 / 1,729 | 69 / 34 |
| 10 | at price / at minimum | 50 / 197 | 1.67 / 6.62 | +19.9% / +5.4% | 78.7% / 89.6% | 1 in 1,692 / 1,661 | 38 / 33 |
| 20 | at price / at minimum | 87 / 387 | 3.08 / 13.08 | +24.3% / +5.4% | 79.2% / 89.9% | 1 in 1,455 / 1,633 | 34 / 32 |
| 50 | at price / at minimum | 207 / 957 | 6.77 / 31.76 | +23.4% / +5.0% | 79.2% / 90.0% | 1 in 1,408 / 1,621 | 32 / 32 |
| 100 | at price / at minimum | 407 / 1,907 | 13.44 / 63.42 | +24.2% / +5.1% | 79.3% / 90.0% | 1 in 1,381 / 1,614 | 32 / 32 |

Expected gameplay until the first win with k fresh Apes listed together: 1 Ape 103 ETH (34 days at 3 ETH a day),
5 Apes 57, 10 Apes 36, 20 or more 33-34 ETH (11 days at 3 ETH a day).

**What this means for players, stated plainly.** With a few Apes, gameplay raises their odds as they decay. From about
10 Apes the target binds: further decay then mostly adds Shapes and Packs to the board, so the chance of winning some
Ape per draw stays near 1 in 1,400-1,700 (about `target × EV / price`) instead of rising; what decay still improves is
the draw's value (player return 79% → 90%) and its price (Apes at their price raise the FWA fee up to ≈ 24%, at their
minimum ≈ 5%). The site shows this.

**Target choice (100 Apes).** 15%: 1 in 2,178 per draw, return 78.3% / 86.4% (fresh / decayed), fee +17.1% / +3.8%;
**20% (launch)**: 1 in 1,614, 79.3% / 90.0%, +24.2% / +5.1%; 25%: 1 in 1,276, 80.2% / 93.7%, +32.0% / +6.5%. Over three
years (base flows 10 / 3 ETH a day) a 20% target buys 125 Apes and wins 91, against 120 and 78 at 15% (383.2 ETH of
buybacks against 340.8). Ape value paid out per ETH played is at most the target / 1.05: at 20%, about 19% of
gameplay's value returns to players as Apes bought with trading fees.

**Board growth on demand, not up front.** Sizing the board for every Ape's eventual minimum at acquisition would tie up
rows nobody plays when trading outruns play (three years at 150 ETH a day of trading and 0.5 ETH a day of play: 15,036
rows and 499.5 ETH up front against 3,436 rows and 113.0 ETH on demand) and buys fewer Apes in every scenario modelled
(base flows: 111 bought and 48 won up front, against 125 and 91 on demand).

**Three years (sim/pool.py part 2; live bid with the D64 first threshold, the D65 fee overflow, K 3, arbitrage sellers at the floor
+ 0.5%, floor 6 ETH, 5% fees plus the opening curve's first hour at 50 ETH of volume, 0.5 gwei).** Gameplay begins
once the first Ape and then the 50-row board, the 0.5 ETH reserve and the opening keeper pay (within the 1 ETH allowance, D79) are funded.

| trading / gameplay, ETH a day | active from day | Apes bought (ETH) | won | held at end | ordinary rows | player return | keeper pay | fee overflow | buybacks (incl. overflow) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 10 / 3 | 1 | 125 (757) | 91 | 34 | 297 | 83.5% | 54.2 | 0.2 | 383.2 ETH |
| 150 / 0.5 (trading ≫ gameplay) | 1 | 864 (5,228) | 17 | 847 | 3,436 | 79.2% | 7.2 | 2,916.9 | 3,013.3 ETH |
| 0.5 / 30 (gameplay ≫ trading) | 1 | 194 (1,175) | 193 | 1 | 50 | 78.8% | 654.8 | 0 | 2,122.7 ETH |
| 10 / 3, then 150 / 40 (sudden popularity) | 1 | 830 (5,021) | 823 | 7 | 183 | 83.9% | 764.3 | 3,750.2 | 8,392.1 ETH |
| 10 / 3, nothing days 120-300 | 1 | 104 (629) | 72 | 32 | 297 | 83.7% | 45.3 | 0.2 | 319.6 ETH |

Gameplay opens on day 1 in every scenario because the curve's first hour (19.5 ETH of fees at 50 ETH of volume, an
assumption; section 10) pays for the first Ape and the activation capital at once; section 10b shows what each flywheel
mechanism adds. When trading far outruns play, Apes accumulate (847 held after three years, all listed, barely
decayed): an intended outcome; the board, 3,436 rows, holds 113.0 ETH of Shapes and Packs (redeemable backing, not
spent), and the fee overflow turns the fees the rate-limited bid cannot use into buybacks (2,917 ETH; without it 2,849
ETH would sit idle in the vault). When play far outruns trading, every Ape is won soon
after it is listed and gameplay's own margin funds the next one. No Ape waited for rows in any scenario. Gas for Ape
upkeep and growth is small (at most 0.40 and 1.33 ETH over three years); replacing won prizes is the keeper cost.

**Maintenance with many Apes (fork, `test/scenario/ManyApes.t.sol`).** Listing, repricing and growth all run in bounded
keeper calls: at most 10 Apes listed and 10 repriced, 8 prizes minted and listed (the board's `maxPerCall`, D61), and
50 rows added per call. The 20-, 50- and 100-Ape receipts were measured before D64 (the 100-row board, a 15% target),
so their rows and fees are not the table above; their gas per call does not depend on those values. The 1-Ape receipt
is on the D64 board (many-apes-1.json: 50 rows, FWA fee 0.019000 / 0.018997 ETH, `acquire` 489,032 gas, an Ape win
settled for 411,749, the largest maintenance call 1.71M, a site draw with upkeep at most 1.14M).

| Apes (pre-D64 board) | rows at price / at minimum | keeper calls to list all | largest call | purchase gate | a draw (`acquire`) |
| --- | --- | --- | --- | --- | --- |
| 20 | 128 / 528 | 6 | 6.74M gas | 7,463 gas | 489,081 gas |
| 50 | 298 / 1,298 | 27 | 7.14M gas | 7,499 gas | 489,152 gas |
| 100 | 581 / 2,581 | 63 | 7.28M gas | 7,558 gas | 489,271 gas |

Every call fits EIP-7825's per-transaction cap of 16,777,216 gas with room to spare, and FWA's 100,000-gas
purchase-operator stipend (the gate column is measured with storage already warm; cold, as inside a purchase, it is
≈ 44,000 gas, docs/receipts/gas.json); a draw costs the same whatever the pool's size (FWA's selection is a fixed-depth
tree). No FWA limit binds: FWA's pool holds up to 2^32 listings, its inventory batches are 20 (the code uses 8, 10 and
20), repricing is per listing and only with nothing in flight (the code follows that rule), and every inventory change
restarts FWA's purchase cooldown, which is 0 on mainnet today (if FWA raises it, maintenance windows space out to six
cooldowns, as before D59).

**The per-transaction gas cap (D61).** Since Fusaka, mainnet rejects any transaction above 2^24 = 16,777,216 gas. Before
D61 a call listed 20 prizes: 24.3M gas on a board of the heaviest prize (0.04 Packs of four Shapes), so such calls could
never have been mined. The worst cases now (`test/fork/TxCap.t.sol`, a board of 0.04 Packs only): listing a batch
10.3M per call; booking 25 wins, relisting 8 Packs and listing 10 Apes in one call 14.0M; a board change to another
heavy board 14.2M; retirement 2.3M. Each is asserted under 90% of the cap. The cost is more, smaller keeper calls: the
50-row opening board takes 7 syncs of about 6.5M gas (sim/results/keepers.md).

**The live bid (sim/results/bid.md; not re-run for D64).** Permanent Collection's model meters real ETH into the bid:
below the threshold at once, above it 0.05 ETH per 300 blocks. D64 changes two things the study does not model: the
first threshold is 100% of the reference price (the study's 75% applies from the first purchase on), and the step above
the threshold grows with play to at most four times 0.05 ETH (so under heavy play the climb is up to four times faster;
the slow rate above the 120% ceiling is unchanged). One year, hourly, constant step:

| case | live bid (0.05 ETH / 300 blocks) | previous time-rising bid (80%, +20%/day) |
| --- | --- | --- |
| arbitrage sellers, flat floor, 0.3 ETH/day of fees | 18 Apes, +0.5% over the floor | 18, +0.6% |
| same, sudden volume (4.5 ETH/day of fees) | 249, +0.9% (worst +1.3%) | 250, +0.8% (+0.9%) |
| floor doubles over 30 days, sudden volume | 139, +0.7% (+1.3%) | 140, +0.8% (+1.2%) |
| volatile floor (90%/yr), sudden volume | 285, +1.4% (+4.3%) | 247, +1.3% (+3.7%) |
| floor halves overnight, sudden volume | 473, +1.2% (worst +51.6%) | 328, +1.5% (+64.7%) |
| strategic sellers (wait for the second-lowest reservation) | 249, +0.9% | 250, +0.8% |
| thin market (holders want 10-40% over the floor) | 222, +12.9% | 224, +12.5% |
| six months with no fees and no activity | 9, +0.5% | 9, +0.6% |
| nobody sells for 30 days (sudden volume) | 232, worst +576% | 231, worst +588% |

The two bids buy at about the same prices; the material differences: (1) the live bid is ETH actually forwarded, so it
cannot rise with time alone; (2) its rate is an absolute amount (`maxSweepWei`, 1 ETH per 300 blocks at launch since D82, ≈ 24 ETH a day; the models below used D59's 0.05 ETH): if Ape prices double, the climb above the threshold takes twice as long relative to
the price, and the owner may change `maxSweepWei`; (3) a purchase keeps the unspent part of the bid, so after a fill
below the bid the next one starts higher; (4) sweepers are rewarded their gas plus the flat fee, at most 0.01 ETH (D82; the models used the former 0.5% of the forward, ≈ 0.3% of acquisition
spending), so the bid keeps moving without the owner or a dedicated bot. $111's own 2 ETH per 150 blocks
would overshoot by up to 2 ETH per step on a 6 ETH NFT; the models' 0.05 ETH per 300 blocks kept each step under 1% of the price (at D82's 1 ETH a step is larger: the owner's choice).

Limits no oracle-free bid avoids, stated explicitly: (a) a floor that halves overnight is hit at the old bid (worst
≈ +52% to +98% on the next purchase, then the threshold descends ≈ 25% per purchase); (b) if nobody sells for a long
time, the bid keeps rising as long as the vault has funds, and the first seller is paid all of it (+576% after 30 days
in the uncapped model). The relative ceiling (below) bounds (b); (a) stays. With the first threshold at 100%, the first
purchase is made at whatever price a holder accepts up to the reference price: the owner sets `REF_PRICE_WEI` to the
live floor on the day.

**The relative ceiling (D60, D61; sim/results/ceiling.md; not re-run for D64).** A hard relative ceiling stops
acquisitions for good whenever the floor rises more than the ceiling between two acquisitions; a ceiling with a slow
rate above it still reaches any floor in time. Apes bought / worst price over the floor / longest stall, one year:

| case | 150% / 0.005 (D60) | 125% / 0.005 | **120% / 0.0025 (D60/D61)** | 110% / 0.0025 | 110% / 0.001 | hard 120% |
| --- | --- | --- | --- | --- | --- | --- |
| nobody sells for 30 days, sudden volume | 244 / +103% | 244 / +81% | **243 / +48%** | 243 / +39% | 242 / +22% | 242 / +21% |
| nobody sells for six months, sudden volume | 128 / +403% | 128 / +381% | **126 / +198%** | 126 / +189% | 125 / +82% | 123 / +21% |
| floor +25% overnight, 0.3 ETH/day of fees | 14 / 0 d | 14 / 0 d | **14 / 4 d** | 14 / 12 d | 14 / 35 d | 2 / **STOPPED** |
| floor +25% overnight, sudden volume | 203 / 2 d | 203 / 2 d | **203 / 7 d** | 203 / 16 d | 192 / 39 d | 23 / **STOPPED** |
| floor doubles over 30 days, 0.3 ETH/day | 10 / 12 d | 10 / 20 d | **10 / 58 d** | 10 / 67 d | 10 / 193 d | 3 / **STOPPED** |
| floor doubles over 30 days, sudden volume | 139 / 3 d | 139 / 3 d | **139 / 3 d** | 139 / 3 d | 139 / 3 d | 139 / 3 d |
| floor doubles overnight, sudden volume | 133 / 27 d | 129 / 38 d | **112 / 81 d** | 108 / 90 d | 54 / 226 d | 23 / **STOPPED** |
| floor rises 50% over a year | 14 / 0 d | 14 / 0 d | **14 / 0 d** | 14 / 0 d | 14 / 0 d | 14 / 0 d |

Launch (D82): 120% of the last acquisition price, then `slowSweepWei` 0.01 ETH per 300 blocks (≈ 0.24 ETH a day); the
`0.0025` column above was the D60/D61 slow rate and predates D82, so the stalls shown are about four times longer than at the launch rate.
`slowSweepWei` 0 gives the hard ceiling; `ceilingBps` 0 removes it;
`maxPrice` remains the absolute brake. No oracle, no owner routine.

## 3. Player sessions (sim/results/sessions.md, the 50-row board)

Spend is FWA fee + VRF at 1 gwei (0.02095 ETH a draw), excluding the player's transaction gas (≈ 620k gas per draw,
≈ 0.0006 ETH at 1 gwei) and redemption gas. The Ape at its opening notional; 'returned' counts it at its reference cost.

| Draws | spend | returned, median (p10-p90) | P(returned ≥ spend) | P(any ≥ 0.05) | P(any ≥ 0.1) | P(any ≥ 0.5) | P(the NFT) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 10 | 0.210 | 0.14 (0.11-0.19) | 6.5% | 22.2% | 5.8% | 0.70% | 0.07% |
| 20 | 0.419 | 0.28 (0.24-0.36) | 4.0% | 39.6% | 11.1% | 1.41% | 0.11% |
| 50 | 1.048 | 0.72 (0.64-0.85) | 3.6% | 72.0% | 26.2% | 3.48% | 0.33% |

Against the D45 100-row board at 5% (same 50 draws): a prize ≥ 0.1 in 26.2% of sessions (14.7%), ≥ 0.5 in 3.48%
(2.51%), the NFT in 0.33% (0.16%), at a higher spend (1.048 against 0.992 ETH) and with no 1 ETH Shape; a prize
≥ 0.05 in 72.0% (75.7%).

## 4. Over cumulative gameplay: the secondary model (sim/results/economics.md)

**Model inputs predate D74, D76, D79 and D82** (a 75% milestone, a 1 ETH reserve, a 10% keeper
margin and players reimbursed for their upkeep; D82 later set `opsBps` to 1%, `openingAllowance` to 0.2 ETH, K to 10 and an absolute 1 ETH listing floor): read its figures as a sensitivity, not the launch values.

**This is the older D57 Ape model, kept as a secondary check, on the launch keeper rule since D65:** one lead Ape
opening at half its cost, at most three Apes held, draws staying open for Shapes and Packs with no Ape in the draw (25%
of demand assumed to keep playing then, `apeless_share`), and a collection win releasing the whole milestone reserve.
Keeper pay is the launch rule (D63): each capture adds 5% of its cost to the allowance (0.2 ETH at opening, less
listing the opening board); a useful call is paid (gas + 70,000) × min(gas price, 3 gwei) × 1.1 within it, gas from
the fork receipts. In the reference every draw runs its own upkeep through the DrawRouter (the site's default), so won
prizes are always replaced and the player pays the gas the allowance does not reimburse; a keepers-only variant (no
router; keepers call only when paid at least their gas, up to ten draws a call) is a sensitivity. Values: the 50-row
board, 10% markup, 5% fees, 35% continuity, 75% milestone, a 1 ETH reserve, K 3 (headroom 7), minimum live rows 70%.
Its Ape rules are not the launch's; use section 2a for the Apes and section 8 for the keepers' break-even.

The D64 run's closure at its 1 gwei reference (8.2% available) came from the retired KeeperFund rule and is gone: with
router upkeep nothing closes for maintenance at any gas price modelled; above the allowance's reach players carry
the rest of the upkeep instead.

| | conservative | reference | aggressive |
| --- | --- | --- | --- |
| Assumptions | trading 0.5×, NFTs 8 ETH, **2 gwei** | 1×, 6 ETH, 1 gwei | 3×, 5 ETH, 0.5 gwei |
| Return all-in (expected, of FWA fee + VRF; lead Ape at half its cost) | 67.8% | 74.1% | 77.7% |
| Collection NFT available | 72.0% | 94.1% | 99.6% |
| Wins per run (first win p50, ETH of gameplay) | 5.58 (94) | 7.88 (79) | 8.92 (71) |
| Distributable surplus | 78.6 | 87.0 | 97.8 |
| → continuity / coin buybacks (ongoing + milestone) | 27.4 / 51.1 | 28.2 / 58.8 (14.7 + 44.1, of which 39.4 released) | 17.7 / 80.1 |
| Keeper pay vs allowance earned (left at the end) | 42.81 vs 42.72 (0) | 42.46 vs 42.32 (0) | 36.29 vs 42.08 (5.96) |
| Upkeep gas players pay beyond the reimbursement, per draw | 0.00156 ETH | 0.00041 ETH | 0 |
| Closed for maintenance; worst cash; negative-cash runs | 0; 0.46; 0 | 0; 0.52; 0 | 0; 0.30; 0 |

At 1 gwei and above the allowance is spent in full (keeper pay equals what captures earn), so the surplus does not
depend on gas; what changes is the players' cost: about 0.0004 ETH a draw at 1 gwei, 0.0016 at 2, 0.0027 at 3, 0.0051
at 5 (about 2%, 8%, 14% and 27% of a 0.019 ETH ticket). Availability in the conservative case is lower because half the
trading funds Apes more slowly (8 ETH each), not because of maintenance.

**Sensitivity (48 runs per row, the reference with one change; distributable surplus → continuity / ongoing /
milestone buybacks):**

- **Gas, every draw running its upkeep:** 0.25 gwei: 96% available, 7.65 wins, 111.5 → 32.3 / 19.8 / 59.4; 0.5: 95%,
  7.83, 93.6; 1 to 5 gwei: 94%, 7.85-7.94 wins, 86.9-87.2 (the allowance spent in full; players pay 0.0004-0.0051 ETH
  a draw).
- **Gas, keepers only (no router):** 0.25 and 0.5 gwei as above; 1.0 gwei: 90% available, 7.88 wins, 85.8; 1.1 gwei:
  61%, 5.73, 66.3; **1.25 gwei and above: closed** (keepers stop when the allowance cannot pay their gas; nothing
  reopens it until gas falls or someone runs the upkeep at a loss). This is the break-even of section 8 (about 1.1
  gwei in batches of ten).
- **Fixed batches, keepers only, 1 gwei:** one draw per call → closed (its break-even is 0.58 gwei); three → 94%,
  7.67 wins, 87.8; ten → 93%, 7.85, 91.1.
- **Markup:** 5%: 42.1 ETH of surplus, return 77.1%; 7.5%: 65.7, 75.6%; 10%: 86.9, 74.1%; 12.5%: 107.8, 72.7%. Wins
  barely move (7.85-7.94): the markup moves the margin, not the Ape odds.
- **Keeper allowance 3%:** 104.5 ETH of surplus, but players pay 0.0007 ETH a draw of unreimbursed upkeep at 1 gwei
  (against 0.0004 at 5%).
- **Trading:** none: 20% available, 4.31 wins; 0.25×: 56%; 0.5×: 78%; 1×: 94%; 2-3×: 98-99%. Declining trading (2×,
  halving every 100 / 250 / 500 ETH of demand): 54% / 92% / 98%. Trading fee 3% / 5% / 7%: 83% / 94% / 97%.
- **Ape price:** 4 ETH: 10.19 wins; 6: 7.94; 10: 4.85.
- **K:** 3 / 4 / 5 make no material difference here (7.94 / 7.83 / 7.77 wins, 94% available); throughput and refunds
  are measured on the fork instead (section 6).
- **Other boards (each with its own markup):** the D45 100-row board at 5%: 40.3 ETH of surplus, 7.42 wins; the 0.05
  ETH board at 7.5%: 88.8, 7.75.
- The results file still has an "ENGINE active" row from the model's options: there is no ENGINE destination for
  surplus, which goes only to the vault and the burner (D63).

## 5. Why the surplus is small on a ≈ 0.02 ETH draw

Keeper gas and FWA's VRF fee are fixed in absolute terms while the draw is small. The keeper allowance a draw earns is
0.000806 ETH at the former 5% `opsBps` (D82's 1% makes it about one fifth, ≈ 0.00016 ETH; sim/results/keepers.md), and a single
replacement costs ≈ 1.15M gas, so per-draw upkeep spent all of the 5% allowance at ≈ 0.58 gwei (about one fifth of that gas price at D82's 1%). The buyback model assumes 0.00104 ETH
a draw of game surplus reaching the burner (sim/results/burner.md). Over three years of base flows (10 / 3 ETH a day)
keeper pay is 54.2 ETH against 383.2 ETH of buybacks, 0.2 of them from the fee overflow (sim/results/pool.md).
Levers: markup (raised from 5% to 10% for D64), lower gas, batching, trading volume.

## 6. FWA throughput, refunds and the in-flight limit (fork, sim/results/throughput.md)

The 50-row board on the D64 code (10% markup, 70% minimum live rows). Six seeded streams × 900 blocks (3 hours), singles
and five-draw batches through FWA's `acquireBatch`; a purchase is admitted while fewer than K requests are unsettled, so
with a batch up to K − 1 + 5 can be.

| K | completed (of attempts) | refunded (of issued) | expired | max unsettled | VRF lost at 1 gwei | keeper gas per completed |
| --- | --- | --- | --- | --- | --- | --- |
| 3 | 1,421 (39.0%) | 4 (0.3%) | 6 | 7 | 0.019 ETH | 691,547 |
| 4 (D65 launch) | 1,469 (40.4%) | 14 (0.9%) | 7 | 8 | 0.041 ETH | 697,509 |
| 5 | 1,557 (42.8%) | 19 (1.2%) | 7 | 9 | 0.051 ETH | 688,886 |

The refunds come from heavy demand (1 / 9 / 12 at K 3 / 4 / 5: listings staged while draws are in flight) and a lazy
keeper (3 at every K). A refunded player gets the price back and loses the VRF fee. On the 100-row D45 board at the
same K none was refunded (K 10 there: 2,086 completed, 0 refunds); the 70% minimum live rows on 50 rows lists more often
while draws are in flight. **The K decision (D82):** K is now 10, FWA's own per-pool limit (D64's K 4 and D65's K 3
traded throughput for fewer refunds). The worst case on the launch board was re-measured at K 10
(`test_launchInFlightBoundWorstCaseDrift`, test/fork/Game.t.sol): 10 requests issued on one quote, all drawing the
cheapest prize, had 2 of 10 refunded by FWA's slippage check; at K 3 none were. Lower K (`setMaxInFlight`, at once) if
refunds matter more than throughput. FWA's VRF layer allows 10 requests awaiting a word per pool, so a batch beyond it
reverts at FWA before any fee (tested). The K 3/4/5 table above was measured on the D64 board; K 10 was not run there.

## 7. Capital

| | ETH | Who funds it |
| --- | --- | --- |
| First collection NFT | the live bid fills at once to 100% of the reference price (6 ETH at the placeholder), then the metered step until a holder accepts; no cap | trading fees (the opening curve) / contributions |
| Opening board | 1.666 | trading fees / contributions |
| Operating reserve | 0.5 (D79; 1.0 before) | trading fees / contributions |
| Opening keeper pay (allowance 0.2 ETH, D82: a limit) | what listing the board costs, about 0.05-0.14 | trading fees / contributions (keepers listing the board are paid from the game's cash, which the vault refills, at the latest at activation) |
| **Activation total** | **first Ape + 1.666 + 0.5 + 0.1 ≈ Ape + 2.27** (D79; 2.77 with the 1 ETH reserve before) | the vault, after the NFT |
| Board growth (on demand) | ≈ 0.033 per row (≈ 4 rows per Ape at its price, ≈ 19 at its minimum: ≈ 0.13-0.63 ETH per 6 ETH Ape; sim/results/pool.md, 100 Apes) | the vault, before it bids again |

At the 6 ETH placeholder, activation needs ≈ 8.37 ETH of fees or contributions. The curve's first hour yields 19.5 ETH
at 50 ETH of volume traded evenly, 7.8 ETH at 20 ETH (sim/results/launch.md): in the three-year model the first case
opens gameplay on day 1, the second on day 1 to 45 depending on later flows (section 10b).

Settlement exposure is `min(unsettled × costliest prize, every prize held or listed)` (D48): at launch at most the
board's 1.666 ETH.

## 8. Keepers: who pays for maintenance, and up to what gas price

Since D63 the game pays each useful call itself: `sync` and `retireStep` pay their caller
`quoteTip(gasUsed) = (gasUsed + 70,000) × min(tx gas price, 3 gwei) + 0.0002 ETH` (D79; a 10% margin before). The first
term reimburses the call's gas at what the caller paid (70,000 covers the gas outside the game's own measurement); above
3 gwei it is still paid, at 3 gwei. The flat fee gives a third-party keeper a reason to run at any gas price (10% of gas
was about 0.00001 ETH at a 0.1 gwei basefee); there is no interval. Payment is
limited to the keeper allowance (`keeperAvailable()`): 0.2 ETH at opening (D82; a limit, not a deposit), plus each capture's `opsBps` (1% since D82, frozen at
listing) of its replacement cost; it never comes out of cash owed to replacements (during retirement the limit is the
game's cash), and it is an expense (`profit = revenue - prizeExpense - keeperPaid`). Unspent allowance is not set aside:
the cash stays profit, and the allowance remains as headroom for later calls. A call with no work reverts; refilling
the reserve from the vault counts as work only when the need was at least one row's cost, so keeper pay cannot earn the
next call a fee by itself. Every parameter is the owner's (`setKeeperParams`; the rate through `setPricing`). The
caller is a keeper; a player's draw through the DrawRouter runs the game's unpaid `upkeep` instead (D76, D77), and
within `payDelay` (5 minutes) of such an upkeep a paid `sync` of light work (under 2.5M gas) does the work and is paid
nothing (D82; a no-work call still reverts `NoWork`), so the keeper bot skips light work unless `UNPAID=1`.

**One call (computed with the 10% margin before D79, and the former 5% `opsBps`: D82's 1% makes the allowance earned
below about one fifth of what is shown, so far less is sustainable; sim/results/keepers.md; the 50-row board, 10% markup; allowance 0.000806 ETH per draw at 5%; a keeper pays
(gas + 21,000) × (basefee + 0.02 gwei priority)).**

| draws booked and replaced per call | gas | keeper margin at 0.5 / 1 / 2 gwei | game pays at 1 gwei | allowance earned | sustainable at 0.5 / 1 / 2 gwei |
| --- | --- | --- | --- | --- | --- |
| 1 | 1,152,036 | +0.000089 / +0.000175 / +0.000346 | 0.001371 | 0.000806 | yes / no / no |
| 3 | 2,115,567 | +0.000139 / +0.000273 / +0.000540 | 0.002452 | 0.002419 | yes / no / no |
| 5 | 3,878,192 | +0.000231 / +0.000453 / +0.000897 | 0.004430 | 0.004032 | yes / no / no |
| 10 | 6,542,752 | +0.000369 / +0.000724 / +0.001435 | 0.007420 | 0.008064 | yes / yes / no |

"Sustainable": pay per call at most the allowance it earns. Above it the allowance runs down and pay stops when it is
spent. Up to 3 gwei the keeper's margin stays positive (the game pays gas plus a flat fee; 10% before D79); at 5 gwei the 3 gwei cap makes
every call a loss for the keeper (−0.001856 ETH for one draw, −0.011128 for ten).

| Break-even average gas price for the allowance | draws per call | gas per draw | break-even basefee |
| --- | --- | --- | --- |
| per-draw upkeep (the DrawRouter) | 1 | 1,152,036 | **0.58 gwei** |
| | 3 | 705,189 | 0.99 gwei |
| keepers batching | 5 | 775,638 | **0.91 gwei** |
| | 10 | 654,275 | **1.09 gwei** |

**Listing the opening board** (7 syncs of about 6.5M gas, paid within the opening allowance: 0.2 ETH since D82 (1 ETH in
D79, 0.1 ETH in D73); under the flat fee add 0.0014 ETH): 0.0061 ETH at
0.1 gwei (3% of the 0.2 ETH allowance), 0.0265 at 0.5 gwei (13%), 0.0519 at 1 gwei (26%), 0.1527 at 3 gwei and above
(76%); all fit within the 0.2 ETH allowance, so every listing call is paid. (The old 0.1 ETH D73 allowance could not
cover the 3 gwei case, leaving the last calls to the primary keeper unpaid.)

**Two years, 150 draws a day (sim/results/maintenance.md; allowance 0.000806 ETH per draw plus 0.2 ETH at opening).**
"Players pay": upkeep gas the allowance could not cover, per draw, paid by the players whose draws run it. "Kept by the
game": allowance earned but not paid out (profit: continuity, then buybacks).

| gas | upkeep | keeper margin per draw | players pay per draw | kept by the game |
| --- | --- | --- | --- | --- |
| 0.2 gwei | per draw (DrawRouter, the site's default) | 0.000038 ETH | 0 | 56.1 ETH |
| 0.2 gwei | ten per keeper call | 0.000016 ETH | 0 | 71.0 ETH |
| 0.3 gwei, 10× spike days | per draw | 0.000078 ETH | 0 | 20.3 ETH |
| 0.3 gwei, 10× spike days | ten per keeper call | 0.000032 ETH | 0 | 51.6 ETH |
| drifting | per draw / ten per call | 0.000086 / 0.000035 ETH | 0 / 0 | 15.0 / 48.7 ETH |
| rises to 2 gwei for good | per draw / ten per call | −0.001041 / −0.000226 ETH | 0.001073 / 0.000265 ETH | 0 / 0 |
| rises to 5 gwei for good | per draw / ten per call | −0.003692 / −0.001710 ETH | 0.003701 / 0.001714 ETH | 0 / 0 |

Below the limit the allowance more than covers the upkeep and the rest returns to the game as profit; batching keeps
more of it (71.0 against 56.1 ETH at 0.2 gwei). In spiky or drifting gas the allowance still pays every call. When gas
rises for good, the allowance is spent and players' draws carry the upkeep: about 0.001073 ETH a draw at 2 gwei with
per-draw upkeep, 0.000265 with batched keepers.

**A player's draw and the upkeep (D60).** The DrawRouter runs the game's upkeep after the purchase within a gas
budget the caller sets (`upkeepGas`), keeping 310,000 gas back for the steps after it (the vault's sweep, 250,000 since
D64, and the change); an upkeep that needs more fails on its own and the draw stands. The site first measures the
upkeep (`measureUpkeep`, simulated) and asks for it only when it is at most 2.5M gas, with a budget 30% above the
measurement; heavier work (a full listing batch, board growth, repricing many Apes) is left to keepers' own `sync`
calls. The measurement is an upper bound: with the player's own draw in flight the game lists replacements only when
the board is below its minimum and reprices Apes only with nothing in flight, so a draw mostly books settled draws and
sweeps the bid. Fork measurements (`test/scenario/ManyApes.t.sol`): a draw with nothing to do costs ≈ 0.50-0.61M gas,
one that does the upkeep ≈ 0.73-1.20M (1.14M at most on the D64 board, many-apes-1.json), never more than the purchase
plus the measured upkeep; the wallet's gas limit includes the budget (the router requires it, so an estimate cannot
leave it out), unused gas is not charged. Since D76/D77 the player is not paid for it and the game pays nothing for it: the router calls `upkeep` (no tip, no
keeper allowance spent) and sends the sweep reward back to the vault; the player pays the upkeep's gas.

**Conclusion, stated explicitly: the game sustains its necessary maintenance only while the average gas price is at or
below about 0.58 gwei with per-draw upkeep and about 0.9-1.1 gwei with keepers batching three to ten draws.** Between the
two, keepers batching keep it paid (a keeper waits for enough draws; low activity is not a problem, the gate closes only
when more than 15 rows wait). Above 1.1 gwei no batch size makes maintenance pay from the allowance: keepers are paid
until it is spent, then players' draws carry the upkeep; if nobody runs it, prizes stay off the board until more than
15 rows are missing, then the purchase gate closes the game. Nothing is at risk (draws in flight settle; no keeper is
needed for safety, D36). It reopens when gas falls (the captures the first syncs book add to the allowance).

No cap on a call's size (since D57): a call is paid its measured gas plus the flat fee (D79), whatever its size, within the
allowance; above `maxGasPrice` (3 gwei) it is reimbursed at 3 gwei per gas rather than refused, so a keeper working
through a spike is paid part of its cost. A full listing batch (8 prizes, ≈ 6.5M gas; up to 10.3M with the heaviest
Packs; the opening board and any recovery) is paid in full up to 3 gwei while the allowance lasts.

**Historical (pre-D63).** Until D63 keeper pay went through a separate KeeperFund (the gas refund plus a flat fee or an
age bounty, a 1 ETH lifetime top-up from fees, its surplus returned to the game by the owner). That analysis (the
percentage-premium comparison, the flat fee's interval, the steady-state tables) described a mechanism that no longer
exists and was measured on the 100-row board; it is removed here and kept in the history of this file and in
docs/IMPLEMENTOR_DECISIONS.md (D53-D63). Since D65 the secondary model in section 4 uses the launch rule too.

| Other calls (fork, docs/receipts/gas.json and gas-prizes.json; measured before D64's changes) | Gas |
| --- | --- |
| player `acquire` (FWA, gate included) | 594,210 |
| player draw through the DrawRouter (nothing waiting to settle, no upkeep) | 635,948 |
| `canPurchase` (inside FWA's 100k stipend; cold, as in a purchase) | 43,976 |
| `sync`: book 1, no listing | 327,211 |
| `sync`: book an Ape win and release the milestone | 628,827 |
| burner `process` (one slice) | 305,269 |
| `setPattern`: a new 100-row pattern | 3,352,492 |
| player `redeem` of a 3-Shape Pack / `open` of a 2-Shape Pack | 190,851 / 122,008 |
| deployment, every contract incl. Draw Packs, the MigrationAuthority and the Sunset | 36,307,777 |
| holder sale to the live bid (`sellToProtocol`) | 323,017 |

## 9. When trading declines

**Since D53 the game no longer closes when trading stops.** With no trading fees the next Ape waits for the vault's
surplus share (35% of the game's margin while it is short) to fund it, but draws continue for Shapes and Packs
meanwhile, and their margin is what funds it. The contracts stay solvent and every draw settles either way.

The primary model (sim/results/pool.md, three years, on-demand growth):

| flows (trading / gameplay, ETH a day) | Apes bought | won | player return | fee overflow | buybacks |
| --- | --- | --- | --- | --- | --- |
| 10 / 3 | 125 | 91 | 83.5% | 0.2 | 383.2 ETH |
| 10 / 3, nothing at all days 120-300 | 104 | 72 | 83.7% | 0.2 | 319.6 ETH |
| 0.5 / 30 (almost no trading) | 194 | 193 | 78.8% | 0 | 2,122.7 ETH |

Six months with neither trading nor play cost 21 Apes and 64 ETH of buybacks against the base, and nothing else: the
game resumes where it stopped. With almost no trading, play funds 194 Apes itself, each won soon after it is listed;
the fee overflow never triggers (the bid uses all the ETH). What does depend on trading is the start: with 0.5 ETH a day of trading
and no opening curve, gameplay would open only on day 257 (section 10b).

The secondary model (section 4) agrees on direction: with no trading an Ape is available for 20% of demand, with half
the reference trading 78%, with the reference 94%.

## 10. Coin launch (sim/results/launch.md)

Unchanged and approved: all supply single-sided below the start price, 0 ETH, ≈ 100 ETH opening FDV (D38). New in D64:
the **opening curve**. From the pool's single initialisation, buys and sells pay max(ordinary fee, 69% − 1 percentage
point per minute), linear per second (`LAUNCH_FEE_BPS` 6,900, `LAUNCH_DECAY_BPS_PER_MINUTE` 100); at the 5% ordinary
fee the curve ends at minute 64. It is immutable: no owner can extend, restart or skip it, and `LAUNCH_FEE_BPS` is also
the hook's absolute clamp. The views `curveBps()`, `currentFeeBps(isBuy)` and `openingFee()` (buy and sell fee, seconds
to the ordinary fee) let a wallet or the site show the current fee. Exact-output buys pay `net × f / (1 − f)`, i.e. f of
the gross ETH, as exact-input buys do, so exact output cannot be used to pay less during the curve; exact-output sells
remain unsupported. All fees are in ETH, to the vault.

**Fees to the vault in the first hour.**

| when volume comes | average fee | 20 ETH traded | 50 ETH | 100 ETH |
| --- | --- | --- | --- | --- |
| evenly over minutes 0-60 | 39.0% | 7.8 | 19.5 | 39.0 |
| rising linearly toward minute 60 | 29.0% | 5.8 | 14.5 | 29.0 |
| traders wait for ≤ 15% (minutes 54-60) | 12.0% | 2.4 | 6.0 | 12.0 |
| reference: flat 5% | 5.0% | 1.0 | 2.5 | 5.0 |

**Opening purchases at 100 ETH FDV.** A 1 ETH buy at minute 0 gets 0.309% of supply at 3.24× the opening price; at
minute 30, 0.606% at 1.65×; after the curve (minute 65), 0.941% at 1.06× (+1.9% price impact). A 5 ETH buy: 1.526% /
2.960% / 4.535% of supply. At 50 ETH FDV the shares double; at 250 ETH they are 2.5 times smaller.

**Early buyers: the curve is a descending auction for early position.** Return of a buy at minute N, sold at 5% after
organic buying of 0.5 ETH buys after the curve (opening FDV 100 ETH):

| organic buying after the curve | buy | minute 0 | 10 | 30 | 50 | 60 | 64 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 10 ETH | 1 ETH | −65% | −53% | −31% | −8% | +3% | +8% |
| 50 ETH | 1 ETH | −36% | −16% | +25% | +66% | +86% | +94% |
| 50 ETH | 5 ETH | −37% | −17% | +22% | +60% | +79% | +87% |

A 1 ETH buyer at minute 0 needs **89 ETH** of later organic buying to break even (minute 30: 33 ETH; minute 50: 15;
minute 60: 8). Sold with no other flow, a 1 ETH minute-0 buy returns 0.099 ETH at minute 1, 0.189 at minute 30 and
0.295 at minute 64. A block-0 sniper is the curve's main payer, not its winner. After the curve a round trip costs
9.75% (5% each way); twenty 0.5 ETH buyers who all exit get 9.02 ETH of their 10 back, whatever the order, and 26 ETH of
buybacks in between turn that into 13.54 ETH back (+35%; 17.5% of supply burned).

**The scanner risk (accepted by the owner).** A sell fee of 69% falling to 5% over 64 minutes is what honeypot
scanners look for: during roughly the first 20 minutes wallet and token scanners may flag the coin as a honeypot, and
cached labels can outlive the curve. Nothing in the contracts prevents a sale at any time, and the fee is public
(`openingFee()`); the owner accepted the risk for the first hour's fees and the early-buyer protection.

## 10a. Buybacks and milestones (sim/results/burner.md; src/treasury/CollectionBurner.sol)

**What reaches the burner.** The game's surplus once the vault holds an Ape (before that, 65% of each distribution; the
vault takes 35% while it is short), the vault's fee overflow (section 10b), and, at the end, the sunset successor's
proceeds or any donation. Of what the game sends, `milestoneBps` (**100%** at launch, D74; 75% in this analysis) is locked in the `reserve`; the rest, and
everything from anyone else (the overflow included), is the ongoing bucket.

**Milestone releases (tiers).** `release(listingId)` (anyone; the game calls it when it books a qualifying capture, and
the keeper bot retries) checks FWA's own records: the listing is `Settled` to a purchaser other than the pool owner, and
has not released before. Then:

| win | releases (of the reserve) |
| --- | --- |
| a big prize: a Shape or Pack listed at ≥ `bigPrizeWei` (0.5 ETH; on the launch board only the 0.5 Shape, listed at 0.55) | 15% (`bigPrizeBps`) |
| an Ape exit (any collection listing) | 60% (`firstExitBps`) |
| a second Ape exit within 24 hours of the last (`exitWindow`) | the rest (100%) |

A small prize, a refunded or pending delivery, or a withdrawn listing never qualifies. After the game retires,
`releaseRetired` releases everything. The owner may change the tiers (`setTiers`: the big-prize share 0-100%, the
Ape-exit share 10-100%, so the reserve can never be locked for good; the window at most 7 days); every release still
ends in buybacks, so the tiers change only the timing. The game asks for a big-prize release when the capture's listed
price (cost × 1.10) is at least `burner.bigPrizeWei()`, and for every Ape win.

**Released ETH is spent first, 1 ETH every 10 minutes**, and a release lets the next slice run at once: in practice at
the keeper's next tick, not inside the booking transaction (FWA settles wins without calling the protocol, and a swap
inside the game's booking would add MEV exposure to the keeper's sync).

| release | 1 ETH slices every 10 minutes | done | largest slice under the 3% impact limit at FDV 50 / 100 / 250 ETH |
| --- | --- | --- | --- |
| 0.5 ETH | 1 | at once | 0.74 / 1.49 / 3.72 ETH |
| 3 ETH | 3 | 20 min after the first | same |
| 9 ETH | 9 | 80 min after the first | same |
| 30 ETH | 30 | 290 min after the first | same |

A slice larger than the impact limit allows is filled only up to the limit (the swap's price limit); the rest stays in
the bucket for the next slice. At an opening FDV of 50 ETH a 1 ETH slice is cut to about 0.74 ETH; from about 67 ETH of
depth a full 1 ETH slice fits.

**Ongoing buybacks follow play.** With n FWA draws issued since the last slice (`drawsSinceLastRun`, from FWA's
`lastIssuedSequence`), the slice is min(1 ETH, bucket, 0.05 + 0.005 × n + 1% of the bucket) and the spacing
max(10 min, 60 min × 20 / (20 + n)). `nextSlice()` returns the amount, whether it is milestone ETH, and when it may
run; `process` reverts `TooSoon` before that.

| draws since the last slice | 0 | 5 | 10 | 20 | 50 | 100 | 190+ |
| --- | --- | --- | --- | --- | --- | --- | --- |
| spacing | 60 min | 48 | 40 | 30 | 17 | 10 | 10 |
| slice (bucket permitting; + 1% of the bucket) | 0.050 ETH | 0.075 | 0.100 | 0.150 | 0.300 | 0.550 | 1.000 |

**Does the cadence keep up? (30 days.)**

| draws a day | inflow a day | slices a day | average slice | spent of inflow | left in the bucket |
| --- | --- | --- | --- | --- | --- |
| 50 | 0.01 ETH | 26.2 | 0.000 ETH | 100% | 0 |
| 50 | 5.01 ETH (5 ETH of fee overflow) | 26.2 | 0.175 ETH | 91% | 13.08 ETH |
| 150 | 5.04 ETH (5 ETH of fee overflow) | 30.0 | 0.158 ETH | 94% | 9.13 ETH |
| 500 | 5.13 ETH (5 ETH of fee overflow) | 38.9 | 0.130 ETH | 99% | 1.70 ETH |
| 1,500 | 5.39 ETH (5 ETH of fee overflow) | 55.4 | 0.097 ETH | 100% | 0.05 ETH |
| 5,000 | 6.30 ETH (5 ETH of fee overflow) | 90.0 | 0.070 ETH | 100% | 0 |

**Why the backlog term (D64).** A cadence keyed only to draws spends little when play is light, but the fee overflow
can bring several ETH a day regardless of play: without the term the bucket grew without bound (docs/
IMPLEMENTOR_DECISIONS.md D64). With 1% of the bucket added to each slice, the backlog settles where 1% of it matches the
inflow the draw-keyed part does not spend: about 13 ETH at 50 draws a day with 5 ETH a day of overflow, 1.7 ETH at 500,
none from about 1,500. The term is owner-adjustable up to 10% (`backlogBps`).

A limit of the cadence model: it runs every slice when due (the inflow is the ongoing quarter of the game's burner share,
0.00026 ETH a draw, plus any overflow), whereas a keeper is reimbursed at most 5% of a slice, which does not cover the
gas of a tiny idle slice. Such slices wait until draws or the backlog make them worth a keeper's gas; the ETH stays in the
bucket meanwhile.

**Hard bounds no owner can pass** (constants): a slice at most 1 ETH (`MAX_SLICE_WEI`), spacing at least 10 minutes
(`MIN_SPACING`) and at most 30 days, impact at most 5% (`MAX_IMPACT_BPS`), deviation since the block opened at most 3%
(`MAX_DEVIATION_BPS`), the backlog term at most 10%. Within them the owner sets the cadence (`setCadence`) and the
milestone share (`setMilestoneBps`). A slice's keeper is reimbursed with the game's formula, at most 5% of the slice
(`MAX_TIP_BPS`). There is no other outflow: bought coins are burned in the same call.

## 10b. The vault's fee overflow (sim/results/pool.md; src/core/FundingVault.sol)

**Fee overflow (D64; trigger D65).** Trading fees are counted as they arrive (`unsplitFees`; the swap path adds one
storage write). The next `sweep` splits them: if the live bid is at its fill target (the activation threshold, or the
120% ceiling or `maxPrice` when lower), 50% of them (`overflowBps`) go to the CollectionBurner's ongoing bucket, never
more than the vault holds beyond the game's capital need, the board growth its Apes wait for, the bid's ETH **and one
more Ape at the funding reference** (`pendingOverflow()`); otherwise they stay as capital. So only ETH the bid cannot use goes:
the bid is rate-limited (1 ETH per 300 blocks above the threshold at launch, D82, ~24 ETH a day; the arbitrage climb to a seller's price takes
a few hours), and without the overflow fees that outrun Ape purchases sit idle in the vault. The next Ape is always
funded, so acquisitions are not slowed. A sweep that only overflows still succeeds. `overflowOut` counts it; the
vault's conservation invariant includes it (balance + acquisitions + finder fees + sweep rewards + game capital +
migrated + overflow = trading fees + contributions + surplus received + returned from the game).

**Why this trigger (D65).** The owner asked for the overflow to fire only while an Ape waits because the board cannot
take it. In the contracts that never happens for long: the board grows by the rows a waiting Ape needs, funded before
the bid, within about an hour, so no Ape waits (the "most queued" column of pool.md is 0 in every scenario) and that
rule would send nothing to buybacks while 2,849 ETH sat idle after three years of trading ≫ play. D64's rule (an Ape
waiting or 10 listed) fired while the board could still take Apes and slowed buying in the base case (112 Apes against
125). The owner chose the idle-ETH rule (all three compared below).

**The play meter (D64) was removed (D65).** It added code to the audit for little effect at expected volumes (base
flows: 125 Apes either way). Under heavy play it did matter: in the sudden-popularity scenario (150 ETH a day of trading,
40 of play) the bid climbs to a seller's price faster with it, 1,106 Apes bought and 1,067 won over three years against
830 and 823 without. The owner can get that effect back by hand: a fixed `maxSweepWei` of 0.1 ETH buys 1,074 and wins
1,044 there, and 125 / 90 at base flows, but in trading ≫ play it also buys 1,097 Apes (233 more, nearly all unplayed)
and halves the overflow (1,444 ETH). So the step stays 0.05 ETH and is raised when sustained heavy play makes Apes the
limit (docs/RUNBOOK.md).

**What each mechanism adds (three years, on-demand growth; each row switches one off or swaps the overflow rule):**

| flows | variant | active from day | Apes bought | won | player return | fee overflow | buybacks | vault ETH idle at the end |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| base (10 / 3) | **launch (D65)** | 1 | 125 | 91 | 83.5% | 0.2 | 383.2 | 1.5 |
| | no opening curve (first hour at 5%) | 12 | 121 | 87 | 83.5% | 0 | 372.4 | 3.0 |
| | curve, traders wait for ≤ 15% | 5 | 122 | 89 | 83.5% | 0 | 374.9 | 1.7 |
| | curve, 20 ETH in the first hour | 2 | 122 | 89 | 83.5% | 0 | 376.8 | 4.6 |
| | no fee overflow | 1 | 125 | 91 | 83.6% | 0 | 386.6 | 3.4 |
| | overflow only while an Ape the target held back waits | 1 | 125 | 91 | 83.6% | 0 | 386.6 | 3.4 |
| | overflow while the board has no room for one more Ape | 1 | 123 | 89 | 83.6% | 10.8 | 393.8 | 2.9 |
| | overflow by the D64 rule (an Ape waiting or 10 listed) | 1 | 112 | 87 | 83.7% | 68.5 | 435.9 | 4.9 |
| trading ≫ gameplay (150 / 0.5) | **launch (D65)** | 1 | 864 | 17 | 79.2% | 2,916.9 | 3,013.3 | 5.3 |
| | no opening curve | 1 | 864 | 17 | 79.2% | 2,900.2 | 2,996.3 | 5.3 |
| | no fee overflow | 1 | 868 | 17 | 79.2% | 0 | 145.5 | 2,849.1 |
| | overflow only while an Ape the target held back waits | 1 | 868 | 17 | 79.2% | 0 | 145.5 | 2,849.1 |
| | overflow while the board has no room for one more Ape | 1 | 867 | 17 | 79.2% | 483.8 | 624.9 | 2,375.9 |
| | overflow by the D64 rule (an Ape waiting or 10 listed) | 1 | 805 | 17 | 79.2% | 3,277.5 | 3,374.3 | 9.2 |
| gameplay ≫ trading (0.5 / 30) | **launch (D65)** | 1 | 194 | 193 | 78.8% | 0 | 2,122.7 | 6.5 |
| | no opening curve | 257 | 147 | 146 | 78.7% | 0 | 1,618.1 | 4.0 |
| | curve, traders wait for ≤ 15% | 116 | 172 | 171 | 78.7% | 0 | 1,892.2 | 2.9 |
| | curve, 20 ETH in the first hour | 45 | 184 | 184 | 78.7% | 0 | 2,028.9 | 5.4 |

What it shows:
- **The opening curve** matters most where trading is thin: with 0.5 ETH a day of trading it opens gameplay on day 1
  instead of day 257 (47 more Apes won and 505 ETH more buybacks over three years); with 10 ETH a day, day 1 instead of
  day 12. Where trading is heavy it changes nothing. The result depends on the first hour's volume (an assumption: 50
  ETH traded evenly); with 20 ETH, or traders waiting for the fee to fall, the thin-trading case opens on day 45 or 116.
- **The fee overflow** turns the trading the bid cannot use into buybacks: 2,916.9 of 3,013.3 ETH when trading is 150
  ETH a day against 0.5 of play, while buying 864 Apes against 868 without it; without it 2,849 ETH sits idle in the
  vault. At base flows it hardly triggers (0.2 ETH) and costs no Apes; with sudden popularity it sends 3,750 ETH with the
  same Apes bought and won. With little trading it never triggers.

## 11. What does not change with any parameter

Distributions never exceed realised profit; a carried loss blocks them; fee income never counts as profit; booked
revenue never exceeds what FWA paid; the vault's share of a distribution never exceeds what it lacks for one Ape, and
the rest always goes to the burner; keeper pay never exceeds the allowance earned (retirement included) and, while the
game runs, never uses cash owed to replacements; a milestone release needs a win FWA shows delivered to someone other
than the pool owner (an Ape exit, or a prize listed at the big-prize price or more), each listing releases once, or the
game's retirement; the fee overflow never takes the game's capital, its growth or the bid's ETH, and goes only to the
burner; the opening curve is fixed in the hook and never returns; no burner slice exceeds 1 ETH or moves the price more
than 5%, and slices are at least 10 minutes apart (except that the first slice after a non-empty release may run at once); no administrative call withdraws prizes, game cash or the
vault's funds to an address; with no keeper, purchases stop before collection exposure can pass its 50% ceiling; a won
Pack belongs to its winner; a pattern change never touches custody or a listed prize; a published Ape notional never
rises; in a sunset, everything handed to the Sunset goes to buy-and-burn. Permanent code (docs/SECURITY.md).

What the owner can change (D57, D63, D64, docs/ADMIN.md): the ordinary trading fees (`setFees`, up to 10% each way);
where future trading fees go (after a 72-hour notice, code pinned, and only before any migration or the sunset starts);
how much of each distribution goes to the vault rather than the burner (`continuityShareBps`, 0-100%) and how much of
the burner's share waits for a milestone (`setMilestoneBps`); the milestone tiers (`setTiers`) and the buyback cadence
(`setCadence`) within the burner's hard bounds; the fee overflow's share (`setOverflowBps`, 0-100%). Surplus has no other destination.
