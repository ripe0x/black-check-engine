#!/usr/bin/env python3
"""Coin launch analysis (docs/ECONOMICS.md section 8). Writes sim/results/launch.md.

The market (src/token/ProtocolLiquidity.sol): the whole fixed supply S sits in one Uniswap v4 position over
[MIN_TICK, startTick), single-sided in coins, ETH = currency0, no LP fee; CollectionHook charges fees in ETH (buy:
out of the ETH input; sell: out of the ETH output). D64: the opening curve, 69% on buys and sells at launch falling one
point a minute (per second) to the ordinary 5% each way by minute 64.
Inside one range a v4 position is exactly constant product on virtual reserves: x = L / sqrt(P) ETH and
y = L * sqrt(P) coins (P = coins per ETH). With S in [MIN, start), y = S at the start and x = S / P0, the opening
fully diluted valuation (FDV). So the opening FDV *is* the virtual ETH depth.

Consequences that need no simulation:
- The price can never go above the start (coins per ETH) because the pool never holds more than S coins, so ETH placed
  above the start tick can never be reached by a seller: a seeded ETH position there is locked for good (there is no
  removal path). Exit liquidity is exactly the ETH buyers (and the coin buyback) have put into the pool.
- Every coin outside the pool was bought with ETH that is still in the pool, so holders can always exit in aggregate,
  at a price that falls as they do; the last seller gets the least.
"""
import os

S = 1_000_000_000.0
FEE = 0.05
HERE = os.path.dirname(os.path.abspath(__file__))
AFTER = 65.0  # minutes: past the curve


def fee_at(minute):
    """The hook's fee `minute` minutes after launch, buys and sells alike."""
    return max(FEE, 0.69 - 0.01 * minute)


class Pool:
    def __init__(self, fdv):
        self.x = fdv  # virtual ETH
        self.y = S  # coins in the pool
        self.k = self.x * self.y
        self.eth_in = 0.0  # real ETH held by the pool
        self.fees = 0.0
        self.burned = 0.0

    def price(self):  # ETH per coin
        return self.x / self.y

    def fdv(self):
        return self.price() * (S - self.burned)

    def buy(self, eth, minute=AFTER, exempt=False):
        fee = 0.0 if exempt else eth * fee_at(minute)
        net = eth - fee
        self.fees += fee
        x2 = self.x + net
        y2 = self.k / x2
        out = self.y - y2
        self.x, self.y = x2, y2
        self.eth_in += net
        return out

    def sell(self, coins, minute=AFTER):
        y2 = self.y + coins
        x2 = self.k / y2
        gross = self.x - x2
        self.x, self.y = x2, y2
        self.eth_in -= gross
        fee = gross * fee_at(minute)
        self.fees += fee
        return gross - fee

    def buyback_burn(self, eth):
        out = self.buy(eth, exempt=True)
        self.burned += out
        # burned coins never return to the pool: the constant product is unchanged, the float shrinks
        return out


def opening_table():
    rows = ["| opening FDV | buy | minute | coins (% of supply) | avg price vs open | FDV after | impact |",
            "|---|---|---|---|---|---|---|"]
    for fdv in [50, 100, 250]:
        for eth in [0.1, 0.5, 1, 5]:
            for minute in [0, 30, AFTER]:
                p = Pool(fdv)
                p0 = p.price()
                out = p.buy(eth, minute)
                avg = eth / out
                rows.append(f"| {fdv} ETH | {eth} ETH | {minute:.0f} | {out / S:.3%} | {avg / p0:.3f}x | "
                            f"{p.fdv():.1f} ETH | {p.price() / p0 - 1:+.2%} |")
    return rows


def first_hour():
    """Fees to the vault in the first hour, by when the volume comes (buys and sells alike)."""
    ts = [i / 100 for i in range(0, 6001)]
    profiles = (("evenly over minutes 0-60", [1.0] * len(ts)),
                ("rising linearly toward minute 60", ts),
                ("traders wait for <= 15% (minutes 54-60)", [1.0 if t >= 54 else 0.0 for t in ts]))
    rows = ["| when volume comes | average fee | 20 ETH | 50 ETH | 100 ETH |", "|---|---|---|---|---|"]
    for name, w in profiles:
        a = sum(fee_at(t) * wi for t, wi in zip(ts, w)) / sum(w)
        rows.append(f"| {name} | {a:.1%} | " + " | ".join(f"{v * a:.1f}" for v in (20, 50, 100)) + " |")
    rows.append(f"| reference: flat 5% | 5.0% | " + " | ".join(f"{v * FEE:.1f}" for v in (20, 50, 100)) + " |")
    return rows


def snipers():
    """A buyer at minute N; organic buying after the curve in 0.5 ETH buys; the buyer then sells (5%)."""
    rows = ["| opening FDV | organic buying after the curve | buy | minute 0 | 10 | 30 | 50 | 60 | 64 |",
            "|---|---|---|---|---|---|---|---|---|"]
    for fdv in (50, 100, 250):
        for organic in (10, 50):
            for x in (1, 5):
                cells = []
                for n in (0, 10, 30, 50, 60, 64):
                    p = Pool(fdv)
                    c = p.buy(x, n)
                    for _ in range(int(organic / 0.5)):
                        p.buy(0.5)
                    back = p.sell(c)
                    cells.append(f"{back / x - 1:+.0%}")
                rows.append(f"| {fdv} ETH | {organic} ETH | {x} ETH | " + " | ".join(cells) + " |")
    rows += ["", "Organic buying after the curve a 1 ETH buyer needs to break even (opening FDV 100 ETH):", "",
             "| bought at minute | break-even organic buying |", "|---|---|"]
    for n in (0, 30, 50, 60):
        lo, hi = 0.0, 5000.0
        for _ in range(60):
            mid = (lo + hi) / 2
            p = Pool(100)
            c = p.buy(1, n)
            p.buy(mid)
            if p.sell(c) >= 1:
                hi = mid
            else:
                lo = mid
        rows.append(f"| {n} | {hi:.0f} ETH |")
    rows += ["", "A 1 ETH buy at minute 0 sold with no other flow (opening FDV 100 ETH):", "",
             "| sold at minute | ETH back |", "|---|---|"]
    for m in (1, 10, 30, 64):
        p = Pool(100)
        c = p.buy(1, 0)
        rows.append(f"| {m} | {p.sell(c, m):.3f} |")
    return rows


def patterns(fdv):
    out = []
    # (a) one buyer, immediate exit
    for eth in [0.1, 0.5, 1, 5]:
        p = Pool(fdv)
        c = p.buy(eth)
        back = p.sell(c)
        out.append(f"| round trip | {eth} ETH bought then sold | {back:.4f} ETH back ({back / eth - 1:+.2%}) | fees {p.fees:.4f} |")
    # (b) 20 x 0.5 ETH, then all sell first-in-first-out and last-in-first-out
    for order in ["first buyer sells first", "last buyer sells first"]:
        p = Pool(fdv)
        bags = [p.buy(0.5) for _ in range(20)]
        seq = bags if order.startswith("first") else bags[::-1]
        backs = [p.sell(c) for c in seq]
        out.append(f"| 20 x 0.5 ETH, all exit, {order} | 10 ETH in | first exit {backs[0]:.3f}, last exit "
                   f"{backs[-1]:.3f}, total {sum(backs):.2f} ETH | fees {p.fees:.3f} |")
    # (c) a buyer at minute 0 vs organic buyers after the curve
    for snipe in [1, 5]:
        p = Pool(fdv)
        sc = p.buy(snipe, 0)
        bags = [p.buy(0.5) for i in range(20)]
        back = p.sell(sc)
        out.append(f"| {snipe} ETH bought at minute 0, 20 x 0.5 ETH after the curve, then sold | | gets {back:.3f} ETH "
                   f"({back / snipe - 1:+.1%}) | fees {p.fees:.3f} |")
    # (d) buybacks: 20 x 0.5 ETH bought, then 26 ETH of ongoing buybacks (reference, 1,000 ETH of gameplay), all exit
    p = Pool(fdv)
    bags = [p.buy(0.5) for _ in range(20)]
    for _ in range(26):
        p.buyback_burn(1.0)
    backs = [p.sell(c) for c in bags]
    out.append(f"| 20 x 0.5 ETH, then 26 ETH of buybacks, all exit | 10 ETH in | total {sum(backs):.2f} ETH back "
               f"({sum(backs) / 10 - 1:+.0%}); {p.burned / S:.1%} of supply burned | |")
    return out


def main():
    L = ["# Coin launch: single-sided liquidity, opening valuation and exits", "",
         "Generated by `python3 sim/launch.py`. Exact constant-product math on the v4 position's virtual reserves (see",
         "the file header). Fees (D64): 69% on buys and sells at launch, one point less a minute, to 5% each way from",
         "minute 64; all in ETH to the vault.", "",
         "## Opening purchases (minute 0, 30 and after the curve)", ""] + opening_table() + [""]
    L += ["## Fees to the vault in the first hour", ""] + first_hour() + [""]
    L += ["## Early buyers (the curve as a descending auction for early position)", "",
          "Return of a buy at minute N after organic buying (0.5 ETH buys after the curve), sold at 5%:", ""] + snipers() + [""]
    for fdv in [50, 100]:
        L += [f"## Selling patterns, opening FDV {fdv} ETH", "", "| pattern | in | out | trading fees to the vault |",
              "|---|---|---|---|"] + patterns(fdv) + [""]
    L += ["## Seeded ETH", "",
          "An ETH position can only sit above the start tick (more coins per ETH than at the start). The pool never",
          "holds more than the full supply, so the price can never return there: sellers can never reach that ETH and",
          "the protocol has no way to remove it. A seeded two-sided position therefore adds no exit liquidity and locks",
          "its ETH permanently; the depth a buyer meets is set by the opening FDV alone. `ProtocolLiquidity.launch` no",
          "longer accepts ETH (D38).", ""]
    os.makedirs(os.path.join(HERE, "results"), exist_ok=True)
    open(os.path.join(HERE, "results", "launch.md"), "w").write("\n".join(L) + "\n")
    print("\n".join(L))


if __name__ == "__main__":
    main()
