#!/usr/bin/env python3
"""Collection Games economic simulation (docs/ECONOMICS.md).

Every input is an assumption; every output is a model result, not a forecast. The reference config uses the launch
values (the 50-row board, 10% markup, 5% fees, continuity 35%, milestone 75%, reserve 1 ETH, K = 3 since D65) and the
launch keeper rule (D63, re-modelled here in D65). The Ape listing is still the D57 model (one lead Ape at a time,
others listed above it) and a collection win releases the whole milestone reserve (the launch releases 60%, the rest
on a second win within a day); sim/pool.py models the Apes, the opening curve and the fee overflow and is the primary
model for them. Standard library only; fixed seeds, so a
rerun reproduces the report. Writes sim/results/economics.md and sim/results/economics.json.

The unit of time is one ETH of *attempted* gameplay demand. Token trading volume accrues as a multiple of that demand
whether or not the game is open (trading does not stop when no collection prize is available). Gameplay itself is
cumulative settled ETH: nothing here assumes a number of pulls per day.

Model of the contracts (src/game/CollectionGame.sol, src/core/CollectionPoolOwner.sol, src/core/FundingVault.sol):
- Board: Shapes with cost = backing + 0.001 ETH mint fee and FWA price = cost x (1 + markup). Collection NFTs listed at
  a notional. FWA's odds are inverse to price; its fee is EV x 1.05, EV = harmonic mean of live prices; the owner
  receives fee - (fee - EV)/2. The player also pays FWA's VRF fee (1.95M gas x gas price).
- A Shape win costs the game its cost (expense) and the game replaces it from cash (launch config restocks within
  minutes; modelled as immediate). A collection win costs the game nothing (the NFT was paid by the vault) and
  releases the milestone reserve.
- Keeper pay (D63): each capture adds opsBps x the captured Shape's cost (for a collection capture, x EV) to the
  keeper allowance (0.2 ETH at opening, less listing the opening board). A useful maintenance call is paid
  (gas + 70,000) x min(gas price, 3 gwei) x 1.1 within what is left of the allowance; pay is an expense when paid.
  Gas per call from the fork receipts (docs/receipts/gas-prizes.json). `upkeep="router"` (the site's default): every
  draw runs its own upkeep through the DrawRouter, so prizes are always replaced and the player pays whatever gas the
  allowance does not reimburse. `upkeep="keepers"`: no router; third-party keepers call when the pay covers their gas
  ((gas + 21,000) x (basefee + 0.02 gwei)), booking and replacing up to ten draws a call (or exactly `keeper_batch`);
  unreplaced prizes stay off the board and the purchase gate closes when more than 30% of the rows wait (minLive 70%).
- Profit = proceeds - Shape cost - keeper pay; losses carry. Distribution = min(undistributed
  profit, cash - reserve - exposure). Continuity reserve takes min(60%, deficit to one NFT at maxPrice); the router
  sends 90% (100% while ENGINE is inactive) to the coin, 25% of that to the milestone reserve.
- Collection listings: the lead opens at 50% of its cost and decays linearly to the 1 ETH floor over 8x its cost of
  settled gameplay, never above the exposure cap sum(cost/notional)/(N - headroom), where headroom is the listings the
  purchase gate can let in-flight requests remove (maxInFlight - 1 + a batch of 5); additional NFTs list at 2x cost
  (or higher to fit the cap); when the lead is won the cheapest other becomes lead at its current notional. Decay
  does not wait for a replacement to be funded (the D28 gate was removed; `funded_decay=True` models it).
- Vault: trading fees and contributions. It funds the game's capital need first, then buys NFTs at the acquisition
  price when the budget allows, up to maxInventory (continuity reserve second). Board growth (+25 rows) when decay is
  cap-deferred and 5 ETH of gameplay has passed, or every 100 ETH, if the vault can fund it.
- The game opens once, with its first collection NFT. While no collection NFT is in the draw later (won, the next not
  yet acquired), draws stay open for Shapes and Packs (D53); only `apeless_share` of the demand still plays then (an
  assumption: players come for the Ape), the rest is lost ("unfilled"). `apeless_share=0` is the old closed rule.
"""
import json, math, os, random, statistics as st
from dataclasses import dataclass, field, replace, asdict
from multiprocessing import Pool

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GAS = json.load(open(os.path.join(ROOT, "docs", "receipts", "gas.json")))

MINT = 0.001
EDGE = 0.05
VRF_GAS = 1_500_000 * 1.3
GAS_PRIZES = json.load(open(os.path.join(ROOT, "docs", "receipts", "gas-prizes.json")))
# Keeper pay (D63, CollectionGame.quoteTip): (gas + gasOverhead) x min(tx gas price, maxGasPrice) x (1 + margin), within
# the allowance. A keeper's own cost: (gas + 21,000) x (basefee + priority).
KEEPER_OVERHEAD = 70_000
KEEPER_MARGIN = 0.10
KEEPER_MAX_GWEI = 3.0
KEEPER_PRIORITY = 0.02  # gwei
OPENING_ALLOWANCE = 0.2
OPENING_GAS = 7 * 6_500_000  # listing the opening board: 7 syncs of about 6.5M gas (sim/results/keepers.md)
# Gas of a sync that books and replaces k draws (fork), k = 1 weighted by the 50-row board's odds (D64;
# sim/results/sessions.md)
_ONE = [("shape_001", 0.7038), ("pack_002", 0.2346), ("pack_003", 0.0293), ("pack_004", 0.0073), ("shape_005", 0.0190),
        ("shape_010", 0.0032), ("pack_015", 0.0021), ("shape_050", 0.0006)]
_CALL_GAS = {
    1: sum(GAS_PRIZES[f"sync_book_1_replace_{n}"] * p for n, p in _ONE) / sum(p for _, p in _ONE),
    **{k: GAS_PRIZES[f"sync_book_{k}_replace_{k}"] for k in (3, 5, 8, 10)},
}


def call_gas(k):
    """Gas of one sync booking and replacing k draws (1-10): the fork receipts, linear between them."""
    if k in _CALL_GAS:
        return _CALL_GAS[k]
    lo = max(x for x in _CALL_GAS if x < k)
    hi = min(x for x in _CALL_GAS if x > k)
    return _CALL_GAS[lo] + (_CALL_GAS[hi] - _CALL_GAS[lo]) * (k - lo) / (hi - lo)


def tip(gas, gwei):
    """What the game pays for a useful call at basefee `gwei` (before the allowance limit)."""
    return (gas + KEEPER_OVERHEAD) * min(gwei + KEEPER_PRIORITY, KEEPER_MAX_GWEI) * (1 + KEEPER_MARGIN) * 1e-9


def caller_cost(gas, gwei):
    return (gas + 21_000) * (gwei + KEEPER_PRIORITY) * 1e-9
SHAPE_DENOMS = (0.01, 0.05, 0.1, 0.5, 1.0, 5.0, 10.0, 50.0, 100.0)


def shape_count(b):
    """Shapes in a prize of backing `b`: the fewest denominations adding up to it exactly, largest first
    (CollectionPoolOwner.makeup). One for a Shapes denomination; more for a Draw Pack."""
    rem = round(b * 100)
    n = 0
    for d in reversed(SHAPE_DENOMS):
        u = round(d * 100)
        n += rem // u
        rem %= u
    assert rem == 0
    return n


def prize_cost(b):
    """Cost of a prize of backing `b`: its backing plus one Shapes mint fee per Shape in it."""
    return b + shape_count(b) * MINT


def _interleave(values, counts):
    placed = [0] * len(values)
    out = []
    for _ in range(sum(counts)):
        best = min((i for i in range(len(values)) if placed[i] < counts[i]),
                   key=lambda i: (2 * placed[i] + 1) / counts[i])
        out.append(values[best])
        placed[best] += 1
    return out
MILESTONES = [10, 25, 50, 100, 250, 500, 1000]

def _halves(first, second):
    return first + second


# Board patterns (rows beyond the pattern repeat it). Shapes mints only its fixed denominations (0.01, 0.05, 0.1, 0.5,
# 1, 5, 10, 50, 100 ETH); 0.02 and 0.03 are Draw Packs of 0.01 Shapes.
PATTERNS = {
    # the launch board (D45): 48 x 0.01 Shape, 32 x 0.02 Pack, 7 x 0.03 Pack, 1 x 0.04 Pack, 7 x 0.05 Shape,
    # 1 x 0.06 Pack, 1 x 0.1 Shape, 1 x 0.15 Pack, 1 x 0.5 Shape, 1 x 1 ETH Shape
    "D45": _interleave([0.01, 0.02, 0.03, 0.04, 0.05, 0.06, 0.1, 0.15, 0.5, 1.0], [48, 32, 7, 1, 7, 1, 1, 1, 1, 1]),
    # the launch board since D64 (A4): D45 halved without the 1 ETH Shape and the 0.06 Pack: 24 x 0.01 Shape,
    # 16 x 0.02 Pack, 3 x 0.03 Pack, 1 x 0.04 Pack, 3 x 0.05 Shape, 1 x 0.1 Shape, 1 x 0.15 Pack, 1 x 0.5 Shape
    "B50": _interleave([0.01, 0.02, 0.03, 0.04, 0.05, 0.1, 0.15, 0.5], [24, 16, 3, 1, 3, 1, 1, 1]),
    # the first Draw Packs board (D42, superseded): 47 x 0.01, 28 x 0.02 Pack, 16 x 0.03 Pack, 7 x 0.05, 1 x 0.1, 1 x 0.5
    "D100": _interleave([0.01, 0.02, 0.03, 0.05, 0.1, 0.5], [47, 28, 16, 7, 1, 1]),
    # the original opening board: 20 x 0.01, 20 x 0.05, 6 x 0.1, 3 x 0.5, 1 x 1
    "C0": _halves([0.01, 0.05] * 10 + [0.1] * 3 + [0.5, 0.5], [0.01, 0.05] * 10 + [0.1] * 3 + [0.5, 1.0]),
    # 10 x 0.01, 30 x 0.05, 6 x 0.1, 3 x 0.5, 1 x 1
    "C1": _halves([0.01] * 5 + [0.05] * 15 + [0.1] * 3 + [0.5, 0.5], [0.01] * 5 + [0.05] * 15 + [0.1] * 3 + [0.5, 1.0]),
    # 40 x 0.05, 6 x 0.1, 3 x 0.5, 1 x 1 (no 0.01 Shapes)
    "C2": _halves([0.05] * 20 + [0.1] * 3 + [0.5, 0.5], [0.05] * 20 + [0.1] * 3 + [0.5, 1.0]),
}


@dataclass(frozen=True)
class Config:
    name: str = "reference"
    pattern: str = "C0"
    markup: float = 0.075
    ops_bps: int = 500
    reserve: float = 3.0
    cap: float = 0.08
    lead_open: float = 0.5
    extra_open: float = 2.0
    floor: float = 1.0
    decay_mult: float = 8.0
    max_inventory: int = 3
    max_listed: int = 3
    board: int = 50
    max_board: int = 200
    ape_price: float = 6.0  # acquisition price of each NFT (lognormal noise below)
    ape_sigma: float = 0.15
    max_price: float = 15.0
    fee_pct: float = 0.03
    trade_mult: float = 1.0  # token trading volume per ETH of gameplay demand
    gwei: float = 1.0
    continuity_share: float = 0.6
    milestone_share: float = 0.25
    engine_share: float = 0.0  # 0.10 once ENGINE is active
    demand_growth: float = 100.0
    start_with_nfts: int = 1  # NFTs held at activation (bought from fees before launch)
    funded_decay: bool = False  # True: the removed D28 gate (decay only while a replacement is held or funded)
    demand_max_board: int = 100  # demand-driven growth stops here; exposure-driven growth continues to max_board
    headroom: int = 7  # listings the purchase gate lets in-flight requests remove: maxInFlight (3) - 1 + 5
    upkeep: str = "router"  # "router": every draw runs its upkeep (site default); "keepers": third-party keepers only
    keeper_batch: int = 0  # keepers: 0 = call as soon as paid (up to 10 draws); else exactly this many draws a call
    min_live: float = 0.70  # the purchase gate closes when fewer than this share of the rows are live
    trade_halflife: float = 0.0  # if > 0, trading volume halves every this many ETH of gameplay demand
    apeless_share: float = 0.25  # demand that still draws while no collection NFT is in the draw (D53; 0: closed)


def board_rows(n, pattern="C0"):
    base = PATTERNS[pattern]
    return [base[i % len(base)] for i in range(n)]


class Run:
    def __init__(self, c: Config, seed: int, horizon: float):
        self.c = c
        self.rnd = random.Random(seed)
        self.horizon = horizon
        self.board = c.board
        # Shapes by backing: count live
        self.rows = board_rows(self.board, c.pattern)
        self.tiers = {}
        for b in self.rows:
            self.tiers[b] = self.tiers.get(b, 0) + 1
        # after the board is listed, the reserve and what is left of the opening keeper allowance are in cash
        open_pay = min(tip(OPENING_GAS, c.gwei), OPENING_ALLOWANCE)
        self.cash = c.reserve + OPENING_ALLOWANCE - open_pay
        self.allowance = OPENING_ALLOWANCE - open_pay  # keeper pay still available
        self.max_cost = max(prize_cost(b) for b in self.rows)
        self.board_cost = sum(prize_cost(b) for b in self.rows)
        self.vault_general = 0.0
        self.continuity = 0.0
        self.pending = []  # prizes won and not yet replaced: no keeper call was paid for them yet
        self.profit = 0.0
        self.distributed = 0.0
        self.turnover = 0.0
        self.demand = 0.0
        self.last_growth = 0.0
        self.apes = []  # dicts: cost, notional, lead, start, start_t, dist, floor
        self.custody = []
        # metrics
        self.m = dict(pulls=0, ticket_sum=0.0, backing_out=0.0, coll_ref_out=0.0, vrf_paid=0.0, over_ticket=0,
                      coll_wins=0, win_turnovers=[], open_turnover=0.0, unfilled=0.0, acq_spent=0.0, acq_n=0,
                      acq_from_cont=0.0, fees=0.0, ongoing=0.0, milestone=0.0, engine=0.0, cont_in=0.0,
                      keeper_cost=0.0, players_upkeep=0.0, keeper_calls=0, deferred=0, maint_closed=0.0, max_pending=0, ops_alloc=0.0, worst_headroom=1e9, deficit_events=0,
                      peak_board_capital=0.0, growth=0, gap_turnover=0.0, apeless_turnover=0.0, milestone_pending=0.0, surplus=0.0,
                      snapshots={})
        for _ in range(c.start_with_nfts):
            self._add_nft(self._price(), fee_funded=True, pre=True)
        self._list_all()

    # ------------------------------------------------------------------ pool math
    def _price(self):
        return max(0.5, self.c.ape_price * math.exp(self.rnd.gauss(0, self.c.ape_sigma)))

    def shape_price(self, b):
        return prize_cost(b) * (1 + self.c.markup)

    def weights(self):
        w = [(k, n / self.shape_price(k)) for k, n in self.tiers.items() if n > 0]
        a = [(i, 1.0 / ap["notional"]) for i, ap in enumerate(self.apes) if ap["open"]]
        return w, a

    def n_listings(self):
        return sum(self.tiers.values()) + sum(1 for ap in self.apes if ap["open"])

    def exposure_sum(self, skip=None):
        return sum(ap["cost"] / ap["notional"] for i, ap in enumerate(self.apes) if ap["open"] and i != skip)

    def cap_min(self, cost, others, n):
        budget = self.c.cap * (n - self.c.headroom) - others
        return math.inf if budget <= 0 else cost / budget

    # ------------------------------------------------------------------ collection rules
    def _add_nft(self, price, fee_funded, pre=False):
        self.custody.append(price)

    def lead(self):
        for ap in self.apes:
            if ap["open"] and ap["lead"]:
                return ap
        return None

    def _promote(self, ap):
        ap["lead"] = True
        ap["start"] = ap["notional"]
        ap["start_t"] = self.turnover
        ap["floor"] = min(self.c.floor, ap["notional"])
        ap["dist"] = self.c.decay_mult * ap["cost"]

    def _list_all(self):
        n = self.n_listings()
        if self.lead() is None:
            opens = [ap for ap in self.apes if ap["open"]]
            if opens:
                self._promote(min(opens, key=lambda a: a["notional"]))
            elif self.custody:
                cost = self.custody[-1]
                notional = max(cost * self.c.lead_open, self.c.floor)
                if self.cap_min(cost, self.exposure_sum(), n + 1) <= notional:
                    self.custody.pop()
                    ap = dict(cost=cost, notional=notional, open=True, lead=False)
                    self.apes.append(ap)
                    self._promote(ap)
        while self.lead() is not None and self.custody and sum(1 for a in self.apes if a["open"]) < self.c.max_listed:
            cost = self.custody[-1]
            cm = self.cap_min(cost, self.exposure_sum(), self.n_listings() + 1)
            if cm == math.inf:
                break
            self.custody.pop()
            self.apes.append(dict(cost=cost, notional=max(cost * self.c.extra_open, cm), open=True, lead=False))
        ld = self.lead()
        if ld is not None:
            spent = self.turnover - ld["start_t"]
            sched = ld["floor"] if spent >= ld["dist"] else ld["floor"] + (ld["start"] - ld["floor"]) * (ld["dist"] - spent) / ld["dist"]
            idx = self.apes.index(ld)
            cm = self.cap_min(ld["cost"], self.exposure_sum(idx), self.n_listings())
            target = max(sched, cm)
            self.deferred = cm > sched and ld["notional"] > sched
            if self.c.funded_decay and not self.replacement_funded():
                target = ld["notional"]
            if target < ld["notional"] * 0.98 or (target < ld["notional"] and target == ld["floor"]):
                ld["notional"] = target
        else:
            self.deferred = False

    def replacement_funded(self):
        others = len(self.custody) + sum(1 for ap in self.apes if ap["open"] and not ap["lead"])
        return others > 0 or self.vault_general + self.continuity >= getattr(self, "_next_price", self.c.ape_price)

    def available(self):
        return (self.board - len(self.pending)) >= self.c.min_live * self.board

    # ------------------------------------------------------------------ capital
    def capital_need(self):
        return max(0.0, self.c.reserve - self.cash)

    def vault_step(self):
        need = self.capital_need()
        if need > 0 and self.vault_general > 0:
            x = min(need, self.vault_general)
            self.vault_general -= x
            self.cash += x
        held = len(self.custody) + sum(1 for ap in self.apes if ap["open"])
        if held < self.c.max_inventory:
            price = self._next_price
            budget = self.vault_general + self.continuity
            if budget >= price:
                g = min(price, self.vault_general)
                self.vault_general -= g
                self.continuity -= price - g
                self.m["acq_spent"] += price
                self.m["acq_from_cont"] += price - g
                self.m["acq_n"] += 1
                self.custody.append(price)
                self._next_price = self._price()

    def grow(self):
        if self.board >= self.c.max_board:
            return
        since = self.turnover - self.last_growth
        demand = since >= self.c.demand_growth and self.board < self.c.demand_max_board
        if not ((self.deferred and since >= 5) or demand):
            return
        new = board_rows(self.board + 25, self.c.pattern)[self.board:]
        cost = sum(prize_cost(b) for b in new)
        others = len(self.custody) + sum(1 for ap in self.apes if ap["open"] and not ap["lead"])
        ld = self.lead()
        keep = ld["cost"] if (ld is not None and others == 0) else 0.0
        if self.vault_general < cost or self.vault_general + self.continuity < cost + keep:
            return
        self.vault_general -= cost
        for b in new:
            self.tiers[b] = self.tiers.get(b, 0) + 1
        self.board += 25
        self.last_growth = self.turnover
        self.m["growth"] += 1

    # ------------------------------------------------------------------ one pull
    def pull(self):
        c = self.c
        w, a = self.weights()
        W = sum(x for _, x in w) + sum(x for _, x in a)
        n = self.n_listings()
        ev = n / W
        fee = ev * (1 + EDGE)
        vrf = VRF_GAS * c.gwei * 1e-9
        proceeds = fee - (fee - ev) / 2
        self.m["pulls"] += 1
        self.m["ticket_sum"] += fee
        self.m["vrf_paid"] += vrf
        self.turnover += fee
        self.m["open_turnover"] += fee
        self.cash += proceeds
        self.profit += proceeds
        # selection
        r = self.rnd.random() * W
        for k, x in w:
            r -= x
            if r <= 0:
                cost = prize_cost(k)
                self.profit -= cost
                self.tiers[k] -= 1
                self.pending.append(k)
                self._ops(cost * c.ops_bps / 10_000)
                self._upkeep()
                self.m["backing_out"] += k
                if k >= fee + vrf:
                    self.m["over_ticket"] += 1
                return
        for i, x in a:
            r -= x
            if r <= 0:
                break
        self._ops(ev * c.ops_bps / 10_000)
        if c.upkeep == "router":  # the draw's own upkeep books it (nothing to replace)
            self._pay(GAS_PRIZES["sync_book_1_only"])
        ap = self.apes[i]
        ap["open"] = False
        self.m["coll_wins"] += 1
        self.m["coll_ref_out"] += ap["cost"]
        self.m["win_turnovers"].append(self.turnover)
        # milestone release: the whole reserve
        self.m["milestone"] += self.m["milestone_pending"]
        self.m["milestone_pending"] = 0.0
        self._list_all()

    def _ops(self, ops):
        """A capture adds its share to the keeper allowance (no cash moves until a call is paid)."""
        self.allowance += ops
        self.m["ops_alloc"] += ops

    def _pay(self, gas):
        """Pays one useful call of `gas` its tip within the allowance (an expense); returns the amount paid. The
        caller's gas the pay does not cover is the router player's (keepers do not call at a loss)."""
        pay = min(tip(gas, self.c.gwei), self.allowance)
        self.allowance -= pay
        self.cash -= pay
        self.profit -= pay
        self.m["keeper_cost"] += pay
        self.m["keeper_calls"] += 1
        short = caller_cost(gas, self.c.gwei) - pay
        if short > 0:
            self.m["players_upkeep"] += short
        return pay

    def _replace(self, k):
        for _ in range(k):
            b = self.pending.pop()
            self.tiers[b] += 1
            self.cash -= prize_cost(b)

    def _upkeep(self):
        """After a Shape capture: the router replaces it at once in the draw's own transaction; keepers call once
        the pay for the call covers their gas (or at exactly `keeper_batch` draws)."""
        c = self.c
        if c.upkeep == "router":
            self._pay(call_gas(1))
            self._replace(1)
            return
        k = min(len(self.pending), 10)
        if c.keeper_batch:
            if k < c.keeper_batch:
                k = 0
            else:
                k = c.keeper_batch
        if k:
            gas = call_gas(k)
            if min(tip(gas, c.gwei), self.allowance) >= caller_cost(gas, c.gwei):
                self._pay(gas)
                self._replace(k)
        if self.pending:
            self.m["deferred"] += 1
            self.m["max_pending"] = max(self.m["max_pending"], len(self.pending))

    def distribute(self):
        undist = self.profit - self.distributed
        # reserve + exposure of ~2 requests in flight at a sync, never more than the board itself (exposure())
        free = self.cash - self.c.reserve - min(2 * self.max_cost, self.board_cost)
        d = min(undist, free)
        if d < 0.01:
            return
        self.distributed += d
        self.m["surplus"] += d
        self.cash -= d
        cont = min(d * self.c.continuity_share, max(0.0, self.c.max_price - self.continuity))
        self.continuity += cont
        self.m["cont_in"] += cont
        rest = d - cont
        eng = rest * self.c.engine_share
        coin = rest - eng
        self.m["engine"] += eng
        self.m["ongoing"] += coin * (1 - self.c.milestone_share)
        self.m["milestone_pending"] += coin * self.c.milestone_share

    def run(self):
        c = self.c
        self._next_price = self._price()
        self.ticket = analytic(c)["ticket"]
        step = 0
        mi = 0
        while self.turnover < self.horizon and self.demand < self.horizon * 50:
            # one ticket of demand: trading fees accrue with demand whether or not the game is open
            t = self.ticket
            self.demand += t
            mult = c.trade_mult * (0.5 ** (self.demand / c.trade_halflife) if c.trade_halflife > 0 else 1.0)
            fees = t * mult * c.fee_pct
            self.vault_general += fees
            self.m["fees"] += fees
            if self.available():
                if any(ap["open"] for ap in self.apes):
                    self.pull()
                elif self.rnd.random() < c.apeless_share:
                    self.m["apeless_turnover"] += t
                    self.pull()
                else:  # came for the Ape: not played while none is in the draw
                    self.m["unfilled"] += t
                    self.m["gap_turnover"] += t
            else:
                self.m["unfilled"] += t
                self.m["gap_turnover"] += t
                self.m["maint_closed"] += t  # closed only by prizes off the board
                self._upkeep()  # a keeper call the allowance can pay reopens it
            step += 1
            if step % 8 == 0:
                self.distribute()
                self.vault_step()
                self.grow()
                self._list_all()
            headroom = self.cash - 0.0
            if headroom < self.m["worst_headroom"]:
                self.m["worst_headroom"] = headroom
            if self.cash < 0:
                self.m["deficit_events"] += 1
            while mi < len(MILESTONES) and self.turnover >= MILESTONES[mi]:
                self.m["snapshots"][MILESTONES[mi]] = dict(
                    wins=self.m["coll_wins"], surplus=self.m["surplus"], ongoing=self.m["ongoing"],
                    milestone=self.m["milestone"] + self.m["milestone_pending"], acq=self.m["acq_spent"],
                    unfilled=self.m["unfilled"], fees=self.m["fees"], board=self.board, cont=self.continuity,
                    profit=self.profit, engine=self.m["engine"])
                mi += 1
        self.m["board_final"] = self.board
        self.m["allowance_left"] = self.allowance
        self.m["board_capital"] = sum(prize_cost(b) * n for b, n in self.tiers.items())
        return self.m


def one(args):
    c, seed, horizon = args
    m = Run(c, seed, horizon).run()
    m.pop("win_turnovers_raw", None)
    return m


def pct(xs, p):
    if not xs:
        return float("nan")
    xs = sorted(xs)
    k = (len(xs) - 1) * p
    f = math.floor(k)
    cidx = math.ceil(k)
    return xs[f] if f == cidx else xs[f] + (xs[cidx] - xs[f]) * (k - f)


def analytic(c: Config):
    rows = board_rows(c.board, c.pattern)
    prices = [prize_cost(b) * (1 + c.markup) for b in rows]
    ape_n = c.ape_price * c.lead_open
    W = sum(1 / p for p in prices) + 1 / ape_n
    n = len(prices) + 1
    ev = n / W
    fee = ev * (1 + EDGE)
    backing = sum(b / p for b, p in zip(rows, prices)) / W
    coll = (c.ape_price / ape_n) / W
    vrf = VRF_GAS * c.gwei * 1e-9
    p_over = sum(1 / p for b, p in zip(rows, prices) if b >= fee + vrf) / W
    return dict(ticket=fee, vrf=vrf, ret_backing=backing / fee, ret_coll=coll / fee,
                ret_all_in=(backing + coll) / (fee + vrf), p_over_ticket=p_over, p_coll_per_pull=(1 / ape_n) / W,
                exposure=(c.ape_price / ape_n) / n, board_capital=sum(prize_cost(b) for b in rows))


def summarise(c: Config, runs, horizon):
    out = dict(config=asdict(c), analytic=analytic(c), runs=len(runs))
    # collection win probability by milestone (at least one win by X ETH)
    out["p_win_by"] = {X: sum(1 for m in runs if m["snapshots"].get(X, {}).get("wins", 0) > 0) / len(runs)
                       for X in MILESTONES if X <= horizon}
    firsts = [m["win_turnovers"][0] for m in runs if m["win_turnovers"]]
    gaps = []
    for m in runs:
        wt = m["win_turnovers"]
        gaps += [b - a for a, b in zip(wt, wt[1:])]
    out["first_win_eth"] = dict(p10=pct(firsts, .1), p50=pct(firsts, .5), p90=pct(firsts, .9), n=len(firsts),
                                never=sum(1 for m in runs if not m["win_turnovers"]))
    out["between_wins_eth"] = dict(p10=pct(gaps, .1), p50=pct(gaps, .5), p90=pct(gaps, .9), n=len(gaps))
    def mean(k):
        return st.mean(m[k] for m in runs)
    T = horizon
    out["per_run"] = dict(
        pulls=mean("pulls"), wins=mean("coll_wins"), surplus=mean("surplus"), ongoing=mean("ongoing"),
        milestone=st.mean(m["milestone"] + m["milestone_pending"] for m in runs), milestone_released=mean("milestone"),
        engine=mean("engine"), continuity_in=mean("cont_in"), acq_spent=mean("acq_spent"), acq_n=mean("acq_n"),
        acq_from_continuity=mean("acq_from_cont"), fees=mean("fees"), unfilled=mean("unfilled"),
        apeless=mean("apeless_turnover"),
        available_frac=st.mean((m["open_turnover"] - m["apeless_turnover"]) / max(1e-18, m["open_turnover"] + m["unfilled"]) for m in runs),
        keeper_cost=mean("keeper_cost"), players_upkeep=mean("players_upkeep"), keeper_calls=mean("keeper_calls"),
        allowance_left=mean("allowance_left"),
        deferred=mean("deferred"), maint_closed=mean("maint_closed"), max_pending=max(m["max_pending"] for m in runs),
        ops_alloc=mean("ops_alloc"),
        worst_cash=min(m["worst_headroom"] for m in runs), deficit_runs=sum(1 for m in runs if m["deficit_events"]),
        board_final=mean("board_final"), board_capital=mean("board_capital"), growth=mean("growth"),
        player_return_realised=st.mean((m["backing_out"] + m["coll_ref_out"]) / max(1e-18, m["ticket_sum"] + m["vrf_paid"]) for m in runs),
        p_over_ticket=st.mean(m["over_ticket"] / max(1, m["pulls"]) for m in runs),
        surplus_p10=pct([m["surplus"] for m in runs], .1), surplus_p90=pct([m["surplus"] for m in runs], .9),
    )
    out["by_milestone"] = {}
    for X in MILESTONES:
        snaps = [m["snapshots"][X] for m in runs if X in m["snapshots"]]
        if not snaps:
            continue
        out["by_milestone"][X] = {k: st.mean(s[k] for s in snaps) for k in snaps[0]}
    return out


def simulate(c: Config, runs=96, horizon=1000, seed0=1):
    with Pool(4) as p:
        res = p.map(one, [(c, seed0 + i, horizon) for i in range(runs)])
    return summarise(c, res, horizon)


# ------------------------------------------------------------------ scenarios

# The launch configuration (D64, D65; docs/ECONOMICS.md section 1): the 50-row board, 10% markup, 5% keeper allowance
# of each prize's cost, 5% trading fee, continuity 35%, milestone 75%, reserve 1 ETH, in-flight limit 3 (headroom
# 3 - 1 + 5 = 7), minimum live rows 70%; every draw runs its own upkeep through the DrawRouter (the site's default).
REF = Config(pattern="B50", markup=0.10, ops_bps=500, board=50, headroom=7, fee_pct=0.05, continuity_share=0.35,
             milestone_share=0.75, reserve=1.0)
CONSERVATIVE = replace(REF, name="conservative", trade_mult=0.5, ape_price=8.0, gwei=2.0)
AGGRESSIVE = replace(REF, name="aggressive", trade_mult=3.0, ape_price=5.0, gwei=0.5)


def grids():
    g = []
    for gw in [0.25, 0.5, 1.0, 2.0, 3.0, 5.0]:
        g.append(("gas price (every draw runs its upkeep)", replace(REF, name=f"{gw} gwei", gwei=gw)))
    for gw in [0.25, 0.5, 1.0, 1.1, 1.25, 2.0]:
        g.append(("gas price, keepers only (no router)", replace(REF, name=f"keepers, {gw} gwei", gwei=gw, upkeep="keepers")))
    for k in (1, 3, 10):
        g.append(("keeper batch size (fixed, keepers only)", replace(REF, name=f"always {k} draws per call, 1 gwei", upkeep="keepers", keeper_batch=k)))
    for m in [0.0, 0.25, 0.5, 1.0, 2.0, 3.0]:
        g.append(("trading multiple", replace(REF, name=f"trade {m}x", trade_mult=m)))
    for hl in [100, 250, 500]:
        g.append(("declining trading (2x, halving)", replace(REF, name=f"2x halving every {hl} ETH", trade_mult=2.0, trade_halflife=hl)))
    for d in [4, 8, 12]:
        g.append(("decay distance", replace(REF, name=f"decay {d}x", decay_mult=d)))
    for mk in [0.05, 0.075, 0.10, 0.125]:
        g.append(("markup", replace(REF, name=f"markup {mk:.1%}", markup=mk)))
    for o in [300, 500]:
        g.append(("operating allocation", replace(REF, name=f"ops {o} bps", ops_bps=o)))
    for f in [0.03, 0.05, 0.07]:
        g.append(("trading fee", replace(REF, name=f"fee {f:.0%}", fee_pct=f)))
    for ap in [4.0, 6.0, 10.0]:
        g.append(("collection NFT price", replace(REF, name=f"NFT {ap} ETH", ape_price=ap)))
    for k in [1, 2, 3]:
        g.append(("NFTs listed at once", replace(REF, name=f"{k} NFTs", max_inventory=k, max_listed=k)))
    g.append(("in-flight limit", replace(REF, name="maxInFlight 4 (headroom 8)", headroom=8)))
    g.append(("in-flight limit", replace(REF, name="maxInFlight 5 (headroom 9)", headroom=9)))
    g.append(("other boards (reference)", replace(REF, name="the D45 100-row board (launch until D64), 5% markup", pattern="D45", board=100, markup=0.05, headroom=14)))
    g.append(("other boards (reference)", replace(REF, name="first Draw Packs board (D42), 5%", pattern="D100", board=100, markup=0.05)))
    g.append(("other boards (reference)", replace(REF, name="original 50 (0.01-heavy), 7.5%", pattern="C0", board=50, markup=0.075, ops_bps=500)))
    g.append(("other boards (reference)", replace(REF, name="0.05 ETH board, 7.5%", pattern="C2", board=50, markup=0.075, ops_bps=300)))
    g.append(("ENGINE active", replace(REF, name="ENGINE 10%", engine_share=0.10)))
    for a in [0.0, 0.25, 1.0]:
        g.append(("demand while no Ape is in the draw (D53)", replace(REF, name=f"{a:.0%} still play" + (" (closed, old rule)" if a == 0 else ""), apeless_share=a)))
    return g


def fmt(x, d=2):
    if isinstance(x, float):
        if math.isnan(x):
            return "-"
        return f"{x:,.{d}f}"
    return str(x)


def report(results):
    L = ["# Collection Games economic simulation", "",
         "Generated by `python3 sim/economics.py` (seeded; 4 processes). Every number is a model result under the",
         "assumptions in the file header and docs/ECONOMICS.md, not a forecast. Gameplay is cumulative settled ETH;",
         "no daily pull count is assumed. 'Return' counts Shape backing at face value and collection NFTs at their",
         "acquisition cost (a reference value, not a guaranteed resale price).", ""]
    for title, r in results["scenarios"].items():
        a, p = r["analytic"], r["per_run"]
        L += [f"## {title}", "",
              f"Config: `{json.dumps({k: v for k, v in r['config'].items() if k != 'name'})}`", "",
              "| measure | value |", "|---|---|",
              f"| ticket (FWA fee) | {a['ticket']:.5f} ETH (+ VRF {a['vrf']:.5f}) |",
              f"| expected return: Shape backing / ticket | {a['ret_backing']:.2%} |",
              f"| expected return: collection reference / ticket (lead at opening) | {a['ret_coll']:.2%} |",
              f"| expected return all-in incl. VRF fee | {a['ret_all_in']:.2%} |",
              f"| realised return over the run (incl. VRF) | {p['player_return_realised']:.2%} |",
              f"| P(prize worth at least FWA fee + VRF fee; excludes transaction and redemption gas; not a profit probability) | {a['p_over_ticket']:.2%} |",
              f"| collection exposure at opening | {a['exposure']:.2%} |",
              f"| pulls per run | {p['pulls']:,.0f} |",
              f"| collection wins per run | {p['wins']:.2f} |",
              f"| first win: ETH of gameplay p10 / p50 / p90 | {fmt(r['first_win_eth']['p10'],1)} / {fmt(r['first_win_eth']['p50'],1)} / {fmt(r['first_win_eth']['p90'],1)} (no win in {r['first_win_eth']['never']} of {r['runs']}) |",
              f"| between wins: ETH p10 / p50 / p90 | {fmt(r['between_wins_eth']['p10'],1)} / {fmt(r['between_wins_eth']['p50'],1)} / {fmt(r['between_wins_eth']['p90'],1)} |",
              f"| share of demand with a collection NFT available | {p['available_frac']:.1%} |",
              f"| demand played while no collection NFT was in the draw (Shapes and Packs only; D53) | {p['apeless']:.1f} ETH |",
              f"| demand unfilled (no collection prize) | {p['unfilled']:.1f} ETH |",
              f"| trading fees collected | {p['fees']:.2f} ETH |",
              f"| acquisitions: count / ETH / from continuity | {p['acq_n']:.2f} / {p['acq_spent']:.2f} / {p['acq_from_continuity']:.2f} |",
              f"| board at end / Shapes capital | {p['board_final']:.0f} / {p['board_capital']:.2f} ETH |",
              f"| distributable surplus (mean, p10, p90): all of it, before the split below | {p['surplus']:.2f} ({p['surplus_p10']:.2f}, {p['surplus_p90']:.2f}) ETH |",
              f"| of which to coin buybacks (ongoing + milestone) | {p['ongoing'] + p['milestone']:.2f} ETH |",
              f"| continuity reserve funded from margin | {p['continuity_in']:.2f} ETH |",
              f"| ongoing buyback ETH | {p['ongoing']:.2f} |",
              f"| milestone buyback ETH (allocated; released on wins) | {p['milestone']:.2f} ({p['milestone_released']:.2f}) |",
              f"| ENGINE allocation | {p['engine']:.2f} |",
              f"| keeper pay vs allowance earned by captures (left at the end, opening allowance included) | {p['keeper_cost']:.2f} vs {p['ops_alloc']:.2f} ETH ({p['allowance_left']:.2f}) |",
              f"| maintenance calls / upkeep gas players paid beyond the reimbursement | {p['keeper_calls']:,.0f} / {p['players_upkeep']:.2f} ETH ({p['players_upkeep'] / max(1, p['pulls']):.6f} a draw) |",
              f"| replacements waiting for a paid keeper call (draws, max prizes off the board) | {p['deferred']:.0f} ({p['max_pending']}) |",
              f"| demand refused because unreplaced prizes closed the gate | {p['maint_closed']:.1f} ETH |",
              f"| worst game cash observed / runs with negative cash | {p['worst_cash']:.2f} ETH / {p['deficit_runs']} |",
              ""]
        L += ["P(at least one collection win) by cumulative gameplay ETH:", "",
              "| ETH | " + " | ".join(str(x) for x in r["p_win_by"]) + " |",
              "|---|" + "---|" * len(r["p_win_by"]),
              "| P | " + " | ".join(f"{v:.0%}" for v in r["p_win_by"].values()) + " |", ""]
        L += ["By cumulative gameplay ETH (means):", "",
              "| ETH | wins | surplus | ongoing | milestone | acquisitions | trading fees | board | unfilled |",
              "|---|---|---|---|---|---|---|---|---|"]
        for X, s in r["by_milestone"].items():
            L.append(f"| {X} | {s['wins']:.2f} | {s['surplus']:.2f} | {s['ongoing']:.2f} | {s['milestone']:.2f} | "
                     f"{s['acq']:.2f} | {s['fees']:.2f} | {s['board']:.0f} | {s['unfilled']:.1f} |")
        L.append("")
    L += ["## Sensitivity (1,000 ETH of gameplay, reference config with one parameter changed)", "",
          "| group | config | ticket | return all-in | wins | first win p50 | available | distributable surplus | to continuity | ongoing buyback | milestone buyback | acquisitions ETH | unfilled ETH | of which closed for maintenance | board | keeper pay | players' unreimbursed upkeep per draw |",
          "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for grp, r in results["grid"]:
        a, p = r["analytic"], r["per_run"]
        L.append(f"| {grp} | {r['config']['name']} | {a['ticket']:.4f} | {a['ret_all_in']:.1%} | {p['wins']:.2f} | "
                 f"{fmt(r['first_win_eth']['p50'],0)} | {p['available_frac']:.0%} | {p['surplus']:.1f} | {p['continuity_in']:.1f} | {p['ongoing']:.1f} | "
                 f"{p['milestone']:.1f} | {p['acq_spent']:.1f} | {p['unfilled']:.0f} | {p['maint_closed']:.0f} | {p['board_final']:.0f} | {p['keeper_cost']:.2f} | {p['players_upkeep'] / max(1, p['pulls']):.6f} |")
    L.append("")
    return "\n".join(L)


def main():
    os.makedirs(os.path.join(HERE, "results"), exist_ok=True)
    quick = os.environ.get("SIM_QUICK") == "1"
    runs = 24 if quick else 96
    grid_runs = 12 if quick else 48
    results = dict(scenarios={}, grid=[])
    for c in [REF, CONSERVATIVE, AGGRESSIVE]:
        results["scenarios"][c.name] = simulate(c, runs=runs)
        print("done", c.name, flush=True)
    for grp, c in grids():
        results["grid"].append((grp, simulate(c, runs=grid_runs)))
        print("done", grp, c.name, flush=True)
    json.dump(results, open(os.path.join(HERE, "results", "economics.json"), "w"), indent=1, default=str)
    open(os.path.join(HERE, "results", "economics.md"), "w").write(report(results))


if __name__ == "__main__":
    main()
