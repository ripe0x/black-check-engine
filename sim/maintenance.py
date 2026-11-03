"""Maintenance funding over two years of changing gas (D59; keeper pay of D63, the 50-row board of D64). Writes
sim/results/maintenance.md.

Every draw that is won must be booked and its prize replaced. The game pays each useful call (D63):
    (measured gas + 70,000 overhead) x min(gas price, maxGasPrice 3 gwei) x 1.1
within the keeper allowance it earns (5% of each captured prize's cost, ALLOC per draw on average, plus the 0.2 ETH
opening allowance). What the allowance does not spend stays in the game as profit (continuity, then buybacks). When the
allowance cannot pay a call, the upkeep still happens: players' draws through the DrawRouter run it and pay the
difference themselves. Nothing stops; the question is who pays.

Two ways the upkeep is done:
  per draw     every player's draw runs `sync` through the DrawRouter (books and replaces about one draw; the site's
               default when the measured upkeep is light) and receives the payment
  batched      a keeper books and replaces ten draws per call

Gas per call is measured on the fork (docs/receipts/gas-prizes.json). Gas price = basefee + 0.02 gwei priority.

Run: python3 sim/maintenance.py
"""
import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from keepers import ALLOC, gas  # noqa: E402

DAYS = 730
DRAWS = 150  # a day
OVERHEAD = 70_000
MARGIN = 0.10
CAP = 3.0  # gwei
OPENING = 0.2
PRIORITY = 0.02


def gas_path(name, rng):
    if name == "low (0.2 gwei)":
        return [0.2] * DAYS
    if name == "rises to 2 gwei for good":
        return [0.2 if d < 180 else 2.0 for d in range(DAYS)]
    if name == "rises to 5 gwei for good":
        return [0.2 if d < 180 else 5.0 for d in range(DAYS)]
    if name == "spiky (0.3 gwei, 10x days)":
        return [3.0 if rng.random() < 0.05 else 0.3 for _ in range(DAYS)]
    x, base = math.log(0.3), []
    for _ in range(DAYS):
        x += rng.gauss(0, 0.08)
        x = min(max(x, math.log(0.05)), math.log(20))
        base.append(math.exp(x))
    return base


def run(path, batch):
    per_call = gas(batch) + 21_000  # what the caller's transaction costs in gas
    calls = DRAWS / batch
    allowance = OPENING
    paid = player = 0.0
    for b in path:
        price = b + PRIORITY
        allowance += ALLOC * DRAWS
        cost = calls * per_call * price * 1e-9
        due = calls * (gas(batch) + OVERHEAD) * min(price, CAP) * (1 + MARGIN) * 1e-9
        pay = min(allowance, due)
        allowance -= pay
        paid += pay
        player += max(0.0, cost - pay)  # upkeep not covered: paid by the players whose draws run it
    n = DRAWS * len(path)
    earned = OPENING + ALLOC * n
    return dict(paid=paid, player_per_draw=player / n, kept=earned - paid, allowance=allowance,
                margin_per_draw=(paid - sum(calls * per_call * (b + PRIORITY) * 1e-9 for b in path)) / n)


def main():
    rng = random.Random(3)
    names = ["low (0.2 gwei)", "spiky (0.3 gwei, 10x days)", "drifting", "rises to 2 gwei for good",
             "rises to 5 gwei for good"]
    paths = {n: gas_path(n, rng) for n in names}
    lines = ["# Maintenance funding (sim/maintenance.py; keeper pay of D63, the 50-row board of D64)", "",
             f"{DRAWS} draws a day for two years; keeper allowance {ALLOC:.6f} ETH per draw (5% of the average captured "
             f"prize's cost) plus {OPENING} ETH at opening; payment per useful call = (gas + {OVERHEAD:,}) x min(gas price, "
             f"{CAP:g} gwei) x {1 + MARGIN:.1f}, within the allowance. Keeper margin: payments less the callers' gas cost, "
             "per draw. Players pay: upkeep gas the allowance could not cover, per draw (paid by the players whose draws "
             "run it). Kept by the game: allowance earned but not paid out over two years (profit: continuity, then "
             "buybacks).", "",
             "| gas | upkeep | keeper margin per draw | players pay per draw | kept by the game | allowance left at end |",
             "| --- | --- | --- | --- | --- | --- |"]
    for name, path in paths.items():
        for label, batch in (("per draw (DrawRouter)", 1), ("batched x10 (keeper)", 10)):
            r = run(path, batch)
            lines.append(f"| {name} | {label} | {r['margin_per_draw']:.6f} ETH | {r['player_per_draw']:.6f} ETH | "
                         f"{r['kept']:.1f} ETH | {r['allowance']:.2f} ETH |")
    out = "\n".join(lines) + "\n"
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "results", "maintenance.md"), "w") as fh:
        fh.write(out)
    print(out)


if __name__ == "__main__":
    main()
