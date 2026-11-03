# Ape acquisition and treasury model (sim/acquisition.py)

Hourly model over 540 days; bid recorded every hour; holders sell at the floor less 0.5%; no bid cap.
Overpay = price paid / floor at that hour - 1. Idle: Apes waiting in custody beyond the one backup.
Vault: ETH left in the vault at the end. Buybacks: margin to the router plus vault overflow (variants with
the overflow rule). Ape-less: days with no Ape in the draw.

## steady floor, base flows

| variant | Apes bought | mean overpay | worst overpay | Apes held at end (custody) | idle Ape value | vault ETH at end | to buybacks | Ape-less days |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| D57 | 32 | -0.4% | -0.3% | 21 (18) | 108.0 | 4.8 | 22.7 | 11 |
| D57+rules | 15 | -0.4% | -0.3% | 4 (1) | 6.0 | 11.9 | 117.1 | 11 |
| 80/20+rules | 15 | -0.4% | -0.4% | 4 (1) | 6.0 | 11.9 | 117.1 | 11 |
| 70/10+rules | 15 | -0.4% | -0.4% | 4 (1) | 6.0 | 11.9 | 117.1 | 11 |

## floor doubles over 30 days

| variant | Apes bought | mean overpay | worst overpay | Apes held at end (custody) | idle Ape value | vault ETH at end | to buybacks | Ape-less days |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| D57 | 18 | -0.4% | -0.3% | 7 (4) | 48.0 | 1.2 | 22.7 | 11 |
| D57+rules | 15 | -0.4% | -0.3% | 4 (1) | 12.0 | 23.9 | 35.8 | 11 |
| 80/20+rules | 15 | -0.4% | -0.4% | 4 (1) | 12.0 | 23.9 | 36.9 | 11 |
| 70/10+rules | 15 | -0.4% | -0.4% | 4 (1) | 12.0 | 23.9 | 36.9 | 11 |

## floor halves overnight

| variant | Apes bought | mean overpay | worst overpay | Apes held at end (custody) | idle Ape value | vault ETH at end | to buybacks | Ape-less days |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| D57 | 62 | +0.1% | +28.7% | 51 (48) | 144.0 | 1.0 | 22.7 | 11 |
| D57+rules | 15 | +1.6% | +28.7% | 4 (1) | 3.0 | 6.0 | 158.0 | 11 |
| 80/20+rules | 15 | +1.7% | +29.1% | 4 (1) | 3.0 | 6.0 | 158.0 | 11 |
| 70/10+rules | 15 | +1.7% | +29.1% | 4 (1) | 3.0 | 6.0 | 158.0 | 11 |

## floor -60% in a week, recovers

| variant | Apes bought | mean overpay | worst overpay | Apes held at end (custody) | idle Ape value | vault ETH at end | to buybacks | Ape-less days |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| D57 | 38 | -0.4% | -0.3% | 27 (24) | 144.0 | 2.2 | 22.7 | 11 |
| D57+rules | 15 | -0.4% | -0.3% | 4 (1) | 6.0 | 12.0 | 124.1 | 11 |
| 80/20+rules | 15 | -0.4% | +0.1% | 4 (1) | 6.0 | 11.9 | 124.6 | 11 |
| 70/10+rules | 15 | -0.3% | -0.2% | 4 (1) | 6.0 | 12.0 | 124.4 | 11 |

## volatile floor (90%/yr)

| variant | Apes bought | mean overpay | worst overpay | Apes held at end (custody) | idle Ape value | vault ETH at end | to buybacks | Ape-less days |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| D57 | 30 | +0.1% | +2.7% | 19 (16) | 122.9 | 5.5 | 22.7 | 13 |
| D57+rules | 15 | +1.3% | +10.7% | 4 (1) | 7.7 | 11.8 | 114.7 | 13 |
| 80/20+rules | 15 | +0.2% | +1.8% | 4 (1) | 7.7 | 12.0 | 112.8 | 12 |
| 70/10+rules | 15 | +0.1% | +1.3% | 4 (1) | 7.7 | 11.9 | 115.6 | 12 |

## sudden popularity (15x)

| variant | Apes bought | mean overpay | worst overpay | Apes held at end (custody) | idle Ape value | vault ETH at end | to buybacks | Ape-less days |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| D57 | 255 | -0.4% | -0.4% | 108 (105) | 630.0 | 787.3 | 710.2 | 13 |
| D57+rules | 151 | -0.4% | -0.4% | 4 (1) | 6.0 | 12.0 | 2107.0 | 19 |
| 80/20+rules | 152 | +0.2% | +0.2% | 4 (1) | 6.0 | 9.0 | 2098.5 | 11 |
| 70/10+rules | 142 | -0.2% | -0.2% | 2 (0) | 0.0 | 12.0 | 2159.2 | 54 |

## six months of inactivity

| variant | Apes bought | mean overpay | worst overpay | Apes held at end (custody) | idle Ape value | vault ETH at end | to buybacks | Ape-less days |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| D57 | 21 | -0.4% | -0.3% | 12 (9) | 54.0 | 5.2 | 15.1 | 11 |
| D57+rules | 13 | -0.4% | -0.3% | 4 (1) | 6.0 | 11.9 | 56.2 | 11 |
| 80/20+rules | 13 | -0.4% | -0.4% | 4 (1) | 6.0 | 11.9 | 56.2 | 11 |
| 70/10+rules | 13 | -0.4% | -0.4% | 4 (1) | 6.0 | 11.9 | 56.2 | 11 |

## coin trades, few play

| variant | Apes bought | mean overpay | worst overpay | Apes held at end (custody) | idle Ape value | vault ETH at end | to buybacks | Ape-less days |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| D57 | 269 | -0.4% | -0.4% | 270 (267) | 1602.0 | 828.4 | 3.8 | 0 |
| D57+rules | 3 | -0.4% | -0.4% | 4 (1) | 6.0 | 12.0 | 2409.6 | 0 |
| 80/20+rules | 3 | -0.0% | -0.0% | 4 (1) | 6.0 | 12.0 | 2409.5 | 0 |
| 70/10+rules | 3 | -0.4% | -0.4% | 4 (1) | 6.0 | 12.0 | 2409.6 | 0 |

## many play, coin barely trades

| variant | Apes bought | mean overpay | worst overpay | Apes held at end (custody) | idle Ape value | vault ETH at end | to buybacks | Ape-less days |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| D57 | 53 | -0.4% | -0.4% | 0 (0) | 0.0 | 3.7 | 254.6 | 307 |
| D57+rules | 53 | -0.4% | -0.4% | 0 (0) | 0.0 | 3.7 | 254.6 | 307 |
| 80/20+rules | 58 | -0.1% | -0.1% | 1 (0) | 0.0 | 0.7 | 226.8 | 271 |
| 70/10+rules | 58 | -0.1% | -0.1% | 1 (0) | 0.0 | 0.7 | 226.8 | 271 |

