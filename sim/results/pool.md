# Ape Draw with many Apes (sim/pool.py; D59 model, D64 launch values and mechanisms, D65 overflow trigger and K 3)

## 1. With k Apes (each bought at 6 ETH; gas 0.5 gwei)

Parameters: opening notional 100% of the price paid, minimum 25%, decay 10% of the price per 1x the price of gameplay credited to the Ape (an Ape reaches its minimum after 7.5x its price, 45 ETH, of credited gameplay), target 20%, reprice step 5%.
No Apes: FWA fee 0.018629 ETH, expected return 75.6% of FWA fee + VRF.

Fresh: every Ape at its opening notional. Decayed: every Ape at its minimum. Rows: ordinary rows the target needs (on demand; at least the 50-row opening board). Ape value: the Apes' expected value as a share of a draw's base value (FWA's EV). Gameplay per win: settled gameplay ETH per Ape won.

| Apes | Ape spend | state | ordinary rows | board capital | FWA fee | vs no Apes | player return | Ape value | an Ape per draw | gameplay per Ape win | gameplay until all decayed |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 6 | fresh | 50 | 1.67 | 0.019000 | +2.0% | 75.9% | 2.0% | 1 in 16,910 | 321 | 45 |
| 1 | 6 | decayed | 50 | 1.67 | 0.018997 | +2.0% | 81.2% | 7.8% | 1 in 4,228 | 80 | 45 |
| 5 | 30 | fresh | 50 | 1.67 | 0.020486 | +10.0% | 77.3% | 9.1% | 1 in 3,383 | 69 | 225 |
| 5 | 30 | decayed | 102 | 3.36 | 0.019493 | +4.6% | 89.1% | 18.7% | 1 in 1,729 | 34 | 225 |
| 10 | 60 | fresh | 50 | 1.67 | 0.022341 | +19.9% | 78.7% | 16.7% | 1 in 1,692 | 38 | 450 |
| 10 | 60 | decayed | 197 | 6.62 | 0.019629 | +5.4% | 89.6% | 19.3% | 1 in 1,661 | 33 | 450 |
| 20 | 120 | fresh | 87 | 3.08 | 0.023162 | +24.3% | 79.2% | 18.7% | 1 in 1,455 | 34 | 900 |
| 20 | 120 | decayed | 387 | 13.08 | 0.019630 | +5.4% | 89.9% | 19.7% | 1 in 1,633 | 32 | 900 |
| 50 | 300 | fresh | 207 | 6.77 | 0.022994 | +23.4% | 79.2% | 19.5% | 1 in 1,408 | 32 | 2,250 |
| 50 | 300 | decayed | 957 | 31.76 | 0.019568 | +5.0% | 90.0% | 19.9% | 1 in 1,621 | 32 | 2,250 |
| 100 | 600 | fresh | 407 | 13.44 | 0.023129 | +24.2% | 79.3% | 19.7% | 1 in 1,381 | 32 | 4,500 |
| 100 | 600 | decayed | 1,907 | 63.42 | 0.019583 | +5.1% | 90.0% | 19.9% | 1 in 1,614 | 32 | 4,500 |

Expected settled gameplay until the first win when k fresh Apes are listed together (uniform credit):

| Apes | first win (ETH of gameplay) | at 3 ETH/day | at 30 ETH/day |
| --- | --- | --- | --- |
| 1 | 103 | 34 days | 3.4 days |
| 5 | 57 | 19 days | 1.9 days |
| 10 | 36 | 12 days | 1.2 days |
| 20 | 34 | 11 days | 1.1 days |
| 50 | 33 | 11 days | 1.1 days |
| 100 | 33 | 11 days | 1.1 days |

### Target sensitivity (100 Apes)

| target | rows, fresh / decayed | board capital, fresh / decayed | FWA fee vs no Apes, fresh / decayed | player return, fresh / decayed | an Ape per draw | gameplay per win |
| --- | --- | --- | --- | --- | --- | --- |
| 5% | 1,907 / 7,907 | 63.4 / 263.3 | +5.2% / +1.2% | 76.5% / 79.2% | 1 in 6,687 | 126 |
| 10% | 907 / 3,907 | 30.1 / 130.1 | +10.9% / +2.5% | 77.4% / 82.8% | 1 in 3,305 | 63 |
| 15% | 574 / 2,574 | 18.8 / 85.4 | +17.1% / +3.8% | 78.3% / 86.4% | 1 in 2,178 | 42 |
| 20% | 407 / 1,907 | 13.4 / 63.4 | +24.2% / +5.1% | 79.3% / 90.0% | 1 in 1,614 | 32 |
| 25% | 307 / 1,507 | 10.1 / 50.1 | +32.0% / +6.5% | 80.2% / 93.7% | 1 in 1,276 | 25 |

### Opening and minimum notional (1 Ape on the 50-row board)

| opening / minimum | return fresh | return decayed | an Ape per draw, fresh | decayed | gameplay per win, decayed | rows per decayed Ape at the target |
| --- | --- | --- | --- | --- | --- | --- |
| 200% / 25% | 75.0% | 81.2% | 1 in 33,819 | 1 in 4,228 | 80 | 19 |
| 100% / 25% | 75.9% | 81.2% | 1 in 16,910 | 1 in 4,228 | 80 | 19 |
| 100% / 50% | 75.9% | 77.7% | 1 in 16,910 | 1 in 8,456 | 161 | 9 |
| 50% / 25% | 77.7% | 81.2% | 1 in 8,456 | 1 in 4,228 | 80 | 19 |
| 100% / 15% | 75.9% | 86.0% | 1 in 16,910 | 1 in 2,537 | 48 | 32 |

## 2. Three years, day by day

Live bid (sim/bid.py, Permanent Collection's model): first threshold 100% of the 6 ETH reference (D64), after each purchase 75% of its price; then 0.05 ETH per 300-block cooldown; arbitrage sellers take it at the floor + 0.5%; floor 6 ETH; 5% trading fee each way plus the opening curve's first hour (50 ETH traded evenly at an average 39%, 19.5 ETH); gas 0.5 gwei. Flows: trading volume / gameplay demand, ETH a day. Opening: gameplay starts only once the first Ape and then the 50-row board (1.67 ETH), the 1 ETH reserve and the 0.2 ETH opening keeper allowance are funded (day shown). Queue: Apes held but not yet listed (most at once, days with any waiting). Gas (0.5 gwei): Ape upkeep (listing, repricing) / growth (minting and listing added rows) / replacing won prizes. Keeper pay: gas + 10% within the allowance (5% of each captured prize's cost). Margin after keeper pay: 35% to the vault while it is short of one Ape, the rest to buybacks. Overflow: trading fees sent to buybacks by D1 (half the fees while the bid is at its threshold, never the bid's ETH or one more Ape at the last price: only ETH the rate-limited bid cannot use; D65).

| flows | rows | active from day | Apes bought (ETH) | won (value) | held at end (listed) | most queued (days) | ordinary rows at end | growth capital | player return | highest FWA fee | gas: Ape upkeep / growth / replacing | keeper pay | fee overflow | buybacks (incl. overflow) | sweep rewards |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| base (10 / 3) | on demand | 1 | 125 (757) | 91 (551) | 34 (34) | 0 (0) | 297 | 8.3 | 83.5% | 0.0214 | 0.04 / 0.10 / 49.3 ETH | 54.2 | 0.2 | 383.2 | 3.76 |
| base (10 / 3) | up front | 1 | 111 (671) | 48 (291) | 63 (63) | 0 (0) | 1,223 | 38.7 | 80.5% | 0.0199 | 0.04 / 0.49 / 55.0 ETH | 60.5 | 0.2 | 286.3 | 3.37 |
| trading >> gameplay (150 / 0.5) | on demand | 1 | 864 (5228) | 17 (103) | 847 (846) | 0 (0) | 3,436 | 113.0 | 79.2% | 0.0234 | 0.08 / 1.41 / 6.6 ETH | 7.2 | 2916.9 | 3013.3 | 15.19 |
| trading >> gameplay (150 / 0.5) | up front | 1 | 796 (4817) | 4 (24) | 792 (791) | 0 (0) | 15,036 | 499.5 | 76.5% | 0.0199 | 0.07 / 6.23 / 9.1 ETH | 10.1 | 2920.2 | 2968.4 | 14.17 |
| gameplay >> trading (0.5 / 30) | on demand | 1 | 194 (1175) | 193 (1169) | 1 (1) | 0 (0) | 50 | 0.0 | 78.8% | 0.0197 | 0.03 / 0.00 / 595.3 ETH | 654.8 | 0.0 | 2122.7 | 5.87 |
| gameplay >> trading (0.5 / 30) | up front | 1 | 194 (1175) | 193 (1169) | 1 (1) | 0 (0) | 64 | 0.3 | 78.6% | 0.0194 | 0.03 / 0.01 / 599.8 ETH | 659.8 | 0.0 | 2118.2 | 5.86 |
| sudden popularity (10 / 3, then 150 / 40) | on demand | 1 | 830 (5021) | 823 (4979) | 7 (6) | 0 (0) | 183 | 4.7 | 83.9% | 0.0209 | 0.23 / 0.06 / 694.8 ETH | 764.3 | 3750.2 | 8392.1 | 14.66 |
| sudden popularity (10 / 3, then 150 / 40) | up front | 1 | 829 (5016) | 722 (4368) | 107 (106) | 0 (0) | 2,173 | 70.4 | 82.6% | 0.0199 | 0.36 / 0.88 / 699.0 ETH | 768.9 | 3750.2 | 8224.3 | 14.64 |
| six months inactive (10 / 3, none days 120-300) | on demand | 1 | 104 (629) | 72 (436) | 32 (32) | 0 (0) | 297 | 8.3 | 83.7% | 0.0214 | 0.04 / 0.10 / 41.1 ETH | 45.3 | 0.2 | 319.6 | 3.14 |
| six months inactive (10 / 3, none days 120-300) | up front | 1 | 93 (563) | 36 (218) | 57 (57) | 0 (0) | 1,090 | 34.8 | 80.5% | 0.0199 | 0.03 / 0.43 / 45.9 ETH | 50.5 | 0.2 | 238.8 | 2.81 |

### What each flywheel mechanism adds (on demand)

Each row switches one mechanism off; the first row is the launch (D64 values, D65 overflow trigger, K 3).

| flows | variant | active from day | Apes bought | won | player return | fee overflow | buybacks | vault ETH idle at the end |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| base (10 / 3) | launch (D65) | 1 | 125 | 91 | 83.5% | 0.2 | 383.2 | 1.5 |
| base (10 / 3) | no opening curve (first hour at 5%) | 12 | 121 | 87 | 83.5% | 0.0 | 372.4 | 3.0 |
| base (10 / 3) | curve, traders wait for <= 15% (avg 12%) | 5 | 122 | 89 | 83.5% | 0.0 | 374.9 | 1.7 |
| base (10 / 3) | curve, 20 ETH in the first hour | 2 | 122 | 89 | 83.5% | 0.0 | 376.8 | 4.6 |
| base (10 / 3) | no fee overflow | 1 | 125 | 91 | 83.6% | 0.0 | 386.6 | 3.4 |
| base (10 / 3) | overflow only while an Ape the target held back waits | 1 | 125 | 91 | 83.6% | 0.0 | 386.6 | 3.4 |
| base (10 / 3) | overflow while the board has no room for one more Ape | 1 | 123 | 89 | 83.6% | 10.8 | 393.8 | 2.9 |
| base (10 / 3) | overflow by the D64 rule (an Ape waiting or 10 listed) | 1 | 112 | 87 | 83.7% | 68.5 | 435.9 | 4.9 |
| trading >> gameplay (150 / 0.5) | launch (D65) | 1 | 864 | 17 | 79.2% | 2916.9 | 3013.3 | 5.3 |
| trading >> gameplay (150 / 0.5) | no opening curve (first hour at 5%) | 1 | 864 | 17 | 79.2% | 2900.2 | 2996.3 | 5.3 |
| trading >> gameplay (150 / 0.5) | curve, traders wait for <= 15% (avg 12%) | 1 | 864 | 17 | 79.2% | 2903.7 | 2999.8 | 5.3 |
| trading >> gameplay (150 / 0.5) | curve, 20 ETH in the first hour | 1 | 864 | 17 | 79.2% | 2905.5 | 3001.6 | 5.3 |
| trading >> gameplay (150 / 0.5) | no fee overflow | 1 | 868 | 17 | 79.2% | 0.0 | 145.5 | 2849.1 |
| trading >> gameplay (150 / 0.5) | overflow only while an Ape the target held back waits | 1 | 868 | 17 | 79.2% | 0.0 | 145.5 | 2849.1 |
| trading >> gameplay (150 / 0.5) | overflow while the board has no room for one more Ape | 1 | 867 | 17 | 79.2% | 483.8 | 624.9 | 2375.9 |
| trading >> gameplay (150 / 0.5) | overflow by the D64 rule (an Ape waiting or 10 listed) | 1 | 805 | 17 | 79.2% | 3277.5 | 3374.3 | 9.2 |
| gameplay >> trading (0.5 / 30) | launch (D65) | 1 | 194 | 193 | 78.8% | 0.0 | 2122.7 | 6.5 |
| gameplay >> trading (0.5 / 30) | no opening curve (first hour at 5%) | 257 | 147 | 146 | 78.7% | 0.0 | 1618.1 | 4.0 |
| gameplay >> trading (0.5 / 30) | curve, traders wait for <= 15% (avg 12%) | 116 | 172 | 171 | 78.7% | 0.0 | 1892.2 | 2.9 |
| gameplay >> trading (0.5 / 30) | curve, 20 ETH in the first hour | 45 | 184 | 184 | 78.7% | 0.0 | 2028.9 | 5.4 |
| gameplay >> trading (0.5 / 30) | no fee overflow | 1 | 194 | 193 | 78.8% | 0.0 | 2122.7 | 6.5 |
| gameplay >> trading (0.5 / 30) | overflow only while an Ape the target held back waits | 1 | 194 | 193 | 78.8% | 0.0 | 2122.7 | 6.5 |
| gameplay >> trading (0.5 / 30) | overflow while the board has no room for one more Ape | 1 | 194 | 193 | 78.8% | 0.0 | 2122.7 | 6.5 |
| gameplay >> trading (0.5 / 30) | overflow by the D64 rule (an Ape waiting or 10 listed) | 1 | 194 | 193 | 78.8% | 0.0 | 2122.7 | 6.5 |

### Target sensitivity over three years (on demand)

| flows | target | Apes bought | won | ordinary rows at end | growth capital | player return | highest FWA fee | buybacks |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| base (10 / 3) | 15% | 120 | 78 | 497 | 14.9 | 82.1% | 0.0209 | 340.8 |
| base (10 / 3) | 20% | 125 | 91 | 297 | 8.3 | 83.5% | 0.0214 | 383.2 |
| base (10 / 3) | 25% | 129 | 101 | 201 | 5.0 | 84.9% | 0.0221 | 427.4 |
| trading >> gameplay (150 / 0.5) | 15% | 862 | 14 | 4,867 | 160.3 | 78.3% | 0.0221 | 2954.7 |
| trading >> gameplay (150 / 0.5) | 20% | 864 | 17 | 3,436 | 113.0 | 79.2% | 0.0234 | 3013.3 |
| trading >> gameplay (150 / 0.5) | 25% | 864 | 22 | 2,566 | 83.6 | 80.2% | 0.0248 | 3063.5 |
| sudden popularity (10 / 3, then 150 / 40) | 15% | 830 | 799 | 632 | 19.7 | 83.3% | 0.0207 | 8425.1 |
| sudden popularity (10 / 3, then 150 / 40) | 20% | 830 | 823 | 183 | 4.7 | 83.9% | 0.0209 | 8392.1 |
| sudden popularity (10 / 3, then 150 / 40) | 25% | 830 | 827 | 94 | 1.6 | 84.6% | 0.0210 | 8290.9 |

