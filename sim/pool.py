#!/usr/bin/env python3
"""Ape Draw pool economics with many Apes (D59; launch values and mechanisms of D63-D64). Writes sim/results/pool.md.

Model of the contracts after D59 (src/core/CollectionPoolOwner.sol, src/game/CollectionGame.sol):
- Every Ape the vault holds is listed. It opens at `start` x its price and its notional falls linearly by `rate` x its
  price per 1x its price of gameplay credited to it, down to `minimum` x its price. Gameplay is credited evenly: each
  ETH of settled gameplay adds 1/k to every one of the k listed Apes (so k Apes decay k times slower than one).
- Pool-level target: Ape exposure, sum(price / notional) / listings, stays at or below `target`, with the purchase
  gate's in-flight headroom (7 listings at K = 3, D65) set aside. A listing or a decay step that would exceed it waits, and the
  board grows by the rows it needs ("on demand"), funded by the vault before it bids again; the board never shrinks
  and never falls below the 50-row opening board. The alternative ("up front": rows for every Ape at its minimum as
  soon as it is bought) is shown for comparison.
- FWA: weight 1/price; fee = 1.05 x listings / sum(1/price); P(listing) = (1/price) / sum(1/price).
  Ape wins per ETH of gameplay = sum(1/notional) / (1.05 x listings): independent of the Shapes' prices.
- Board: the 50-row pattern (D64, A4), repeated (prefixes keep its mix). Prize cost = backing + 0.001 ETH per Shape;
  FWA price = cost x 1.10 (10% markup).

Part 1 is exact (expected values). Part 2 runs the system day by day for three years under trading and gameplay
flows: fees fund the bid (sim/bid.py's mechanism with arbitrage sellers), board growth and the game; Apes are won at
the model's hazard; the game's margin, after keeper pay, goes 35% to the vault while it is short of an Ape and the rest
to buybacks. D64: the opening curve's first-hour fees and the fee overflow (D65 trigger: half of the trading fees to
buybacks while the bid is at its threshold, capped at what the vault holds beyond the bid and one more Ape at the last
price: only ETH the rate-limited bid cannot use) are modelled (the D64 play meter was removed in D65); the milestone tiers change only when buybacks happen, not how much.

Run: python3 sim/pool.py
"""
import math
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from economics import prize_cost, shape_count  # noqa: E402
from bid import MeteredBid  # noqa: E402

EDGE = 0.05
MARKUP = 0.10
OPS = 0.05
VRF_GAS = 1_950_000
HEADROOM = 7  # maxInFlight (3, D65) - 1 + a batch of 5
BASE_ROWS = 50
APE = 6.0  # ETH, price of every Ape in part 1

# launch parameters chosen from this model (docs/ECONOMICS.md, D59)
START = 1.00  # opening notional, share of the price paid
MINIMUM = 0.25  # lowest notional, share of the price paid
RATE = 0.10  # notional falls by 10% of the price per 1x the price of gameplay credited to the Ape
TARGET = 0.20  # Ape exposure target at full decay (D64, A3)
STEP = 0.05  # reprice when the notional falls by at least 5% (or reaches its minimum)

VALUES = [0.01, 0.02, 0.03, 0.04, 0.05, 0.1, 0.15, 0.5]
COUNTS = [24, 16, 3, 1, 3, 1, 1, 1]


def pattern():
    """LaunchConfig._interleave: each next row goes to the tier furthest behind its share."""
    placed = [0] * len(VALUES)
    out = []
    for _ in range(sum(COUNTS)):
        best = min((i for i in range(len(VALUES)) if placed[i] < COUNTS[i]),
                   key=lambda i: (2 * placed[i] + 1) / COUNTS[i])
        out.append(VALUES[best])
        placed[best] += 1
    return out


PATTERN = pattern()


class Board:
    """Running sums over the first `rows` rows of the repeated pattern."""

    def __init__(self, rows):
        self.rows = 0
        self.inv = 0.0  # sum(1/price)
        self.val = 0.0  # sum(backing/price)
        self.cost = 0.0  # capital at cost
        self.grow(rows)

    def grow(self, to):
        added = 0.0
        while self.rows < to:
            b = PATTERN[self.rows % len(PATTERN)]
            c = prize_cost(b)
            p = c * (1 + MARKUP)
            self.inv += 1 / p
            self.val += b / p
            self.cost += c
            added += c
            self.rows += 1
        return added


def rows_for(exposure_sum, k, target=TARGET):
    """Ordinary rows that hold Apes with sum(price/notional) = exposure_sum (k of them) within the target."""
    if k == 0:
        return BASE_ROWS
    return max(BASE_ROWS, math.ceil(exposure_sum / target - 1e-9) + HEADROOM - k)


def rows_wanted(k, target=TARGET, minimum=MINIMUM):
    """Up front: rows for k Apes all at their minimum."""
    return rows_for(k / minimum, k, target)


def draw(board, notionals, refs, gwei=0.5):
    """Expected figures for one draw with the board and Apes at `notionals` (refs: their prices)."""
    n = board.rows + len(notionals)
    s = board.inv + sum(1 / x for x in notionals)
    fee = (1 + EDGE) * n / s
    vrf = VRF_GAS * gwei * 1e-9
    value = board.val + sum(r / x for r, x in zip(refs, notionals))
    ret = value / ((1 + EDGE) * n)  # of the FWA fee
    p_ape = sum(1 / x for x in notionals) / s
    wins_per_eth = sum(1 / x for x in notionals) / ((1 + EDGE) * n)
    exposure = sum(r / x for r, x in zip(refs, notionals)) / n
    return dict(fee=fee, all_in=fee + vrf, ret=ret * fee / (fee + vrf), p_ape=p_ape, wins_per_eth=wins_per_eth,
                exposure=exposure, n=n)


def notional(ref, credited, start=START, minimum=MINIMUM, rate=RATE):
    return ref * max(minimum, start - rate * credited / ref)


def first_win_gameplay(k, start=START, minimum=MINIMUM, rate=RATE, ref=APE, target=TARGET):
    """Expected settled gameplay (ETH) until the first of k fresh Apes, listed together, is won (uniform credit;
    the board grows on demand as they decay)."""
    full = (start - minimum) / rate * ref * k  # gameplay until every Ape reaches its minimum
    g, surv, expect, dg = 0.0, 1.0, 0.0, max(0.05, full / 4000)
    while surv > 1e-6 and g < 1e6:
        x = notional(ref, g / k, start, minimum, rate)
        n = rows_for(k * ref / x, k, target) + k
        lam = k / x / ((1 + EDGE) * n)
        expect += surv * dg
        surv *= math.exp(-lam * dg)
        g += dg
    return expect


def part1(out):
    base = Board(BASE_ROWS)
    b0 = draw(base, [], [])
    out += ["## 1. With k Apes (each bought at 6 ETH; gas 0.5 gwei)", "",
            f"Parameters: opening notional {START:.0%} of the price paid, minimum {MINIMUM:.0%}, decay {RATE:.0%} of the "
            f"price per 1x the price of gameplay credited to the Ape (an Ape reaches its minimum after "
            f"{(START - MINIMUM) / RATE:.1f}x its price, {(START - MINIMUM) / RATE * APE:.0f} ETH, of credited "
            f"gameplay), target {TARGET:.0%}, reprice step {STEP:.0%}.",
            f"No Apes: FWA fee {b0['fee']:.6f} ETH, expected return {b0['ret']:.1%} of FWA fee + VRF.", "",
            "Fresh: every Ape at its opening notional. Decayed: every Ape at its minimum. Rows: ordinary rows the target "
            "needs (on demand; at least the 50-row opening board). Ape value: the Apes' expected value as a share of a "
            "draw's base value (FWA's EV). Gameplay per win: settled gameplay ETH per Ape won.", "",
            "| Apes | Ape spend | state | ordinary rows | board capital | FWA fee | vs no Apes | player return | Ape value | an Ape per draw | gameplay per Ape win | gameplay until all decayed |",
            "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for k in (1, 5, 10, 20, 50, 100):
        refs = [APE] * k
        for state, x in (("fresh", START * APE), ("decayed", MINIMUM * APE)):
            b = Board(rows_for(k * APE / x, k))
            d = draw(b, [x] * k, refs)
            full = (START - MINIMUM) / RATE * APE * k
            out.append(
                f"| {k} | {k * APE:.0f} | {state} | {b.rows:,} | {b.cost:.2f} | {d['fee']:.6f} | {d['fee'] / b0['fee'] - 1:+.1%} | "
                f"{d['ret']:.1%} | {d['exposure']:.1%} | 1 in {1 / d['p_ape']:,.0f} | {1 / d['wins_per_eth']:,.0f} | "
                f"{full:,.0f} |")
    out += ["", "Expected settled gameplay until the first win when k fresh Apes are listed together (uniform credit):", "",
            "| Apes | first win (ETH of gameplay) | at 3 ETH/day | at 30 ETH/day |", "| --- | --- | --- | --- |"]
    for k in (1, 5, 10, 20, 50, 100):
        g = first_win_gameplay(k)
        out.append(f"| {k} | {g:,.0f} | {g / 3:,.0f} days | {g / 30:,.1f} days |")
    out += ["", "### Target sensitivity (100 Apes)", "",
            "| target | rows, fresh / decayed | board capital, fresh / decayed | FWA fee vs no Apes, fresh / decayed | player return, fresh / decayed | an Ape per draw | gameplay per win |",
            "| --- | --- | --- | --- | --- | --- | --- |"]
    for t in (0.05, 0.10, 0.15, 0.20, 0.25):
        bf = Board(rows_for(100 / START, 100, t))
        bd = Board(rows_for(100 / MINIMUM, 100, t))
        f = draw(bf, [START * APE] * 100, [APE] * 100)
        d = draw(bd, [MINIMUM * APE] * 100, [APE] * 100)
        out.append(f"| {t:.0%} | {bf.rows:,} / {bd.rows:,} | {bf.cost:.1f} / {bd.cost:.1f} | "
                   f"{f['fee'] / b0['fee'] - 1:+.1%} / {d['fee'] / b0['fee'] - 1:+.1%} | {f['ret']:.1%} / {d['ret']:.1%} | "
                   f"1 in {1 / d['p_ape']:,.0f} | {1 / d['wins_per_eth']:,.0f} |")
    out += ["", "### Opening and minimum notional (1 Ape on the 50-row board)", "",
            "| opening / minimum | return fresh | return decayed | an Ape per draw, fresh | decayed | gameplay per win, decayed | rows per decayed Ape at the target |",
            "| --- | --- | --- | --- | --- | --- | --- |"]
    for s_, m in ((2.0, 0.25), (1.0, 0.25), (1.0, 0.5), (0.5, 0.25), (1.0, 0.15)):
        f = draw(base, [s_ * APE], [APE])
        dd = draw(base, [m * APE], [APE])
        out.append(f"| {s_:.0%} / {m:.0%} | {f['ret']:.1%} | {dd['ret']:.1%} | 1 in {1 / f['p_ape']:,.0f} | "
                   f"1 in {1 / dd['p_ape']:,.0f} | {1 / dd['wins_per_eth']:,.0f} | {1 / (m * TARGET) - 1:.0f} |")
    out.append("")


# ---------------------------------------------------------------------------------------------- part 2: dynamics

FEE = 0.05  # trading fee, each way (D64, A1)
ARB = 0.005  # an arbitrageur sells to the vault once the bid clears the floor by 0.5% (marketplace cost + gas)
THRESHOLD = 0.75  # the live bid's activation threshold after an acquisition, share of its clearing price
FIRST_THRESHOLD = 1.00  # the first threshold, share of the reference (D64, A6)
SWEEP_WEI = 0.05  # ETH entering the bid per 300-block cooldown above the threshold (one an hour)
OVERFLOW = 0.50  # D64, D1: fee share to buybacks, beyond the bid and the next Ape (D65)
CONT_SHARE = 0.35  # D64, A5
RESERVE = 1.0  # the game's operating reserve (D64, A4)
OPENING_ALLOWANCE = 0.2  # keeper pay before any capture, funded with the board (D63)
KEEPER_MARGIN = 0.10  # keepers are paid their gas + 10% (D63), within the allowance
LAUNCH_VOLUME = 50.0  # ETH traded in the first hour (D64, B: the opening curve, 69% falling a point a minute)
LAUNCH_FEE_AVG = 0.39  # the curve's average fee when that volume comes evenly over minutes 0-60 (docs/review/flywheel/curve.py)
GAS_GWEI = 0.5
# gas (fork measures, docs/receipts/gas.json; per item inside a sync)
GAS_REPRICE = 45_000  # one FWA updatePrice
GAS_LIST_APE = 180_000  # one Ape listed (FWA escrow + records)
GAS_LIST_ROW = 831_000  # minting and listing one prize (sync_fund_and_list_a_batch_of_8 / 8, D61)
GAS_REPLACE = 690_000  # booking and replacing one won prize (ten per call)


def flows(name):
    return {
        "base (10 / 3)": lambda d: (10.0, 3.0),
        "trading >> gameplay (150 / 0.5)": lambda d: (150.0, 0.5),
        "gameplay >> trading (0.5 / 30)": lambda d: (0.5, 30.0),
        "sudden popularity (10 / 3, then 150 / 40)": lambda d: (10.0, 3.0) if d < 60 else (150.0, 40.0),
        "six months inactive (10 / 3, none days 120-300)": lambda d: (10.0, 3.0) if d < 120 or d > 300 else (0.0, 0.0),
    }[name]


def run(name, days=1095, seed=11, target=TARGET, upfront=False, launch_volume=LAUNCH_VOLUME,
        launch_fee=LAUNCH_FEE_AVG, overflow=OVERFLOW, trigger="idle"):
    """Day by day (the bid hour by hour). The contracts' order: before activation the vault spends everything on the
    first Ape; the game activates only once the opening board, the operating reserve and the opening keeper allowance
    are funded from fees (no gameplay before); afterwards the vault keeps the game's capital need and the board growth
    the Apes are waiting for before ETH enters the bid."""
    rng = random.Random(seed)
    flow = flows(name)
    general, buybacks = 0.0, 0.0
    board = Board(BASE_ROWS)
    bid = MeteredBid(APE, THRESHOLD, SWEEP_WEI)
    bid.threshold = FIRST_THRESHOLD * APE
    overflowed = 0.0
    held_back = 0  # Apes the target held back at the last listing pass (CollectionPoolOwner.waitingForRows)
    apes = []  # [price, credited gameplay, published notional]
    queue = []  # prices of Apes held but not yet listed
    bought = spend = wins = 0
    won_value = 0.0
    reprices = deferred_days = 0
    ape_gas = growth_gas = replace_gas = 0.0
    max_queue = queue_days = 0
    ret_acc = played = demand = 0.0
    max_fee = 0.0
    growth_capital = 0.0
    allowance = OPENING_ALLOWANCE
    keeper_paid = 0.0
    opened = False  # the first Ape is held
    active = False  # activated: gameplay possible
    activation_day = None
    last_price = APE
    for day in range(days):
        trade, play = flow(day)
        fees = trade * FEE + (launch_volume * launch_fee if day == 0 else 0.0)
        general += fees
        # D64, D1 (D65 trigger "idle", the launch): while the bid is at its threshold, half the fees buy back the coin,
        # never the bid's ETH or the next Ape. The others are the rules compared in the variants table.
        if trigger == "held_back":  # an Ape the target held back at the last listing pass still waits
            fire = held_back and queue
        elif trigger == "no_room":  # the board as it is has no room under the target for one more Ape
            fire = (sum(a[0] / a[2] for a in apes) + len(queue) / START + 1 / START
                    > target * (board.rows + len(apes) + len(queue) + 1 - HEADROOM))
        elif trigger == "idle":  # more than one Ape's price idle beyond the bid (the bid is rate-limited)
            fire = general - bid.bid >= last_price
        else:  # "listed10": D64's rule
            fire = queue or len(apes) >= 10
        if overflow and active and bid.bid >= bid.threshold and fire:
            keep = last_price if trigger == "idle" else 0.0  # the idle trigger keeps one Ape's price beyond the bid
            ov = min(fees * overflow, max(0.0, general - bid.bid - keep))
            general -= ov
            buybacks += ov
            overflowed += ov
        demand += play
        if opened and not active and general >= board.cost + RESERVE + OPENING_ALLOWANCE:
            general -= board.cost + RESERVE + OPENING_ALLOWANCE
            active, activation_day = True, day
        if active:
            # rows the target needs: up front (every Ape at its minimum) or on demand (published notionals, queued
            # Apes at their opening, and the decay due now)
            if upfront:
                want = rows_wanted(len(apes) + len(queue), target)
            else:
                ex = sum(a[0] / max(notional(a[0], a[1]), MINIMUM * a[0]) for a in apes) + len(queue) / START
                want = rows_for(ex, len(apes) + len(queue), target)
            if want > board.rows:
                grow_to = min(want, board.rows + 50 * 24)  # 50 rows a maintenance, ~hourly
                cost_est = (grow_to - board.rows) * board.cost / board.rows
                if general >= cost_est:  # growth comes before the bid (the vault's budget excludes it)
                    rows0 = board.rows
                    added = board.grow(grow_to)
                    general -= added
                    growth_capital += added
                    growth_gas += (board.rows - rows0) * GAS_LIST_ROW
            # list queued Apes while the target allows (batches; no FWA limit binds at this pace)
            n = board.rows + len(apes)
            ex = sum(a[0] / a[2] for a in apes)
            while queue and (ex + 1 / START) <= target * (n + 1 - HEADROOM):
                r = queue.pop()
                apes.append([r, 0.0, START * r])
                ape_gas += GAS_LIST_APE
                ex += 1 / START
                n += 1
            held_back = len(queue)
            if queue:
                queue_days += 1
            max_queue = max(max_queue, len(queue))
        # the live bid (sweeps hourly; arbitrage sellers at the floor + 0.5%)
        for _ in range(24):
            if not opened:
                spendable = general  # before activation: everything, for the first Ape
            elif not active:
                spendable = 0.0
            else:
                reserve = 0.0
                if not upfront:
                    ex = sum(a[0] / a[2] for a in apes) + len(queue) / START
                    short = rows_for(ex, len(apes) + len(queue), target) - board.rows
                    reserve = max(0, short) * board.cost / board.rows
                spendable = max(0.0, general - reserve)
            bid.bid = min(bid.bid, spendable)  # the game's capital and growth come first: the bid is clamped
            available = max(0.0, spendable - bid.bid)
            paid_before = bid.rewards
            bid.sweep(available)
            # sweep rewards leave the vault; forwards stay in it (the bid is accounted inside the vault)
            general -= bid.rewards - paid_before
            if bid.offer() >= APE * (1 + ARB) and (active or not opened):
                price = bid.offer()
                general -= price
                bid.bought(price)
                last_price = price
                bought += 1
                spend += price
                queue.append(price)
                opened = True
        if not active:
            continue
        k = len(apes)
        if play <= 0:
            continue
        # gameplay: credit evenly, decay within the target, wins
        if k:
            n = board.rows + k
            ex = sum(a[0] / a[2] for a in apes)
            deferred = False
            for a in apes:
                a[1] += play / k
                want_n = notional(a[0], a[1])
                if want_n <= a[2] * (1 - STEP) or (want_n == MINIMUM * a[0] and a[2] > want_n):
                    delta = a[0] / want_n - a[0] / a[2]
                    if ex + delta <= target * (n - HEADROOM):
                        ex += delta
                        a[2] = want_n
                        reprices += 1
                        ape_gas += GAS_REPRICE
                    else:
                        deferred = True
            deferred_days += deferred
        d = draw(board, [a[2] for a in apes], [a[0] for a in apes], GAS_GWEI)
        max_fee = max(max_fee, d["fee"])
        ret_acc += d["ret"] * play
        played += play
        # Ape wins: Poisson at the hazard, in small slices
        slices = max(1, int(play * 20))
        for _ in range(slices):
            if not apes:
                break
            lam = sum(1 / a[2] for a in apes) / ((1 + EDGE) * (board.rows + len(apes)))
            if rng.random() < lam * play / slices:
                weights = [1 / a[2] for a in apes]
                won = apes.pop(rng.choices(range(len(apes)), weights)[0])
                won_value += won[0]
                wins += 1
        # the game's margin per ETH of gameplay: owner proceeds less Shape prizes and keeper pay (D63: gas + 10%,
        # within the allowance the captures earn, OPS of each captured prize's cost)
        n = board.rows + len(apes)
        s_ = board.inv + sum(1 / a[2] for a in apes)
        fee = (1 + EDGE) * n / s_
        draws = play / fee
        proceeds = (n / s_) * (1 + EDGE / 2)
        shape_cost = (board.rows / (1 + MARKUP)) / s_
        margin = (proceeds - shape_cost) / fee * play
        allowance += OPS * shape_cost * draws
        upkeep = draws * (board.rows / n) * GAS_REPLACE
        replace_gas += upkeep
        pay = min(allowance, upkeep * GAS_GWEI * 1e-9 * (1 + KEEPER_MARGIN))
        allowance -= pay
        keeper_paid += pay
        margin -= pay
        if margin > 0:
            short = max(0.0, last_price - max(0.0, general - bid.bid))  # the vault's shortfall of one Ape
            to_c = min(margin * CONT_SHARE, short)
            general += to_c
            buybacks += margin - to_c
    g = GAS_GWEI * 1e-9
    return dict(bought=bought, spend=spend, held=len(apes) + len(queue), listed=len(apes), queue=len(queue),
                max_queue=max_queue, queue_days=queue_days, wins=wins, won_value=won_value, rows=board.rows,
                growth=growth_capital, reprices=reprices, deferred_days=deferred_days, ape_gas=ape_gas * g,
                growth_gas=growth_gas * g, replace_gas=replace_gas * g, ret=ret_acc / played if played else 0.0,
                played=played, demand=demand, max_fee=max_fee, buybacks=buybacks, vault=general,
                activation_day=activation_day, sweep_rewards=bid.rewards, keeper_paid=keeper_paid,
                overflowed=overflowed, vault_end=general)


SCEN = ("base (10 / 3)", "trading >> gameplay (150 / 0.5)", "gameplay >> trading (0.5 / 30)",
        "sudden popularity (10 / 3, then 150 / 40)", "six months inactive (10 / 3, none days 120-300)")


def part2(out):
    out += ["## 2. Three years, day by day", "",
            "Live bid (sim/bid.py, Permanent Collection's model): first threshold 100% of the 6 ETH reference (D64), "
            "after each purchase 75% of its price; then 0.05 ETH per 300-block cooldown; arbitrage sellers take it at the floor + 0.5%; floor 6 ETH; 5% trading fee "
            "each way plus the opening curve's first hour (50 ETH traded evenly at an average 39%, 19.5 ETH); gas 0.5 "
            "gwei. Flows: trading volume / gameplay demand, ETH a day. Opening: gameplay starts only once the first Ape "
            "and then the 50-row board (1.67 ETH), the 1 ETH reserve and the 0.2 ETH opening keeper allowance are funded "
            "(day shown). Queue: Apes held but not yet listed (most at once, days with any waiting). Gas (0.5 gwei): Ape "
            "upkeep (listing, repricing) / growth (minting and listing added rows) / replacing won prizes. Keeper pay: "
            "gas + 10% within the allowance (5% of each captured prize's cost). Margin after keeper pay: 35% to the "
            "vault while it is short of one Ape, the rest to buybacks. Overflow: trading fees sent to buybacks by D1 "
            "(half the fees while the bid is at its threshold, never the bid's ETH or one more Ape at the last price: only ETH the rate-limited bid cannot use; D65).", "",
            "| flows | rows | active from day | Apes bought (ETH) | won (value) | held at end (listed) | most queued (days) | ordinary rows at end | growth capital | player return | highest FWA fee | gas: Ape upkeep / growth / replacing | keeper pay | fee overflow | buybacks (incl. overflow) | sweep rewards |",
            "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for name in SCEN:
        for upfront in (False, True):
            r = run(name, upfront=upfront)
            out.append(f"| {name} | {'up front' if upfront else 'on demand'} | {r['activation_day']} | "
                       f"{r['bought']} ({r['spend']:.0f}) | {r['wins']} ({r['won_value']:.0f}) | "
                       f"{r['held']} ({r['listed']}) | {r['max_queue']} ({r['queue_days']}) | {r['rows']:,} | "
                       f"{r['growth']:.1f} | {r['ret']:.1%} | {r['max_fee']:.4f} | "
                       f"{r['ape_gas']:.2f} / {r['growth_gas']:.2f} / {r['replace_gas']:.1f} ETH | "
                       f"{r['keeper_paid']:.1f} | {r['overflowed']:.1f} | {r['buybacks']:.1f} | {r['sweep_rewards']:.2f} |")
    out += ["", "### What each flywheel mechanism adds (on demand)", "",
            "Each row switches one mechanism off; the first row is the launch (D64 values, D65 overflow trigger, K 3).", "",
            "| flows | variant | active from day | Apes bought | won | player return | fee overflow | buybacks | vault ETH idle at the end |",
            "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    variants = (("launch (D65)", {}),
                ("no opening curve (first hour at 5%)", dict(launch_fee=FEE)),
                ("curve, traders wait for <= 15% (avg 12%)", dict(launch_fee=0.12)),
                ("curve, 20 ETH in the first hour", dict(launch_volume=20.0)),
                ("no fee overflow", dict(overflow=0.0)),
                ("overflow only while an Ape the target held back waits", dict(trigger="held_back")),
                ("overflow while the board has no room for one more Ape", dict(trigger="no_room")),
                ("overflow by the D64 rule (an Ape waiting or 10 listed)", dict(trigger="listed10")))
    for name in SCEN[:3]:
        for label, kw in variants:
            r = run(name, **kw)
            out.append(f"| {name} | {label} | {r['activation_day']} | {r['bought']} | {r['wins']} | {r['ret']:.1%} | "
                       f"{r['overflowed']:.1f} | {r['buybacks']:.1f} | {r['vault_end']:.1f} |")
    out += ["", "### Target sensitivity over three years (on demand)", "",
            "| flows | target | Apes bought | won | ordinary rows at end | growth capital | player return | highest FWA fee | buybacks |",
            "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for name in (SCEN[0], SCEN[1], SCEN[3]):
        for t in (0.15, 0.20, 0.25):
            r = run(name, target=t)
            out.append(f"| {name} | {t:.0%} | {r['bought']} | {r['wins']} | {r['rows']:,} | {r['growth']:.1f} | "
                       f"{r['ret']:.1%} | {r['max_fee']:.4f} | {r['buybacks']:.1f} |")
    out.append("")


def main():
    out = ["# Ape Draw with many Apes (sim/pool.py; D59 model, D64 launch values and mechanisms, D65 overflow trigger and K 3)", ""]
    part1(out)
    part2(out)
    text = "\n".join(out) + "\n"
    with open(os.path.join(HERE, "results", "pool.md"), "w") as fh:
        fh.write(text)
    print(text)


if __name__ == "__main__":
    main()
