#!/usr/bin/env python3
"""Checks Survival Protocol: economic model (Phase 3). Stdlib only, deterministic seeds.

Mechanics reproduced from verified sources and fork tests:
- FWA V2 selection: P(i) = (1/p_i) / sum(1/p); draw fee F = 1.05 * N / sum(1/p) (harmonic mean of notionals plus the
  5% edge). The owner keeps base + half the edge = 1.025 * N / sum(1/p); FWA keeps 0.025 * N / sum(1/p). The player
  also pays VRF = 1.95M gas * gas price (measured: 0.00195 ETH at 1 gwei).
- Survival: every draw that allocates a prize adds one survived draw to every listed Check that was not selected
  (src/game/SurvivalCursor.sol). Composition needs both Checks at `threshold` (Engine.drawsToCompose).
- Listing price per tier from a schedule the timelock updates (D003): here re-set to the market every `review_days`,
  effective 7 days later. Decay multiplies a Check's notional by (1 - decay) per survived draw down to `floor` of the
  schedule, applied in batches (FWA repricing needs an empty queue; each reprice costs gas).
- Shapes list at backing * (1 + shape_markup); a won Shape costs its backing plus the 0.001 ETH Shapes mint fee to
  replace.
- Trading fees on the coin (volume * fee share) fund Checks purchases at the market price of an 80 plus 5% slippage
  and fees, limited by `max_buys_per_week` (thin listing depth).
- Players: base demand (Poisson draws per day). Arbitrage players add draws whenever the expected market value per
  draw exceeds its full cost (fee + VRF) by 2%, re-checked after every draw, up to 300 per day.
Not modelled: coin price, liquidity depth, BLACK buyouts (their burns are a transfer of inventory, priced elsewhere),
legal constraints, FWA parameter changes beyond the scenario list.

Run: python3 sim/model.py            (writes sim/results/phase3.md)
     python3 sim/model.py --quick    (fewer runs, for a smoke check)
"""
import math
import os
import random
import sys

UNITS = [1, 2, 4, 8, 16, 32, 64, 4096]  # 80-equivalents per tier (divisorIndex 0..7)
NAMES = ["80", "40", "20", "10", "5", "4", "1", "Black"]
EDGE = 0.05
OWNER = 1.025
VRF_GAS = 1_950_000
SHAPE_FEE = 0.001
REVIEW_LAG = 7


def base_params():
    return dict(
        days=730,
        price80=0.25,  # ETH, Originals floor late October 2026
        premium=[1.0] * 8,  # market value per unit by tier, relative to an 80 (1.0 = no rarity premium)
        drift=0.0,  # yearly log drift of the Checks market
        vol=0.8,  # yearly volatility
        jump_day=None,
        jump=1.0,  # multiplier applied on jump_day
        start_checks=20,
        shapes=[0.01] * 20 + [0.02] * 10 + [0.05] * 5 + [0.1] * 2,  # board filler (backing, ETH)
        shape_markup=0.10,  # Shape notional = backing * (1 + markup)
        draws_per_day=25.0,
        gas_gwei=2.0,
        volume_per_day=20.0,  # coin trading volume, ETH
        fee_share=0.01,  # protocol share of volume
        max_buys_per_week=3,
        decay=0.002,  # per survived draw
        floor=0.6,  # lowest notional, share of schedule
        reprice_every=10,  # allocating draws between decay batches
        threshold=[150, 150, 150, 150, 150, 150, 300],
        composes_per_day=1,
        review_days=30,
        arbitrage=True,
        keeper_gas=dict(compose=600_000, reprice_per=45_000, cursor_per=0, list_per=180_000, buy=250_000),  # O(1) survival (C010)
    )


class Run:
    def __init__(self, P, seed):
        self.P = P
        self.rng = random.Random(seed)
        self.price80 = P["price80"]
        self.sched = [P["price80"] * UNITS[t] * P["premium"][t] for t in range(8)]
        self.pending_sched = None
        self.checks = []  # dicts: tier, mult (decay), survived
        for _ in range(P["start_checks"]):
            self.checks.append(dict(tier=0, mult=1.0, s=0))
        self.shapes = list(P["shapes"])
        self.ledger = dict(owner=0.0, fwa=0.0, shape_cost=0.0, check_value_won=0.0, check_notional_won=0.0,
                           checks_won=0, check_won_by_tier=[0] * 8, keeper=0.0, fees=0.0, buys=0, buy_eth=0.0,
                           composes=0, draws=0, arb_draws=0, max_tier=0, budget=0.0, first_single=None)
        self.since_reprice = 0
        self.dirty = True

    def value(self, tier):
        return self.price80 * UNITS[tier] * self.P["premium"][tier]

    def notional(self, c):
        return self.sched[c["tier"]] * c["mult"]

    def board(self):
        if self.dirty:
            self.items = [("c", i, self.notional(c)) for i, c in enumerate(self.checks)]
            self.items += [("s", j, b * (1 + self.P["shape_markup"])) for j, b in enumerate(self.shapes)]
            self.weights = [1.0 / it[2] for it in self.items]
            self.wsum = sum(self.weights)
            self.dirty = False
        return self.items

    def fee(self):
        self.board()
        return (1 + EDGE) * len(self.items) / self.wsum

    def player_ev_ratio(self):
        items = self.board()
        ev = 0.0
        for w, it in zip(self.weights, items):
            v = self.value(self.checks[it[1]]["tier"]) if it[0] == "c" else self.shapes[it[1]]
            ev += w * v
        ev /= self.wsum
        vrf = VRF_GAS * self.P["gas_gwei"] * 1e-9
        return ev / (self.fee() + vrf)

    def gas(self, units):
        self.ledger["keeper"] += units * self.P["gas_gwei"] * 1e-9

    def draw(self, arb):
        items = self.board()
        f = self.fee()
        L = self.ledger
        L["draws"] += 1
        L["arb_draws"] += arb
        base = len(items) / self.wsum
        L["owner"] += f - (f - base) / 2
        L["fwa"] += (f - base) / 2
        kind, idx, notional = self.rng.choices(items, weights=self.weights)[0]
        self.gas(self.P["keeper_gas"]["cursor_per"])
        if kind == "s":
            L["shape_cost"] += self.shapes[idx] + SHAPE_FEE  # replaced at once, same backing
        else:
            c = self.checks.pop(idx)
            L["checks_won"] += 1
            L["check_won_by_tier"][c["tier"]] += 1
            L["check_value_won"] += self.value(c["tier"])
            L["check_notional_won"] += notional
            self.dirty = True
        for c in self.checks:
            c["s"] += 1
        self.since_reprice += 1
        if self.since_reprice >= self.P["reprice_every"]:
            self.since_reprice = 0
            n = 0
            for c in self.checks:
                m = max(self.P["floor"], (1 - self.P["decay"]) ** c["s"])
                if m < c["mult"]:
                    c["mult"] = m
                    n += 1
            if n:
                self.gas(self.P["keeper_gas"]["reprice_per"] * n)
                self.dirty = True

    def compose(self, day):
        P = self.P
        done = 0
        for tier in range(6, -1, -1):
            while done < P["composes_per_day"]:
                ready = [c for c in self.checks if c["tier"] == tier and c["s"] >= P["threshold"][tier]]
                if tier == 6:
                    if len(ready) < 64:
                        break
                    keep = ready[0]
                    for c in ready[1:64]:
                        self.checks.remove(c)
                else:
                    if len(ready) < 2:
                        break
                    keep = ready[0]
                    self.checks.remove(ready[1])
                keep.update(tier=tier + 1, mult=1.0, s=0)
                self.ledger["composes"] += 1
                self.ledger["max_tier"] = max(self.ledger["max_tier"], tier + 1)
                if tier + 1 == 6 and self.ledger["first_single"] is None:
                    self.ledger["first_single"] = day
                self.gas(P["keeper_gas"]["compose"])
                self.dirty = True
                done += 1

    def day(self, d):
        P = self.P
        # market
        sigma = P["vol"] / math.sqrt(365)
        self.price80 *= math.exp(P["drift"] / 365 - sigma * sigma / 2 + sigma * self.rng.gauss(0, 1))
        if P["jump_day"] == d:
            self.price80 *= P["jump"]
        # timelocked schedule: proposed at review, effective 7 days later
        if d % P["review_days"] == 0:
            self.pending_sched = (d + REVIEW_LAG, [self.value(t) for t in range(8)])
        if self.pending_sched and self.pending_sched[0] == d:
            self.sched = self.pending_sched[1]
            self.pending_sched = None
            for c in self.checks:  # a schedule change is a fresh price; decay restarts from the new schedule
                c["mult"] = max(P["floor"], (1 - P["decay"]) ** c["s"])
            self.dirty = True
        # coin fees buy 80s
        L = self.ledger
        income = P["volume_per_day"] * P["fee_share"]
        L["fees"] += income
        L["budget"] += income
        if d % 7 == 0:
            for _ in range(P["max_buys_per_week"]):
                cost = self.price80 * 1.05
                if L["budget"] < cost:
                    break
                L["budget"] -= cost
                L["buys"] += 1
                L["buy_eth"] += cost
                self.checks.append(dict(tier=0, mult=1.0, s=0))
                self.gas(P["keeper_gas"]["buy"] + P["keeper_gas"]["list_per"])
                self.dirty = True
        # play
        n = self.poisson(P["draws_per_day"])
        for _ in range(n):
            self.draw(0)
        if P["arbitrage"]:
            k = 0
            while k < 300 and self.player_ev_ratio() > 1.02:
                self.draw(1)
                k += 1
        self.compose(d)

    def poisson(self, lam):
        if lam <= 0:
            return 0
        if lam > 50:
            return max(0, int(round(self.rng.gauss(lam, math.sqrt(lam)))))
        L, k, p = math.exp(-lam), 0, 1.0
        while True:
            p *= self.rng.random()
            if p <= L:
                return k
            k += 1

    def run(self):
        for d in range(1, self.P["days"] + 1):
            self.day(d)
        L = self.ledger
        held = [0] * 8
        for c in self.checks:
            held[c["tier"]] += 1
        held_value = sum(self.value(c["tier"]) for c in self.checks)
        game = L["owner"] - L["shape_cost"] - L["check_value_won"] - L["keeper"]
        return dict(L, held=held, held_value=held_value, price80=self.price80,
                    subsidy=L["check_value_won"] - L["check_notional_won"], game_pnl=game,
                    game_pnl_ex_checks=L["owner"] - L["shape_cost"] - L["check_notional_won"] - L["keeper"])


def stats(xs):
    xs = sorted(xs)
    n = len(xs)
    return xs[n // 2], xs[max(0, int(n * 0.1))], xs[min(n - 1, int(n * 0.9))]


SCENARIOS = [
    ("Base: 25 draws/day, 20 ETH/day coin volume, flat market", {}),
    ("Zero coin volume", dict(volume_per_day=0.0)),
    ("Low play: 5 draws/day", dict(draws_per_day=5.0)),
    ("High play: 100 draws/day", dict(draws_per_day=100.0)),
    ("High coin volume: 200 ETH/day", dict(volume_per_day=200.0)),
    ("Checks rally: +100%/yr drift", dict(drift=math.log(2))),
    ("Checks crash: -50%/yr drift", dict(drift=math.log(0.5))),
    ("Jump: market x3 on day 180", dict(jump_day=180, jump=3.0)),
    ("No decay (floor 1.0)", dict(floor=1.0)),
    ("Deep decay (floor 0.25)", dict(floor=0.25, decay=0.005)),
    ("Rarity premium x1.5 for tiers above 80", dict(premium=[1.0] + [1.5] * 7)),
    ("Fast composition: threshold 40", dict(threshold=[40] * 6 + [80])),
    ("No arbitrage players (deep decay)", dict(floor=0.25, decay=0.005, arbitrage=False)),
    ("Gas 20 gwei", dict(gas_gwei=20.0)),
    ("Gas 20 gwei with a draw-by-draw survival cursor (29k gas/draw)",
     dict(gas_gwei=20.0, keeper_gas=dict(compose=600_000, reprice_per=45_000, cursor_per=29_000, list_per=180_000,
                                         buy=250_000))),
    ("Shapes at exact backing (markup 0)", dict(shape_markup=0.0)),
    ("Shallow decay (floor 0.85)", dict(floor=0.85)),
    ("Recommended: floor 0.85, threshold 100, markup 10%", dict(floor=0.85, threshold=[100] * 6 + [200])),
]


def table(runs_by_scenario):
    out = ["| Scenario | Draws (arb %) | Checks won | Game P&L ETH (p10..p90) | Operating P&L ETH | Subsidy ETH | Coin fees ETH (unspent) | 80s bought | Composes | Max tier (p90) | P(single) | Checks held end (80/40/20/10/5/4/1) |",
           "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for name, rs in runs_by_scenario:
        draws = stats([r["draws"] for r in rs])[0]
        arb = stats([r["arb_draws"] / max(1, r["draws"]) for r in rs])[0]
        won = stats([r["checks_won"] for r in rs])[0]
        pnl = stats([r["game_pnl"] for r in rs])
        sub = stats([r["subsidy"] for r in rs])[0]
        fees = stats([r["fees"] for r in rs])[0]
        buys = stats([r["buys"] for r in rs])[0]
        comp = stats([r["composes"] for r in rs])[0]
        mt = stats([r["max_tier"] for r in rs])
        held = [stats([r["held"][t] for r in rs])[0] for t in range(7)]
        ops = stats([r["game_pnl_ex_checks"] for r in rs])[0]
        unspent = stats([r["budget"] for r in rs])[0]
        single = sum(1 for r in rs if r["max_tier"] >= 6) / len(rs)
        out.append(f"| {name} | {draws:,} ({arb:.0%}) | {won} | {pnl[0]:+.2f} ({pnl[1]:+.2f}..{pnl[2]:+.2f}) | "
                   f"{ops:+.2f} | {sub:.2f} | {fees:.1f} ({unspent:.1f}) | {buys} | {comp} | "
                   f"{NAMES[mt[0]]} ({NAMES[mt[2]]}) | {single:.0%} | {'/'.join(str(h) for h in held)} |")
    return "\n".join(out)


def exact_section():
    """Closed-form FWA economics for a board, independent of randomness."""
    lines = ["## Exact FWA economics (no randomness)", "",
             "For a board with notionals p_i and market values v_i: fee F = 1.05 N / S with S = sum(1/p); "
             "player expected value per draw = sum(v_i / p_i) / S; owner keeps 1.025 N / S. "
             "If every notional equals its value, the owner's expected margin is 2.5% of N/S per draw and players "
             "get 1/1.05 of the fee back in value (less VRF). A Check listed at a share a of its value adds "
             "(1/a - 1) to sum(v_i/p_i): draws turn positive expected value for players, so arbitrage, once",
             "sum over Checks of (1/a_k - 1) > 0.05 N + VRF/(N/S).", "",
             "| Board | Floor a at which every Check at floor makes draws break even for players (VRF ignored) |",
             "| --- | --- |"]
    for k, n in [(20, 57), (40, 77), (20, 30), (100, 137)]:
        a = k / (k + 0.05 * n)
        lines.append(f"| {k} Checks among {n} listings | {a:.3f} |")
    lines += ["", "Below that floor, the protocol pays a subsidy on every Check won and arbitrage players will draw "
              "until Checks leave. Above it, decay only shifts odds between prizes.", ""]
    return "\n".join(lines)


def main():
    quick = "--quick" in sys.argv
    runs = 8 if quick else 60
    results = []
    for name, over in SCENARIOS:
        P = base_params()
        P.update(over)
        rs = [Run(P, 1000 + i).run() for i in range(runs)]
        results.append((name, rs))
        print(f"{name}: done", file=sys.stderr)
    P = base_params()
    md = ["# Phase 3 economic model results", "",
          f"Generated by `python3 sim/model.py` ({runs} seeded runs per scenario, {P['days']} days). Medians unless "
          "stated. A model, not evidence about real behavior; parameters marked in sim/model.py `base_params`.", "",
          "Base: 20 Originals at 0.25 ETH, 37 Shapes (0.01-0.1 ETH backing), tier schedule reset to market monthly "
          "with a 7-day timelock, decay 0.2% per survived draw to 60% of schedule, composition at 150 survived "
          "draws (300 for Black), coin fee share 1% of volume buying 80s (max 3 per week), gas 2 gwei.", "",
          exact_section(), "## Simulated scenarios", "",
          "Game P&L = owner proceeds - Shape replacement - market value of Checks won - keeper gas (Checks won are "
          "inventory paid for by coin fees, so this is negative by design). Operating P&L counts Checks won at their "
          "notional instead: what draws earn or lose before the prize subsidy. Subsidy = market value of Checks won "
          "- their notional. Coin fees fund purchases separately; unspent = budget left by the purchase-depth limit. "
          "P(single) = share of runs that composed at least one single Check. No run formed a Black Check unless "
          "the max tier column says Black.", "",
          table(results), ""]
    here = os.path.dirname(os.path.abspath(__file__))
    os.makedirs(os.path.join(here, "results"), exist_ok=True)
    path = os.path.join(here, "results", "phase3.md")
    with open(path, "w") as f:
        f.write("\n".join(md))
    print(path)


if __name__ == "__main__":
    main()
