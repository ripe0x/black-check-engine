# FWA throughput on the Checks game: in-flight limit x board size

Generated from docs/receipts/throughput/k<K>-b<board>.json written by `test/scenario/Throughput.t.sol` (fast profile,
2026-11-04) on a fork at block 26,337,000 of the real FWA V2 pool and VRF service, with the Checks deployment (one
80-Check in the draw) and the launch board pattern (LaunchConfig `_boardPattern`; 50, 75 and 100 rows repeat it).
Every purchase through FWA's `acquireBatch` (singles and five-draw batches), 900 blocks (3 hours) per stream, the same
seeds for every configuration. `K` admits a purchase while fewer than K requests are unsettled. Completed = Fulfilled.
VRF lost: FWA keeps the VRF fee of a refunded or expired request (ETH at 1 gwei). The "Ape wins" column counts wins of
the collection prize, here the Check. All 12 configurations passed every assertion (books exact, the gate's bound).
Launch value K = 10 (collection-games D82): on the 50-row board 2.4% of issued requests refunded and 45.0% completion;
K = 3 refunds 0.6% at 39.7%.

| K | board | attempted | completed | completion | refused | refunded (of issued) | expired | max unsettled | VRF lost (ETH, 1 gwei) | keeper gas / completed | Ape wins |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 3 | 50 | 3594 | 1427 | 39.7% | 2152 | 9 (0.6%) | 6 | 7 | 0.029 | 814,483 | 1 |
| 4 | 50 | 3608 | 1465 | 40.6% | 2123 | 13 (0.9%) | 7 | 8 | 0.039 | 818,169 | 3 |
| 5 | 50 | 3594 | 1447 | 40.3% | 2124 | 17 (1.2%) | 6 | 9 | 0.045 | 824,603 | 3 |
| 10 | 50 | 3626 | 1632 | 45.0% | 1947 | 41 (2.4%) | 6 | 14 | 0.092 | 801,318 | 4 |
| 3 | 75 | 3641 | 1424 | 39.1% | 2210 | 0 (0.0%) | 7 | 7 | 0.014 | 808,099 | 2 |
| 4 | 75 | 3567 | 1419 | 39.8% | 2141 | 0 (0.0%) | 7 | 8 | 0.014 | 821,802 | 2 |
| 5 | 75 | 3460 | 1443 | 41.7% | 2010 | 0 (0.0%) | 7 | 9 | 0.014 | 816,920 | 2 |
| 10 | 75 | 3564 | 1676 | 47.0% | 1879 | 3 (0.2%) | 6 | 12 | 0.018 | 808,411 | 1 |
| 3 | 100 | 3594 | 1421 | 39.5% | 2166 | 0 (0.0%) | 7 | 7 | 0.014 | 782,977 | 0 |
| 4 | 100 | 3615 | 1461 | 40.4% | 2146 | 0 (0.0%) | 8 | 8 | 0.016 | 803,913 | 2 |
| 5 | 100 | 3492 | 1488 | 42.6% | 1998 | 0 (0.0%) | 6 | 9 | 0.012 | 799,384 | 0 |
| 10 | 100 | 3622 | 1727 | 47.7% | 1888 | 2 (0.1%) | 5 | 13 | 0.014 | 779,870 | 0 |

By stream (completed / refunded / refused):

| stream | K3 b50 | K4 b50 | K5 b50 | K10 b50 | K3 b75 | K4 b75 | K5 b75 | K10 b75 | K3 b100 | K4 b100 | K5 b100 | K10 b100 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| steady | 247/0/22 | 246/0/21 | 246/0/21 | 255/0/1 | 247/0/22 | 246/0/21 | 246/0/21 | 256/0/0 | 247/0/22 | 246/0/21 | 246/0/21 | 256/0/0 |
| bursts of 15 on one quote | 212/0/168 | 212/0/168 | 212/0/168 | 277/0/96 | 212/0/168 | 212/0/168 | 212/0/168 | 277/0/96 | 212/0/168 | 212/0/168 | 212/0/168 | 277/0/96 |
| delayed and missing VRF | 100/0/159 | 115/0/160 | 119/0/147 | 142/4/124 | 98/0/148 | 112/0/153 | 122/0/143 | 137/0/110 | 99/0/147 | 111/0/143 | 129/0/128 | 160/0/108 |
| heavy demand | 470/4/750 | 493/10/698 | 457/11/656 | 514/23/645 | 464/0/745 | 460/0/700 | 464/0/676 | 555/0/629 | 451/0/704 | 472/0/702 | 492/0/662 | 557/2/658 |
| heavy demand, FWA cooldown 5 min | 193/2/978 | 194/0/1001 | 208/3/1057 | 218/13/1016 | 209/0/1032 | 195/0/1004 | 205/0/907 | 255/3/952 | 208/0/1029 | 216/0/1016 | 205/0/923 | 276/0/946 |
| steady, lazy keeper (5 min) | 205/3/75 | 205/3/75 | 205/3/75 | 226/1/65 | 194/0/95 | 194/0/95 | 194/0/95 | 196/0/92 | 204/0/96 | 204/0/96 | 204/0/96 | 201/0/80 |

