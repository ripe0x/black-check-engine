"use client";

import { useMemo, useState } from "react";
import type { Address, Hash } from "viem";
import { useAccount, useReadContract, useReadContracts, useWriteContract } from "wagmi";
import { config, deployed, tierName } from "../lib/config";
import { engineAbi } from "../lib/abi.generated";
import { checksAbi, coinAbi, useListedEvents, useSystem } from "../lib/chain";
import { coin as fmtCoin } from "../lib/format";
import { NotDeployed } from "../components/NotDeployed";
import { TxStatus } from "../components/Tx";

type Elig = { tokenId: bigint; tier: number; survived: bigint };

export default function ComposePage() {
  if (!deployed) return <NotDeployed />;
  return <Compose />;
}

function Compose() {
  const { checks } = useSystem();
  const records = useListedEvents();
  const tokens = useMemo(
    () => (checks ? records.filter((r) => r.collection.toLowerCase() === checks.toLowerCase()).map((r) => r.tokenId) : []),
    [records, checks],
  );
  const engine = { address: config.engine, abi: engineAbi } as const;

  const reads = useReadContracts({
    contracts: tokens.flatMap((id) => [
      { ...engine, functionName: "eligible", args: [id] } as const,
      { address: checks, abi: checksAbi, functionName: "getCheck", args: [id] } as const,
      { ...engine, functionName: "survivedDraws", args: [id] } as const,
    ]),
    query: { enabled: !!checks && tokens.length > 0, refetchInterval: 15_000 },
  });
  const { data: params } = useReadContract({ ...engine, functionName: "params" });
  const graceDraws = params ? Number((params as readonly unknown[])[4]) : undefined;

  const eligible: Elig[] = useMemo(() => {
    const out: Elig[] = [];
    tokens.forEach((id, i) => {
      const ok = reads.data?.[3 * i]?.result as boolean | undefined;
      const info = reads.data?.[3 * i + 1]?.result as { stored: { divisorIndex: number } } | undefined;
      const surv = reads.data?.[3 * i + 2]?.result as bigint | undefined;
      if (ok && info && surv !== undefined) out.push({ tokenId: id, tier: Number(info.stored.divisorIndex), survived: surv });
    });
    return out;
  }, [reads.data, tokens]);

  return (
    <>
      <h1>Compose two survivors</h1>
      <p className="note">Two living Checks of the same tier that have each passed the tier&apos;s survival threshold
        can be composed into one of the next tier. You pick which token survives (and whether to swap its art). The
        composition is <b>irreversible</b>: the other Check is burned by the canonical Checks contract. If a draw wins
        either Check first, the whole transaction reverts and no coin is burned. The survivor is relisted at its new
        tier with a fresh survival count.</p>
      <p className="note">Choosing the survivor or swapping art burns the tier&apos;s coin amount. It is <b>free</b> only
        on the deterministic outcome: no swap, the survivor is the Check with more survived draws (lower ID on a tie),
        and both are past the grace window ({graceDraws === undefined ? "…" : `${graceDraws} draws`} beyond the
        threshold). A Black Check is formed separately from 64 single Checks (<code>formBlack</code>), not shown here.</p>
      {eligible.length < 2 ? (
        <div className="card">Fewer than two eligible Checks right now. Composition needs two of the same tier past
          their threshold. See <a href="/checks/">Checks</a>.</div>
      ) : (
        <ComposeForm eligible={eligible} graceDraws={graceDraws} />
      )}
    </>
  );
}

function ComposeForm({ eligible, graceDraws }: { eligible: Elig[]; graceDraws?: number }) {
  const { address } = useAccount();
  const { coin: coinAddr } = useSystem();
  const { writeContract, data: hash, error, isPending } = useWriteContract();

  const tiers = useMemo(() => [...new Set(eligible.map((e) => e.tier))].filter((t) => eligible.filter((e) => e.tier === t).length >= 2).sort(), [eligible]);
  const [tier, setTier] = useState<number | undefined>(undefined);
  const activeTier = tier ?? tiers[0];
  const pool = eligible.filter((e) => e.tier === activeTier);
  const [keep, setKeep] = useState<string>("");
  const [burn, setBurn] = useState<string>("");
  const [swap, setSwap] = useState(false);

  const keepId = keep ? BigInt(keep) : pool[0]?.tokenId;
  const burnId = burn ? BigInt(burn) : pool.find((e) => e.tokenId !== keepId)?.tokenId;

  const { data: threshold } = useReadContract({ address: config.engine, abi: engineAbi, functionName: "drawsToCompose", args: activeTier === undefined ? undefined : [BigInt(activeTier)], query: { enabled: activeTier !== undefined } });
  const { data: burnAmount } = useReadContract({ address: config.engine, abi: engineAbi, functionName: "composeBurn", args: activeTier === undefined ? undefined : [BigInt(activeTier)], query: { enabled: activeTier !== undefined } });
  const { data: allowance } = useReadContract({ address: coinAddr, abi: coinAbi, functionName: "allowance", args: [address ?? "0x0000000000000000000000000000000000000000", config.engine], query: { enabled: !!coinAddr && !!address, refetchInterval: 10_000 } });

  // Replicates Engine.compose's free-path test so the shown cost matches what the transaction will burn.
  const free = useMemo(() => {
    if (swap || threshold === undefined || graceDraws === undefined || keepId === undefined || burnId === undefined) return false;
    const k = pool.find((e) => e.tokenId === keepId);
    const b = pool.find((e) => e.tokenId === burnId);
    if (!k || !b) return false;
    const first = k.survived !== b.survived ? (k.survived > b.survived ? k : b) : (k.tokenId < b.tokenId ? k : b);
    if (first.tokenId !== keepId) return false;
    const ready = (e: Elig) => e.survived !== 0n && e.survived >= Number(threshold) + graceDraws;
    return ready(k) && ready(b);
  }, [swap, threshold, graceDraws, keepId, burnId, pool]);

  const willBurn = free ? 0n : (burnAmount as bigint | undefined) ?? 0n;
  const needsApprove = willBurn > 0n && (allowance === undefined || allowance < willBurn);

  return (
    <div className="card">
      <div className="row">
        <div>
          <label htmlFor="tier">Tier</label>
          <select id="tier" value={activeTier} onChange={(e) => { setTier(Number(e.target.value)); setKeep(""); setBurn(""); }}>
            {tiers.map((t) => <option key={t} value={t}>{tierName(t)} ({eligible.filter((e) => e.tier === t).length} eligible)</option>)}
          </select>
        </div>
        <div>
          <label htmlFor="keep">Survivor (keep)</label>
          <select id="keep" value={keepId?.toString() ?? ""} onChange={(e) => setKeep(e.target.value)}>
            {pool.map((e) => <option key={e.tokenId.toString()} value={e.tokenId.toString()}>#{e.tokenId.toString()} ({e.survived.toString()} survived)</option>)}
          </select>
        </div>
        <div>
          <label htmlFor="burn">Burn</label>
          <select id="burn" value={burnId?.toString() ?? ""} onChange={(e) => setBurn(e.target.value)}>
            {pool.filter((e) => e.tokenId !== keepId).map((e) => <option key={e.tokenId.toString()} value={e.tokenId.toString()}>#{e.tokenId.toString()} ({e.survived.toString()} survived)</option>)}
          </select>
        </div>
      </div>
      <p><label><input type="checkbox" checked={swap} onChange={(e) => setSwap(e.target.checked)} /> Swap art (survivor keeps the burned Check&apos;s visuals; never free)</label></p>
      <p className="note">Cost: {free ? <b className="ok">free (deterministic fallback)</b> : <b>{fmtCoin(willBurn)} {config.coinSymbol} burned</b>}. This is permanent.</p>
      <div className="row">
        {needsApprove ? (
          <button className="btn-outline" disabled={!address || !coinAddr} onClick={() => writeContract({ address: coinAddr!, abi: coinAbi, functionName: "approve", args: [config.engine, willBurn] })}>
            1. Approve {fmtCoin(willBurn)} {config.coinSymbol}
          </button>
        ) : null}
        <button className="btn-filled" disabled={!address || needsApprove || isPending || keepId === undefined || burnId === undefined || keepId === burnId}
          onClick={() => keepId !== undefined && burnId !== undefined && writeContract({ address: config.engine, abi: engineAbi, functionName: "compose", args: [keepId, burnId, swap] })}>
          {address ? "Compose" : "Connect a wallet"}
        </button>
      </div>
      <TxStatus hash={hash as Hash | undefined} error={error} />
    </div>
  );
}
