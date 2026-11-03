"""Tabulates the fork throughput study (test/scenario/Throughput.t.sol) into sim/results/throughput.md.

Per configuration (in-flight limit K x opening board): draws completed, refused at request, refunded for settlement
drift, expired, the most requests unsettled at once, keeper gas per completed draw, and the VRF fees players lost on
refunded or expired requests (FWA keeps the VRF fee: 1.5M gas x gas price x 1.3)."""

import json
import os

ROOT = os.path.join(os.path.dirname(__file__), "..")
RECEIPTS = os.path.join(ROOT, "docs", "receipts", "throughput")
OUT = os.path.join(ROOT, "sim", "results", "throughput.md")
BOARD_NAMES = {
    "board-d65": "launch board (D64): the 50-row pattern, 24 x 0.01 Shape, 16 x 0.02 Pack, 3 x 0.03 Pack, 1 x 0.04 Pack,"
    " 3 x 0.05, 1 x 0.1, 1 x 0.15 Pack, 1 x 0.5; 10% markup, minimum live rows 70%, K 3 / 4 / 5 (run on the D65 code;"
    " launch K 3)",
    "": "launch board until D64 (D45): 48 x 0.01 Shape, 32 x 0.02 Pack, 7 x 0.03 Pack, 1 x 0.04 Pack, 7 x 0.05, 1 x 0.06 Pack,"
    " 1 x 0.1, 1 x 0.15 Pack, 1 x 0.5, 1 x 1 ETH (50 and 75 rows are its interleaved prefixes)",
    "board-d42": "first Draw Packs board (superseded D42): 47 x 0.01 Shape, 28 x 0.02 Pack, 16 x 0.03 Pack, 7 x 0.05,"
    " 1 x 0.1, 1 x 0.5 Shape",
    "board-005": "0.05 ETH board (superseded): 40 x 0.05, 6 x 0.1, 3 x 0.5, 1 x 1 ETH",
    "original-board": "original board: 20 x 0.01, 20 x 0.05, 6 x 0.1, 3 x 0.5, 1 x 1 ETH",
}
VRF_GAS = 1_500_000 * 1.3
KS = [3, 4, 5, 10]
BOARDS = [50, 75, 100]


def configs(sub):
    return ([3, 4, 5], [50]) if sub == "board-d65" else (KS, BOARDS)


def load(sub):
    data = {}
    ks, boards = configs(sub)
    for k in ks:
        for b in boards:
            with open(os.path.join(RECEIPTS, sub, f"k{k}-b{b}.json")) as f:
                runs = json.load(f)
            data[(k, b)] = [runs[f"s{i}"] for i in range(len(runs))]
    return data


def pct(a, b):
    return f"{100 * a / b:.1f}%" if b else "-"


def section(sub):
    data = load(sub)
    KS, BOARDS = configs(sub)
    scenarios = [r["scenario"] for r in data[(3, 50)]]
    lines = [
        f"## {BOARD_NAMES[sub]}",
        "",
        "| K | board | attempted | completed | completion | refused | refunded (of issued) | expired | max unsettled "
        "| VRF lost (ETH, 1 gwei) | keeper gas / completed | Ape wins |",
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for b in BOARDS:
        for k in KS:
            rs = data[(k, b)]
            att = sum(r["attempted"] for r in rs)
            iss = sum(r["issued"] for r in rs)
            ful = sum(r["fulfilled"] for r in rs)
            ref = sum(r["refused"] for r in rs)
            rfd = sum(r["refunded"] for r in rs)
            exp = sum(r["expired"] for r in rs)
            mu = max(r["maxUnsettled"] for r in rs)
            gas = sum(r["keeperGas"] for r in rs)
            lost = (rfd + exp) * VRF_GAS * 1e-9
            wins = sum(r["apeWins"] for r in rs)
            lines.append(
                f"| {k} | {b} | {att} | {ful} | {pct(ful, att)} | {ref} | {rfd} ({pct(rfd, iss)}) | {exp} | {mu} "
                f"| {lost:.3f} | {gas / max(ful, 1):,.0f} | {wins} |"
            )
    lines += ["", "By stream (completed / refunded / refused):", ""]
    header = "| stream | " + " | ".join(f"K{k} b{b}" for b in BOARDS for k in KS) + " |"
    lines += [header, "| --- " * (1 + len(BOARDS) * len(KS)) + "|"]
    for i, name in enumerate(scenarios):
        cells = []
        for b in BOARDS:
            for k in KS:
                r = data[(k, b)][i]
                cells.append(f"{r['fulfilled']}/{r['refunded']}/{r['refused']}")
        lines.append(f"| {name} | " + " | ".join(cells) + " |")
    return lines + [""]


def main():
    lines = [
        "# FWA throughput: in-flight limit x opening board",
        "",
        "Fork, block 26,284,000, real FWA pool and VRF service; every purchase through FWA's `acquireBatch` (singles and",
        "five-draw batches). 900 blocks (3 hours) per stream, same seeds for every configuration. `K` admits a purchase",
        "while fewer than K requests are unsettled; with a batch, up to K - 1 + 5 can be. Completed = Fulfilled.",
        "VRF lost: FWA keeps the VRF fee of a refunded or expired request (ETH at 1 gwei). Receipts:",
        "docs/receipts/throughput/ (`test/scenario/Throughput.t.sol`).",
        "",
    ]
    for sub in ["board-d65", "", "board-d42", "board-005", "original-board"]:
        if os.path.exists(os.path.join(RECEIPTS, sub, "k3-b50.json")):
            lines += section(sub)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
