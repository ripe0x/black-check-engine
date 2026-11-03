"""Ape acquisition and treasury model: the vault's standing bid (FundingVault.currentBid/poke/_book) against a moving
market floor, with fee and margin inflows, Ape wins driven by gameplay, and the inventory and overflow rules under
review (docs/AUTONOMY_REVIEW.md).

Hourly steps over 18 months. Holders sell to the protocol when the bid reaches the floor minus what a marketplace
sale would cost them (0.5%); the bid is recorded every hour (a waiting seller, the DrawRouter or the keeper bot pokes).
Wins: the lead Ape is won at about 7 per 1,000 ETH of gameplay while an Ape is in the draw (docs/ECONOMICS.md); up to
`LISTED` Apes are in the draw at once, the rest wait in custody.

Variants (all with no bid cap):
  D57          restart 90% of the last price, +5%/day; buys whenever it can pay; vault ETH stays in the vault
  D57+rules    the same bid, plus "buy only to keep one Ape waiting" and "vault ETH above a buffer -> buybacks"
  80/20+rules  restart 80%, +20%/day, with both rules (recommended)
  70/10+rules  restart 70%, +10%/day, with both rules

Run: python3 sim/acquisition.py  (writes sim/results/acquisition.md)
"""

import math
import random

HOURS = 24 * 540
LISTED = 3  # Apes in the draw at once (listing strategy maxListed)
WINS_PER_ETH = 7.0 / 1000
HOLDER_DISCOUNT = 0.005  # a holder accepts the bid at floor x (1 - 0.5%): what a marketplace sale would cost them
MARGIN = 0.035  # share of gameplay ETH distributed (ECONOMICS: 36.6 per 1,000), 60% to continuity until target
CONT_SHARE = 0.6

VARIANTS = {
    "D57": dict(start=0.90, rise=0.05, demand_linked=False, overflow=False),
    "D57+rules": dict(start=0.90, rise=0.05, demand_linked=True, overflow=True),
    "80/20+rules": dict(start=0.80, rise=0.20, demand_linked=True, overflow=True),
    "70/10+rules": dict(start=0.70, rise=0.10, demand_linked=True, overflow=True),
}


def floor_path(name, rng):
    f = [6.0] * HOURS
    if name == "doubles":  # +100% over 30 days from day 60
        for h in range(HOURS):
            d = h / 24
            f[h] = 6.0 if d < 60 else (12.0 if d > 90 else 6.0 * (1 + (d - 60) / 30))
    elif name == "halves":  # -50% overnight on day 60
        for h in range(HOURS):
            f[h] = 6.0 if h < 60 * 24 else 3.0
    elif name == "crash_recover":  # -60% over a week on day 60, back to 6 by day 240
        for h in range(HOURS):
            d = h / 24
            if d < 60:
                f[h] = 6.0
            elif d < 67:
                f[h] = 6.0 * (1 - 0.6 * (d - 60) / 7)
            elif d < 240:
                f[h] = 2.4 + 3.6 * (d - 67) / 173
            else:
                f[h] = 6.0
    elif name == "volatile":  # geometric random walk, 90%/yr volatility
        sigma = 0.9 / math.sqrt(24 * 365)
        x = math.log(6.0)
        for h in range(HOURS):
            x += rng.gauss(0, sigma)
            f[h] = math.exp(x)
    return f


def flows(name):
    """ETH per day: (trading volume, gameplay) as a function of the day."""
    if name == "base":
        return lambda d: (10.0, 3.0)
    if name == "popular":  # sudden popularity from day 30
        return lambda d: (10.0, 3.0) if d < 30 else (150.0, 40.0)
    if name == "inactive":  # everything stops for six months from day 60, then resumes
        return lambda d: (10.0, 3.0) if d < 60 or d > 240 else (0.0, 0.0)
    if name == "trading_only":  # the coin trades heavily, few play
        return lambda d: (150.0, 0.5)
    if name == "play_only":  # many play, the coin barely trades
        return lambda d: (0.5, 30.0)
    return lambda d: (10.0, 3.0)


SCENARIOS = [
    ("steady floor, base flows", "flat", "base"),
    ("floor doubles over 30 days", "doubles", "base"),
    ("floor halves overnight", "halves", "base"),
    ("floor -60% in a week, recovers", "crash_recover", "base"),
    ("volatile floor (90%/yr)", "volatile", "base"),
    ("sudden popularity (15x)", "flat", "popular"),
    ("six months of inactivity", "flat", "inactive"),
    ("coin trades, few play", "flat", "trading_only"),
    ("many play, coin barely trades", "flat", "play_only"),
]


def run(variant, floor_name, flow_name, seed=7):
    v = VARIANTS[variant]
    rng = random.Random(seed)
    floor = floor_path(floor_name, random.Random(seed + 1))
    flow = flows(flow_name)
    general, continuity = 0.0, 0.0
    ref = 6.0
    level, updated = 0.0, 0
    listed, custody = 1, 0  # launch: one Ape in the draw
    bought, overpay, to_buybacks, apeless_hours = [], [], 0.0, 0
    idle_ape_value = []
    for h in range(HOURS):
        d = h / 24
        trade, play = flow(d)
        general += trade * 0.03 / 24
        margin = play * MARGIN / 24
        if continuity < ref:
            continuity += margin * CONT_SHARE
            to_buybacks += margin * (1 - CONT_SHARE)
        else:
            to_buybacks += margin
        # wins remove listed Apes; custody refills the draw
        if listed > 0 and rng.random() < play / 24 * WINS_PER_ETH:
            listed -= 1
        while listed < LISTED and custody > 0:
            custody -= 1
            listed += 1
        if listed == 0:
            apeless_hours += 1
        # the bid (FundingVault.currentBid with hourly pokes)
        budget = general + continuity
        wants = (custody < 1) if v["demand_linked"] else True
        if not wants:
            budget = 0.0
        start = ref * v["start"]
        bid = max(level, start) + ref * v["rise"] * min(h - updated, 1) / 24
        bid = min(bid, budget)
        level, updated = bid, h
        f = floor[h]
        if bid > 0 and bid >= f * (1 - HOLDER_DISCOUNT):
            spend_g = min(bid, general)
            general -= spend_g
            continuity -= bid - spend_g
            bought.append(bid)
            overpay.append(bid / f - 1)
            ref, level, updated = bid, 0.0, h
            if listed < LISTED:
                listed += 1
            else:
                custody += 1
        # vault ETH above a buffer (two Apes at the reference price) goes to buybacks
        if v["overflow"]:
            buffer = 2 * ref
            excess = general + continuity - buffer
            if excess > 0:
                take = min(excess, general)
                general -= take
                to_buybacks += take
        idle_ape_value.append(custody * f)
    n = len(bought)
    return {
        "apes": n,
        "mean_overpay": sum(overpay) / n if n else 0.0,
        "worst_overpay": max(overpay) if n else 0.0,
        "held_end": listed + custody,
        "custody_end": custody,
        "idle_value_end": idle_ape_value[-1],
        "vault_end": general + continuity,
        "buybacks": to_buybacks,
        "apeless_days": apeless_hours / 24,
    }


def main():
    lines = ["# Ape acquisition and treasury model (sim/acquisition.py)", "",
             "Hourly model over 540 days; bid recorded every hour; holders sell at the floor less 0.5%; no bid cap.",
             "Overpay = price paid / floor at that hour - 1. Idle: Apes waiting in custody beyond the one backup.",
             "Vault: ETH left in the vault at the end. Buybacks: margin to the router plus vault overflow (variants with",
             "the overflow rule). Ape-less: days with no Ape in the draw.", ""]
    for title, fl, fw in SCENARIOS:
        lines.append(f"## {title}")
        lines.append("")
        lines.append("| variant | Apes bought | mean overpay | worst overpay | Apes held at end (custody) | idle Ape value | vault ETH at end | to buybacks | Ape-less days |")
        lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
        for v in VARIANTS:
            r = run(v, fl, fw)
            lines.append(
                f"| {v} | {r['apes']} | {r['mean_overpay']*100:+.1f}% | {r['worst_overpay']*100:+.1f}% | "
                f"{r['held_end']} ({r['custody_end']}) | {r['idle_value_end']:.1f} | {r['vault_end']:.1f} | "
                f"{r['buybacks']:.1f} | {r['apeless_days']:.0f} |")
        lines.append("")
    out = "\n".join(lines) + "\n"
    with open("sim/results/acquisition.md", "w") as fh:
        fh.write(out)
    print(out)


if __name__ == "__main__":
    main()
