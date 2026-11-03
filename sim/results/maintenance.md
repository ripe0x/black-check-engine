# Maintenance funding (sim/maintenance.py; keeper pay of D63, the 50-row board of D64)

150 draws a day for two years; keeper allowance 0.000806 ETH per draw (5% of the average captured prize's cost) plus 0.2 ETH at opening; payment per useful call = (gas + 70,000) x min(gas price, 3 gwei) x 1.1, within the allowance. Keeper margin: payments less the callers' gas cost, per draw. Players pay: upkeep gas the allowance could not cover, per draw (paid by the players whose draws run it). Kept by the game: allowance earned but not paid out over two years (profit: continuity, then buybacks).

| gas | upkeep | keeper margin per draw | players pay per draw | kept by the game | allowance left at end |
| --- | --- | --- | --- | --- | --- |
| low (0.2 gwei) | per draw (DrawRouter) | 0.000038 ETH | 0.000000 ETH | 56.1 ETH | 56.12 ETH |
| low (0.2 gwei) | batched x10 (keeper) | 0.000016 ETH | 0.000000 ETH | 71.0 ETH | 70.98 ETH |
| spiky (0.3 gwei, 10x days) | per draw (DrawRouter) | 0.000078 ETH | 0.000000 ETH | 20.3 ETH | 20.33 ETH |
| spiky (0.3 gwei, 10x days) | batched x10 (keeper) | 0.000032 ETH | 0.000000 ETH | 51.6 ETH | 51.61 ETH |
| drifting | per draw (DrawRouter) | 0.000086 ETH | 0.000000 ETH | 15.0 ETH | 14.96 ETH |
| drifting | batched x10 (keeper) | 0.000035 ETH | 0.000000 ETH | 48.7 ETH | 48.71 ETH |
| rises to 2 gwei for good | per draw (DrawRouter) | -0.001041 ETH | 0.001073 ETH | -0.0 ETH | 0.00 ETH |
| rises to 2 gwei for good | batched x10 (keeper) | -0.000226 ETH | 0.000265 ETH | -0.0 ETH | 0.00 ETH |
| rises to 5 gwei for good | per draw (DrawRouter) | -0.003692 ETH | 0.003701 ETH | -0.0 ETH | 0.00 ETH |
| rises to 5 gwei for good | batched x10 (keeper) | -0.001710 ETH | 0.001714 ETH | -0.0 ETH | 0.00 ETH |
