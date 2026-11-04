"use client";

import { useMemo, useState } from "react";
import { formatEther, maxUint256, type Address, type Hash } from "viem";
import { useAccount, useReadContract, useReadContracts, useWriteContract } from "wagmi";
import { deployment, collectionMeta } from "../lib/deployment";
import { deskAbi, poolOwnerAbi, tokenAbi } from "../lib/abi.generated";
import { ethUp } from "../lib/format";
import { NotDeployed } from "../components/NotDeployed";
import { TxStatus } from "../components/Tx";

const TIERS = ["80", "40", "20", "10", "5", "4", "1", "Black"];
const on = { enabled: deployment.deployed, refetchInterval: 15_000 };

type Row = { listingId: bigint; tokenId: bigint; tier: number; draws: bigint; notional: bigint; eligible: boolean };

export default function Checks() {
  if (!deployment.deployed) return <NotDeployed />;
  return <Inner />;
}

/** Every Check in the draw (D002, D003, D005, D008): its tier, the price that sets its odds, the draws it has
 *  survived, and whether it can be composed; composition and buyouts go through the desk, in one transaction each. */
function Inner() {
  const rows = useRows();
  const { data: cp } = useReadContract({ address: deployment.desk, abi: deskAbi, functionName: "composeParams", query: on });
  const [picked, setPicked] = useState<bigint[]>([]);
  const toggle = (id: bigint) =>
    setPicked((p) => (p.includes(id) ? p.filter((x) => x !== id) : p.length < 2 ? [...p, id] : [p[1], id]));
  return (
    <div className="page">
      <h1>Checks in the draw</h1>
      <p className="note">
        A Check survives a draw when the draw gives out any prize but not it. Each survived draw lowers the price that
        sets its odds by {cp ? "the published rate" : "…"}, down to a floor, so a long survivor gets easier to win. After{" "}
        {cp ? `${cp.drawsToCompose[0]} survived draws` : "enough survived draws"} two Checks of the same tier can be
        composed: anyone may choose which survives for a coin burn, and {cp ? `${cp.graceDraws}` : "some"} draws later
        the default outcome is free. Every Check, a Black Check included, can always be won.
      </p>
      {rows === undefined ? <p className="note">Loading…</p> : rows.length === 0 ? (
        <p className="note">No Check is in the draw right now.</p>
      ) : (
        <div className="table-wrap"><table className="table">
          <thead>
            <tr><th /><th>Check</th><th>Tier</th><th>Odds price</th><th>Survived</th><th>Composable</th><th /></tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={String(r.listingId)}>
                <td><input type="checkbox" aria-label={`select Check #${r.tokenId}`} checked={picked.includes(r.listingId)}
                  disabled={!r.eligible} onChange={() => toggle(r.listingId)} /></td>
                <td>#{String(r.tokenId)}</td>
                <td>{TIERS[r.tier] ?? "?"}</td>
                <td>{ethUp(r.notional)}</td>
                <td>{String(r.draws)}</td>
                <td>{r.eligible ? "yes" : "not yet"}</td>
                <td><BuyButton listingId={r.listingId} /></td>
              </tr>
            ))}
          </tbody>
        </table></div>
      )}
      <Compose picked={picked} rows={rows ?? []} />
    </div>
  );
}

function useRows(): Row[] | undefined {
  const { data: count } = useReadContract({ address: deployment.poolOwner, abi: poolOwnerAbi, functionName: "listedCount", query: on });
  const n = Number(count ?? 0n);
  const { data: ids } = useReadContracts({
    contracts: Array.from({ length: n }, (_, i) => ({
      address: deployment.poolOwner, abi: poolOwnerAbi, functionName: "listedAt" as const, args: [BigInt(i)] as const,
    })),
    query: { ...on, enabled: on.enabled && n > 0 },
  });
  const listingIds = useMemo(() => (ids ?? []).map((x) => x.result as bigint | undefined).filter((x): x is bigint => x !== undefined), [ids]);
  const { data: info } = useReadContracts({
    contracts: listingIds.flatMap((id) => [
      { address: deployment.desk, abi: deskAbi, functionName: "listingInfo" as const, args: [id] as const },
      { address: deployment.desk, abi: deskAbi, functionName: "eligible" as const, args: [id] as const },
      { address: deployment.poolOwner, abi: poolOwnerAbi, functionName: "cListings" as const, args: [id] as const },
    ]),
    query: { ...on, enabled: on.enabled && listingIds.length > 0 },
  });
  if (count === undefined) return undefined;
  if (n === 0) return [];
  if (!info) return undefined;
  const out: Row[] = [];
  listingIds.forEach((listingId, i) => {
    const li = info[3 * i]?.result as readonly [bigint, number, bigint] | undefined;
    const el = info[3 * i + 1]?.result as boolean | undefined;
    const cl = info[3 * i + 2]?.result as readonly [bigint, bigint, bigint, bigint, boolean, bigint] | undefined;
    if (!li || !cl || li[1] === 255) return;
    out.push({ listingId, tokenId: li[0], tier: li[1], draws: li[2], notional: cl[1], eligible: !!el });
  });
  return out.sort((a, b) => (a.tier !== b.tier ? b.tier - a.tier : Number(b.draws - a.draws)));
}

function BuyButton({ listingId }: { listingId: bigint }) {
  const { address } = useAccount();
  const { data: price } = useReadContract({ address: deployment.desk, abi: deskAbi, functionName: "ethPrice", args: [listingId], query: on });
  const { writeContract, data: hash, error, isPending } = useWriteContract();
  if (price === undefined) return null;
  return (
    <span>
      <button type="button" className="btn-outline" disabled={!address || isPending}
        title="Buy this Check now: it leaves the draw and the price funds new Checks"
        onClick={() => writeContract({ address: deployment.desk, abi: deskAbi, functionName: "buyWithEth", args: [listingId], value: price })}>
        Buy {ethUp(price)}
      </button>
      <TxStatus hash={hash as Hash | undefined} error={error} />
    </span>
  );
}

function Compose({ picked, rows }: { picked: bigint[]; rows: Row[] }) {
  const { address } = useAccount();
  const [swap, setSwap] = useState(false);
  const [keep, burn] = picked;
  const ready = picked.length === 2;
  const { data: cost, error: costError } = useReadContract({
    address: deployment.desk, abi: deskAbi, functionName: "composeCost", args: ready ? [keep, burn, swap] : undefined,
    query: { ...on, enabled: on.enabled && ready },
  });
  const { data: allowance } = useReadContract({
    address: deployment.token, abi: tokenAbi, functionName: "allowance",
    args: address ? [address, deployment.desk as Address] : undefined, query: { ...on, enabled: on.enabled && !!address },
  });
  const approve = useWriteContract();
  const compose = useWriteContract();
  const keepRow = rows.find((r) => r.listingId === keep);
  const burnRow = rows.find((r) => r.listingId === burn);
  if (!ready) return <p className="note">Select two composable Checks of the same tier to compose them.</p>;
  const needsApproval = cost !== undefined && cost > 0n && (allowance ?? 0n) < cost;
  return (
    <div className="card">
      <h2>Compose</h2>
      <p>
        #{String(keepRow?.tokenId)} survives at the next tier; #{String(burnRow?.tokenId)} is burned by Checks.
        <label> <input type="checkbox" checked={swap} onChange={(e) => setSwap(e.target.checked)} /> keep the burned
          Check&apos;s art</label>
      </p>
      {costError ? <p className="err">Not composable: different tiers, or a Check not yet eligible.</p> : (
        <p className="note">
          {cost === undefined ? "…" : cost === 0n ? "Free: the default outcome after the grace."
            : `Burns ${Number(formatEther(cost)).toLocaleString()} ${collectionMeta.ticker} from your wallet.`}
        </p>
      )}
      {needsApproval ? (
        <button type="button" className="btn-outline" disabled={!address || approve.isPending}
          onClick={() => approve.writeContract({ address: deployment.token, abi: tokenAbi, functionName: "approve", args: [deployment.desk, maxUint256] })}>
          Allow the desk to burn {collectionMeta.ticker}
        </button>
      ) : (
        <button type="button" className="btn-filled" disabled={!address || cost === undefined || compose.isPending}
          onClick={() => compose.writeContract({ address: deployment.desk, abi: deskAbi, functionName: "compose", args: [keep, burn, swap] })}>
          Compose
        </button>
      )}
      <TxStatus hash={(approve.data ?? compose.data) as Hash | undefined} error={approve.error ?? compose.error} />
    </div>
  );
}
