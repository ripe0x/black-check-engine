"use client";

import { useEffect, useState } from "react";
import { formatEther } from "viem";
import { usePublicClient, useReadContract } from "wagmi";
import { deployment, collectionMeta } from "../lib/deployment";
import { burnerAbi } from "../lib/abi.generated";
import { fmtEth } from "../lib/format";

// The buy-and-burn pot (D74): all of the game's surplus sent to the burner waits in its reserve; an Ape win releases
// `firstExitBps` of it (a second Ape within the exit window, all of it), and the released ETH is then bought and burned
// a slice at a time (at most 1 ETH every 10 minutes). Read from the burner; nothing here is an estimate of the chain.
const on = { enabled: deployment.deployed, refetchInterval: 12_000 };
const e3 = (w: bigint | undefined) => (w === undefined ? "–" : fmtEth(Number(formatEther(w))));
const SHOWN_FROM = 10n ** 18n / 2n; // the pot shows from 0.5 ETH (a burn under way always shows)
const clock = (s: number) => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;

/** The chain's clock, ticking locally between reads (a fork's clock can be far from the browser's). */
function useChainNow() {
  const client = usePublicClient();
  const [now, setNow] = useState<number>();
  useEffect(() => {
    if (!client) return;
    let base = 0, at = 0;
    const read = () => client.getBlock().then((b) => { base = Number(b.timestamp); at = Date.now(); }).catch(() => {});
    read();
    const r = setInterval(read, 30_000);
    const t = setInterval(() => base && setNow(base + Math.floor((Date.now() - at) / 1000)), 1000);
    return () => { clearInterval(r); clearInterval(t); };
  }, [client]);
  return now;
}

/** The pot, a row under the coin bar: its size and what pulling an Ape releases, or, while a release burns, how much
 *  is left. */
export function BurnPot() {
  const b = deployment.burner;
  const { data: pot } = useReadContract({ address: b, abi: burnerAbi, functionName: "reserve", query: on });
  const { data: burning } = useReadContract({ address: b, abi: burnerAbi, functionName: "milestoneBalance", query: on });
  const { data: tiers } = useReadContract({ address: b, abi: burnerAbi, functionName: "tiers", query: on });
  const { data: lastExit } = useReadContract({ address: b, abi: burnerAbi, functionName: "lastExitAt", query: on });
  const { data: next } = useReadContract({ address: b, abi: burnerAbi, functionName: "nextSlice", query: { ...on, enabled: on.enabled && !!burning } });
  const client = usePublicClient();
  const [release, setRelease] = useState<bigint>();
  // the size of the burn under way: the last release (several at once add up; the bar then reads from the latest)
  useEffect(() => {
    if (!client || !burning) return;
    client.getContractEvents({ address: b, abi: burnerAbi, eventName: "Released", fromBlock: BigInt(deployment.block ?? 0) })
      .then((logs) => setRelease(logs.length ? logs[logs.length - 1].args.amount : undefined)).catch(() => {});
  }, [client, b, !!burning]); // eslint-disable-line react-hooks/exhaustive-deps
  const now = useChainNow();
  if (pot === undefined) return null;
  const sym = collectionMeta.ticker, ape = collectionMeta.short;
  if (burning) {
    const total = release && release >= burning ? release : burning;
    const done = total ? Number(((total - burning) * 1000n) / total) / 10 : 0;
    const wait = next && now !== undefined ? Math.max(0, Number(next[2]) - now) : undefined;
    return (
      <div className="pot burning" role="status">
        <span className="pot-head"><i aria-hidden />BURNING {sym}</span>
        <b>{e3(burning)} ETH to go</b>
        <span className="pot-bar" aria-hidden><span style={{ width: `${done}%` }} /></span>
        <span className="pot-sub">{wait === undefined ? "Bought and burned a slice at a time" : wait > 0 ? `Next ${e3(next![0])} ETH slice in ${clock(wait)}` : "Next slice runs now"}</span>
      </div>
    );
  }
  if (pot < SHOWN_FROM) return null;
  const inWindow = tiers && lastExit && now !== undefined && now <= Number(lastExit) + Number(tiers.exitWindow);
  const bps = !tiers ? undefined : inWindow ? 10_000n : tiers.firstExitBps;
  return (
    <div className="pot" title="All game surplus sent to buybacks waits here. Winning a Check releases it to buy and burn the coin.">
      <span className="pot-head">{ape.toUpperCase()} BURN POT</span>
      <b>{e3(pot)} ETH</b>
      <span className="pot-sub">{bps === undefined ? `Pull an ${ape} to set it off` : `Pull an ${ape}: ${e3((pot * bps) / 10_000n)} ETH buys and burns ${sym}`}</span>
    </div>
  );
}

/** On the win screen: the burn this Ape win set off, or sets off when it is booked (seconds later). */
export function BurnLine({ listingId }: { listingId: bigint }) {
  const b = deployment.burner;
  const client = usePublicClient();
  const { data: released } = useReadContract({ address: b, abi: burnerAbi, functionName: "released", args: [listingId], query: { refetchInterval: 4_000 } });
  const { data: bps } = useReadContract({ address: b, abi: burnerAbi, functionName: "releaseBps", args: [listingId], query: { enabled: released === false } });
  const { data: pot } = useReadContract({ address: b, abi: burnerAbi, functionName: "reserve", query: { enabled: released === false } });
  const [amount, setAmount] = useState<bigint>();
  useEffect(() => {
    if (!client || !released) return;
    client.getContractEvents({ address: b, abi: burnerAbi, eventName: "Released", args: { listingId }, fromBlock: BigInt(deployment.block ?? 0) })
      .then((logs) => setAmount(logs[0]?.args.amount)).catch(() => {});
  }, [client, b, listingId, released]);
  const sym = collectionMeta.ticker;
  const eth = released ? amount : bps && pot !== undefined ? (pot * bps) / 10_000n : undefined;
  if (!eth) return null;
  return <span className="r4 dd-burn">{released ? "Your pull set off" : "Your pull sets off"} a {e3(eth)} ETH buy-and-burn of {sym}</span>;
}
