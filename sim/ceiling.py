#!/usr/bin/env python3
"""A relative ceiling on the live bid (D60). Writes sim/results/ceiling.md.

The question: does a ceiling of `ceiling` x the last acquisition price (updated automatically at every acquisition,
no oracle) stop extreme overpayment without stalling acquisitions or creating new problems? Compared:

  uncapped        the D59 bid (FundingVault as built)
  hard 150%/200%  the meter stops at 150% (200%) of the last acquisition price; nothing above it until the next
                  acquisition or an owner change
  slow above 150% the meter runs at its normal rate (0.05 ETH per 300 blocks) up to 150% of the last price and at a
                  slow rate above it (0.005 or 0.01 ETH per 300 blocks): the bid still reaches any floor, later

Everything else is sim/bid.py's model (hourly, one year; one 300-block cooldown per hour; arbitrage sellers sell at
the bid once it clears the floor by 0.5%; the bid's funding is trading fees: 0.3 ETH a day, or 4.5 ETH a day from day
30 with "volume"). Added cases: the floor doubles or triples overnight or over 30 days; nobody sells for 30 days or
six months; a cartel of holders that sells only at the most the bid will pay (the ceiling, or 3x the floor uncapped),
which is the ratchet: every purchase at the ceiling raises the next ceiling.

Measured: Apes bought; mean and worst price over the floor; longest stall (days with no purchase while the funds
in the bid and vault could have bought at the floor), counted from day 30; whether acquisitions are stopped at the
end of the year (no purchase in the last 60 days although the funds could buy).

Run: python3 sim/ceiling.py
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bid import HOURS, MeteredBid, floor_path as base_floor  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


class CeilingBid(MeteredBid):
    """MeteredBid with a ceiling relative to the last acquisition price; above it, `slow` per cooldown (0: none)."""

    def __init__(self, ref, ceiling=0.0, slow=0.0, **kw):
        super().__init__(ref, **kw)
        self.last, self.ceiling, self.slow = ref, ceiling, slow

    def sweep(self, available):
        if not self.ceiling:
            return super().sweep(available)
        cap = self.ceiling * self.last
        taken = 0.0
        # fast fill to the threshold, never past the ceiling
        if self.bid < self.threshold:
            amount = min(available, self.threshold - self.bid, max(0.0, cap - self.bid))
            if amount > 0:
                taken += self._forward(amount, available)
        room = available - taken
        if self.bid >= self.threshold and room > 0:
            if self.bid < cap:
                amount = min(room, self.sweep_wei, cap - self.bid)
            else:
                amount = min(room, self.slow)
            if amount > 0:
                taken += self._forward(amount, room)
        return taken

    def _forward(self, amount, room):
        reward = min(amount * 0.005, 0.01)
        if room >= amount + reward:
            self.bid += amount
            self.rewards += reward
            return amount + reward
        self.bid += amount - reward
        self.rewards += reward
        return amount

    def bought(self, price):
        super().bought(price)
        self.last = price


def floor_path(name):
    if name in ("flat", "doubles", "halves", "crash", "volatile"):
        return base_floor(name, random.Random(6))
    f = []
    for h in range(HOURS):
        d = h / 24
        if name == "doubles overnight":
            v = 6.0 if d < 60 else 12.0
        elif name == "triples overnight":
            v = 6.0 if d < 60 else 18.0
        elif name == "triples":
            v = 6.0 if d < 60 else (18.0 if d > 90 else 6.0 * (1 + 2 * (d - 60) / 30))
        elif name == "+25% overnight":
            v = 6.0 if d < 60 else 7.5
        elif name == "+50% over a year":
            v = 6.0 * (1 + 0.5 * d / 365)
        elif name == "doubles, 6 months":
            v = 6.0 if d < 60 else (12.0 if d > 240 else 6.0 * (1 + (d - 60) / 180))
        else:
            raise ValueError(name)
        f.append(v)
    return f


def run(seller, floor_name, volume, ceiling=0.0, slow=0.0, sweep_wei=0.05):
    floor = floor_path(floor_name)
    inflow = (lambda d: 4.5 if d >= 30 else 0.3) if volume else (lambda d: 0.3)
    bid = CeilingBid(6.0, ceiling=ceiling, slow=slow, sweep_wei=sweep_wei)
    vault = 0.0
    paid, last_buy, stall, longest = [], 0, 0, 0
    for h in range(HOURS):
        d = h / 24
        vault += inflow(d) / 24
        vault -= bid.sweep(vault)
        b, f = bid.offer(), floor[h]
        absent = (seller == "absent 30 days" and 60 <= d < 90) or (seller == "absent 6 months" and 60 <= d < 240)
        price = None
        if absent or b <= 0:
            pass
        elif seller == "cartel":
            # sells only at the most the bid will pay: the ceiling (hard), or 3x the floor when uncapped / soft
            top = bid.ceiling * bid.last if (ceiling and not slow) else 3 * f
            if b >= min(top, 3 * f) * 0.999 and b >= f * 1.005:
                price = b
        elif b >= f * 1.005:
            price = b
        if price is not None:
            bid.bought(price)
            paid.append(price / f - 1)
            last_buy = h
        could = vault + bid.bid >= f * 1.005
        if d >= 30 and could and price is None:
            stall += 1
            longest = max(longest, stall)
        else:
            stall = 0
    could_end = vault + bid.bid >= floor[-1] * 1.005
    stopped = could_end and (HOURS - last_buy) > 60 * 24
    n = len(paid)
    return dict(n=n, mean=sum(paid) / n if n else 0.0, worst=max(paid) if n else 0.0, stall=longest / 24,
                stopped=stopped)


CASES = [
    ("arbitrage", "flat", False), ("arbitrage", "flat", True),
    ("arbitrage", "doubles", False), ("arbitrage", "doubles", True),
    ("arbitrage", "doubles overnight", False), ("arbitrage", "doubles overnight", True),
    ("arbitrage", "triples", True), ("arbitrage", "triples overnight", True),
    ("arbitrage", "doubles, 6 months", False),
    ("arbitrage", "halves", True), ("arbitrage", "crash", True), ("arbitrage", "volatile", True),
    ("absent 30 days", "flat", True), ("absent 6 months", "flat", True), ("absent 6 months", "flat", False),
    ("absent 30 days", "halves", True),
    ("absent 30 days", "doubles overnight", True),
    ("cartel", "flat", True), ("cartel", "flat", False),
]

VARIANTS = [
    ("uncapped (D59)", dict()),
    ("hard 150%", dict(ceiling=1.5)),
    ("hard 200%", dict(ceiling=2.0)),
    ("150%, then 0.0025/h", dict(ceiling=1.5, slow=0.0025)),
    ("150%, then 0.005/h", dict(ceiling=1.5, slow=0.005)),
    ("150%, then 0.01/h", dict(ceiling=1.5, slow=0.01)),
]


LOWER_CASES = [
    ("arbitrage", "flat", True), ("arbitrage", "+50% over a year", False), ("arbitrage", "+25% overnight", False),
    ("arbitrage", "+25% overnight", True), ("arbitrage", "doubles", False), ("arbitrage", "doubles", True),
    ("arbitrage", "doubles overnight", True), ("arbitrage", "halves", True),
    ("absent 30 days", "flat", True), ("absent 6 months", "flat", True), ("absent 30 days", "flat", False),
]

LOWER_VARIANTS = [
    ("uncapped", dict()),
    ("150% / 0.005", dict(ceiling=1.5, slow=0.005)),
    ("125% / 0.005", dict(ceiling=1.25, slow=0.005)),
    ("120% / 0.0025", dict(ceiling=1.2, slow=0.0025)),
    ("115% / 0.0025", dict(ceiling=1.15, slow=0.0025)),
    ("110% / 0.0025", dict(ceiling=1.1, slow=0.0025)),
    ("110% / 0.001", dict(ceiling=1.1, slow=0.001)),
    ("hard 120%", dict(ceiling=1.2)),
]


def table(cases, variants):
    rows = ["| sellers | floor | volume | " + " | ".join(v[0] for v in variants) + " |",
            "| --- | --- | --- | " + " | ".join("---" for _ in variants) + " |"]
    for seller, fl, vol in cases:
        cells = []
        for _, kw in variants:
            x = run(seller, fl, vol, **kw)
            cells.append(f"{x['n']} / {x['mean'] * 100:+.1f}% / {x['worst'] * 100:+.0f}% / {x['stall']:.0f}d"
                         + (" / **STOPPED**" if x["stopped"] else ""))
        rows.append(f"| {seller} | {fl} | {'yes' if vol else 'no'} | " + " | ".join(cells) + " |")
    return rows


def main():
    lines = ["# A relative ceiling on the live bid (sim/ceiling.py, D60)", "",
             "One year, hourly; the D59 live bid (threshold 75% of the last price, 0.05 ETH per 300 blocks above it). "
             "Funding 0.3 ETH a day of trading fees, or 4.5 ETH a day from day 30 (\"volume\"). Each cell: Apes bought / "
             "mean over the floor / worst over the floor / longest stall in days (no purchase while the funds could buy "
             "at the floor) / **STOPPED** when no purchase in the last 60 days although the funds could buy.", ""]
    lines.append("| sellers | floor | volume | " + " | ".join(v[0] for v in VARIANTS) + " |")
    lines.append("| --- | --- | --- | " + " | ".join("---" for _ in VARIANTS) + " |")
    for seller, fl, vol in CASES:
        cells = []
        for _, kw in VARIANTS:
            x = run(seller, fl, vol, **kw)
            cells.append(f"{x['n']} / {x['mean'] * 100:+.1f}% / {x['worst'] * 100:+.0f}% / {x['stall']:.0f}d"
                         + (" / **STOPPED**" if x["stopped"] else ""))
        lines.append(f"| {seller} | {fl} | {'yes' if vol else 'no'} | " + " | ".join(cells) + " |")
    lines += ["", "## Lower ceilings (D61: the owner does not want to pay 50% over)", "",
              "Same cells. Slow rates are ETH per 300 blocks above the ceiling (0.0025 ≈ 0.06 ETH a day, 1% of a 6 ETH "
              "price; 0.001 ≈ 0.024 ETH a day).", ""]
    lines += table(LOWER_CASES, LOWER_VARIANTS)
    lines.append("")
    out = "\n".join(lines) + "\n"
    with open(os.path.join(HERE, "results", "ceiling.md"), "w") as fh:
        fh.write(out)
    print(out)


if __name__ == "__main__":
    main()
