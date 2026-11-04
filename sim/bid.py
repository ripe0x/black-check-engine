#!/usr/bin/env python3
"""The vault's live bid against sellers and floors (D59). Writes sim/results/bid.md.

Two bids, hour by hour over one year:

metered (Permanent Collection's live bid, as adapted in FundingVault.sweep / sellToProtocol / fillOrder):
  - the bid is real ETH metered into it from the vault's spendable funds (trading fees, contributions, the
    continuity reserve, after the game's protected capital);
  - `sweep` (anyone; rewarded 0.5% of what it forwards, at most 0.01 ETH): while the bid is below the activation
    threshold, available ETH enters at once, up to the threshold; at or above it, at most `maxSweepWei` per cooldown;
  - an acquisition subtracts the price actually paid from the bid (unspent bid ETH stays) and resets the threshold to
    75% of that clearing price;
  - a holder accepting the bid names its price (at most the bid; a rational seller names the whole bid); a marketplace
    fill pays the listing's price plus a finder fee (0.5% of the bid, at most 0.01 ETH).

timed (the previous D57/D58 proposal): restarts at 80% of the last price after a purchase, then rises 20% of it a day
  from the level last recorded (hourly records), never above what the vault can pay.

Sellers (each hour, after the sweep):
  arbitrage   someone buys the floor listing and sells it to the vault once the bid clears the floor by 0.5%
              (marketplace cost and gas), at the bid
  strategic   30 holders with reservation prices floor x (1 + u), u uniform in [-2%, +30%]; the lowest waits until
              the bid reaches the second-lowest reservation (it cannot be undercut before), then sells at the bid
  thin        as strategic with every holder wanting 10-40% over the floor and no arbitrage
  fill        a keeper fills the floor listing through the marketplace adapter once the bid covers it: the vault pays
              the floor (metered: plus the finder fee)
  absent      arbitrage, but nobody sells from day 60 to day 90 (sweeps continue)

Floors: flat 6 ETH; doubles over 30 days (day 60); halves overnight (day 60); -60% in a week then recovers; volatile
(90%/yr). Funding: 3% fees on 10 ETH/day of trading (0.3 ETH/day); 150 ETH/day from day 30 ("sudden volume");
nothing at all for six months, days 60-240 ("inactive": no fees, no sweeps, no records).

Run: python3 sim/bid.py
"""
import math
import os
import random

HERE = os.path.dirname(os.path.abspath(__file__))
HOURS = 24 * 365
REWARD_BPS, REWARD_CAP = 0.005, 0.01  # sweep keeper reward and finder fee, as in Permanent Collection


class MeteredBid:
    """FundingVault's live bid. `sweep_wei` per cooldown; one cooldown per hour (300 blocks)."""

    def __init__(self, ref, threshold=0.75, sweep_wei=0.05, cap=0.0):
        self.bid = 0.0
        self.threshold = threshold * ref
        self.bps = threshold
        self.sweep_wei = sweep_wei
        self.cap = cap
        self.rewards = 0.0

    def sweep(self, available):
        """One hour of sweeps: a fast fill to the threshold (no cooldown), then one throttled forward. `available`
        is spendable ETH not yet in the bid. Returns ETH taken from `available` (forwards and rewards)."""
        taken = 0.0
        for fast in (True, False):
            room = available - taken
            if room <= 0:
                break
            if fast:
                if self.bid >= self.threshold:
                    continue
                amount = min(room, self.threshold - self.bid)
            else:
                if self.bid < self.threshold:
                    continue
                amount = min(room, self.sweep_wei)
            if self.cap:
                amount = min(amount, max(0.0, self.cap - self.bid))
            if amount <= 0:
                continue
            reward = min(amount * REWARD_BPS, REWARD_CAP)
            if room >= amount + reward:
                self.bid += amount
            else:
                self.bid += amount - reward
            self.rewards += reward
            taken += amount + reward if room >= amount + reward else amount
        return taken

    def offer(self):
        return self.bid

    def bought(self, price):
        self.bid -= price
        self.threshold = self.bps * price


class TimedBid:
    """The previous proposal: threshold 80% of the last price, +20% of it a day from the recorded level."""

    def __init__(self, ref, start=0.80, rate=0.20):
        self.ref, self.start, self.rate = ref, start, rate
        self.level = 0.0
        self.budget = 0.0
        self.rewards = 0.0

    def sweep(self, available_total):
        self.budget = available_total
        self.level = min(max(self.level, self.start * self.ref) + self.ref * self.rate / 24, available_total)
        return 0.0

    def offer(self):
        return min(self.level, self.budget)

    def bought(self, price):
        self.ref, self.level = price, 0.0


def floor_path(name, rng):
    f = []
    x = math.log(6.0)
    sigma = 0.9 / math.sqrt(24 * 365)
    for h in range(HOURS):
        d = h / 24
        if name == "doubles":
            v = 6.0 if d < 60 else (12.0 if d > 90 else 6.0 * (1 + (d - 60) / 30))
        elif name == "halves":
            v = 6.0 if d < 60 else 3.0
        elif name == "crash":
            v = 6.0 if d < 60 else (6.0 * (1 - 0.6 * (d - 60) / 7) if d < 67 else min(6.0, 2.4 + 3.6 * (d - 67) / 173))
        elif name == "volatile":
            x += rng.gauss(0, sigma)
            v = math.exp(x)
        else:
            v = 6.0
        f.append(v)
    return f


def funding(name):
    if name == "sudden volume":
        return lambda d: 4.5 if d >= 30 else 0.3
    if name == "inactive":
        return lambda d: 0.0 if 60 <= d < 240 else 0.3
    return lambda d: 0.3


def run(kind, seller, floor_name, fund_name, seed=5, **kw):
    floor = floor_path(floor_name, random.Random(seed + 1))
    inflow = funding(fund_name)
    lo, hi = (0.10, 0.40) if seller == "thin" else (-0.02, 0.30)
    holders = [random.Random(seed + 2 + i).uniform(lo, hi) for i in range(30)]
    rng = random.Random(seed)
    bid = MeteredBid(6.0, **kw) if kind == "metered" else TimedBid(6.0, **kw)
    vault = 0.0  # spendable ETH not in the metered bid (all spendable ETH for the timed bid)
    paid, idle = [], []
    for h in range(HOURS):
        d = h / 24
        vault += inflow(d) / 24
        active = not (fund_name == "inactive" and 60 <= d < 240)
        if active:
            if kind == "metered":
                vault -= bid.sweep(vault)
            else:
                bid.sweep(vault)
        b = bid.offer()
        f = floor[h]
        price = None
        present = not (seller == "absent" and 60 <= d < 90)
        if not active or not present or b <= 0:
            pass
        elif seller in ("arbitrage", "absent") and b >= f * 1.005:
            price = b
        elif seller == "fill":
            fee = min(b * REWARD_BPS, REWARD_CAP) if kind == "metered" else 0.0
            if b >= f + fee:
                price = f + fee
        elif seller in ("strategic", "thin"):
            res = sorted(f * (1 + u) for u in holders)
            if b >= res[1]:
                price = b
        if price is not None:
            if kind == "metered":
                bid.bought(price)
            else:
                vault -= price
                bid.bought(price)
            paid.append(price / f - 1)
            rng.shuffle(holders)
        idle.append(vault + (bid.bid if kind == "metered" else 0.0))
    n = len(paid)
    return dict(n=n, mean=sum(paid) / n if n else 0.0, worst=max(paid) if n else 0.0, idle=sum(idle) / len(idle),
                rewards=bid.rewards)


CASES = [
    ("arbitrage", "flat", "base"), ("arbitrage", "flat", "sudden volume"), ("absent", "flat", "sudden volume"),
    ("arbitrage", "doubles", "base"), ("arbitrage", "doubles", "sudden volume"), ("arbitrage", "halves", "base"),
    ("arbitrage", "halves", "sudden volume"), ("arbitrage", "crash", "sudden volume"),
    ("arbitrage", "volatile", "sudden volume"), ("arbitrage", "flat", "inactive"),
    ("strategic", "flat", "sudden volume"), ("strategic", "doubles", "sudden volume"), ("thin", "flat", "sudden volume"),
    ("fill", "volatile", "sudden volume"),
]

VARIANTS = [
    ("metered 0.01/h", "metered", dict(sweep_wei=0.01)),
    ("metered 0.025/h", "metered", dict(sweep_wei=0.025)),
    ("metered 0.05/h", "metered", dict(sweep_wei=0.05)),
    ("metered 0.1/h", "metered", dict(sweep_wei=0.1)),
    ("metered 0.25/h", "metered", dict(sweep_wei=0.25)),
    ("$111 literal 2/150 blocks", "metered", dict(sweep_wei=4.8)),
    ("timed 80% / +20%/day", "timed", dict()),
]


def main():
    lines = ["# The live bid against sellers and floors (sim/bid.py, D59)", "",
             "One year, hourly. Metered: Permanent Collection's live bid (threshold 75% of the last clearing price; "
             "above it `maxSweepWei` per 300-block cooldown, shown per hour). Timed: the previous proposal (80%, then "
             "+20% of the last price a day). Each cell: Apes bought / mean price over the floor / worst price over the "
             "floor / average ETH waiting (in the vault or the bid) / sweep rewards and finder fees paid.", ""]
    lines.append("| sellers | floor | funding | " + " | ".join(v[0] for v in VARIANTS) + " |")
    lines.append("| --- | --- | --- | " + " | ".join("---" for _ in VARIANTS) + " |")
    for seller, fl, fu in CASES:
        cells = []
        for _, kind, kw in VARIANTS:
            x = run(kind, seller, fl, fu, **kw)
            cells.append(f"{x['n']} / {x['mean'] * 100:+.1f}% / {x['worst'] * 100:+.1f}% / {x['idle']:.1f} / "
                         f"{x['rewards']:.2f}")
        lines.append(f"| {seller} | {fl} | {fu} | " + " | ".join(cells) + " |")
    lines.append("")
    out = "\n".join(lines) + "\n"
    with open(os.path.join(HERE, "results", "bid.md"), "w") as fh:
        fh.write(out)
    print(out)


if __name__ == "__main__":
    main()
