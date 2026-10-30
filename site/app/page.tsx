"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { decodeFunctionResult, encodeFunctionData, type Address, type Hash } from "viem";
import { useAccount, useGasPrice, usePublicClient, useReadContract, useReadContracts, useWriteContract } from "wagmi";
import { config, deployed, tierName } from "./lib/config";
import { fwaPoolAbi } from "./lib/abi.generated";
import { useCheckSvg, useListedEvents, useSystem } from "./lib/chain";
import { eth, gwei, odds, short } from "./lib/format";
import { NotDeployed } from "./components/NotDeployed";
import { Stat } from "./components/Stat";
import { TxStatus } from "./components/Tx";

const ZERO = "0x0000000000000000000000000000000000000000" as const;
// FWA ListingStatus.Active and AcquisitionStatus labels (IFWA.sol enum order).
const ACTIVE = 1;
const ACQ_STATUS = ["none", "pending", "fulfilled", "expired", "refunded", "ready", "timed out", "delivery pending", "delivery refunded"];

type Live = { listingId: bigint; tokenId: bigint; weight: bigint; price: bigint; isCheck: boolean };

export default function PlayPage() {
  if (!deployed) return <NotDeployed />;
  return <Play />;
}

function Play() {
  const { pool, checks } = useSystem();
  const records = useListedEvents();
  const { data: totalWeight } = useReadContract({ address: pool, abi: fwaPoolAbi, functionName: "totalWeight", query: { enabled: !!pool, refetchInterval: 12_000 } });
  const { data: open } = useReadContract({ address: pool, abi: fwaPoolAbi, functionName: "localPurchasesEnabled", query: { enabled: !!pool, refetchInterval: 8_000 } });

  const listingReads = useReadContracts({
    contracts: records.map((r) => ({ address: pool, abi: fwaPoolAbi, functionName: "listings", args: [r.listingId] }) as const),
    query: { enabled: !!pool && records.length > 0, refetchInterval: 12_000 },
  });

  const live: Live[] = useMemo(() => {
    const out: Live[] = [];
    (listingReads.data ?? []).forEach((res, i) => {
      if (res.status !== "success") return;
      const v = res.result as readonly [Address, Address, Address, bigint, bigint, bigint, bigint, number];
      if (Number(v[7]) !== ACTIVE) return;
      out.push({ listingId: records[i].listingId, tokenId: v[3], weight: v[4], price: v[5], isCheck: !!checks && records[i].collection.toLowerCase() === checks.toLowerCase() });
    });
    return out;
  }, [listingReads.data, records, checks]);

  const tw = totalWeight ? Number(totalWeight) : 0;
  const checkList = live.filter((l) => l.isCheck);
  const shapeList = live.filter((l) => !l.isCheck);
  const anyCheck = tw > 0 ? checkList.reduce((a, l) => a + Number(l.weight), 0) / tw : 0;

  return (
    <>
      <h1>Play: draw for a Check</h1>
      <p className="note">Each draw asks FWA&apos;s pool to pick one listed NFT at random, weighted by inverse notional:
        a lower notional means a bigger weight and better odds. Buying a draw is a bet on chance, not a purchase of a
        chosen Check. Odds and the price are read live from the pool and change as prizes are won, listed and repriced.
        You buy directly from the FWA pool; there is no router.</p>

      <div className="stats">
        <Stat label="Chance of any Check per draw" value={odds(anyCheck)} hint={`${checkList.length} Check${checkList.length === 1 ? "" : "s"} in the draw`} />
        <Stat label="Items in the draw" value={live.length} hint={`${shapeList.length} Shape${shapeList.length === 1 ? "" : "s"} + ${checkList.length} Check${checkList.length === 1 ? "" : "s"}`} />
        <Stat label="Draws open" value={open === undefined ? "–" : open ? "yes" : "halted / closed"} />
      </div>

      <DrawPanel pool={pool} open={!!open} />

      <h2 style={{ marginTop: 24 }}>Checks in the draw</h2>
      {checkList.length === 0 ? (
        <div className="card"><b>No Check is in the draw right now.</b> A draw can still win a Shape. A Check joins when
          the protocol lists one. Until then no draw can win a Check.</div>
      ) : (
        <div className="grid">
          {checkList.map((l) => <CheckPrize key={l.listingId.toString()} l={l} checks={checks} tw={tw} />)}
        </div>
      )}

      {shapeList.length > 0 ? (
        <div className="card">
          <h2>Shapes in the draw</h2>
          <p className="note">Shapes are ETH-backed prizes listed at backing plus a markup. Listed value is not what you
            redeem.</p>
          <div className="scroll">
            <table>
              <thead><tr><th>Listing</th><th>Token</th><th>Notional</th><th>Odds / draw</th></tr></thead>
              <tbody>
                {shapeList.map((l) => (
                  <tr key={l.listingId.toString()}>
                    <td>{l.listingId.toString()}</td><td>#{l.tokenId.toString()}</td><td>{eth(l.price, 4)}</td>
                    <td>{odds(tw > 0 ? Number(l.weight) / tw : 0)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      ) : null}
    </>
  );
}

function CheckPrize({ l, checks, tw }: { l: Live; checks?: Address; tw: number }) {
  const img = useCheckSvg(checks, l.tokenId);
  return (
    <div className="tile">
      {img ? <img src={img} alt={`Check #${l.tokenId}`} /> : <div className="ph">Check #{l.tokenId.toString()}</div>}
      <div className="body">
        <div><b>Check #{l.tokenId.toString()}</b></div>
        <div className="big-odds">{odds(tw > 0 ? Number(l.weight) / tw : 0)}</div>
        <div className="note">per draw · notional {eth(l.price, 3)}</div>
      </div>
    </div>
  );
}

function DrawPanel({ pool, open }: { pool?: Address; open: boolean }) {
  const { address } = useAccount();
  const client = usePublicClient();
  const { data: gasPrice } = useGasPrice({ query: { refetchInterval: 12_000 } });
  const { data: version } = useReadContract({ address: pool, abi: fwaPoolAbi, functionName: "inventoryVersion", query: { enabled: !!pool, refetchInterval: 12_000 } });
  const [quote, setQuote] = useState<{ fee: bigint; vrf: bigint; total: bigint } | null>(null);
  const { writeContract, data: hash, error, isPending } = useWriteContract();

  // FWA's VRF fee scales with the transaction's gas price, so quote at the current gas price (prior art pattern). A
  // plain eth_call would price it at zero gas. The acquisition fee is the live weighted quote.
  useEffect(() => {
    if (!client || !pool) return;
    let alive = true;
    (async () => {
      const data = encodeFunctionData({ abi: fwaPoolAbi, functionName: "quoteAcquisitionPrice", args: [1n] });
      const r = await client.call({ to: pool, data, gasPrice: gasPrice ?? undefined });
      const [fee, vrf, total] = decodeFunctionResult({ abi: fwaPoolAbi, functionName: "quoteAcquisitionPrice", data: r.data! }) as readonly [bigint, bigint, bigint];
      if (alive) setQuote({ fee, vrf, total });
    })().catch(() => alive && setQuote(null));
    return () => { alive = false; };
  }, [client, pool, gasPrice, hash]);

  const vrfMargin = quote ? (quote.vrf * 12n) / 10n : 0n; // FWA refunds any VRF overpayment to the buyer
  const draw = () => {
    if (!quote || !address || !pool || version === undefined) return;
    writeContract({
      address: pool,
      abi: fwaPoolAbi,
      functionName: "acquire",
      // purchaser = you; maxAcquisitionFee = the live fee; minWeightedValue 0; negative-slippage tolerance 10%
      // (FWA's UI default); pin the inventory version; 15-minute deadline. value covers the fee and the VRF fee.
      args: [address, quote.fee, 0n, 1000n, version as bigint, BigInt(Math.floor(Date.now() / 1000) + 900)],
      value: quote.fee + vrfMargin,
      gasPrice: gasPrice ?? undefined,
    });
  };

  return (
    <div className="card">
      <h2>One draw <span className="pill live">live quote</span></h2>
      <div className="stats">
        <Stat label="Ticket (acquisition fee)" value={eth(quote?.fee, 5)} hint="FWA's weighted price for one draw" />
        <Stat label="Randomness fee" value={eth(quote?.vrf, 5)} hint={`FWA VRF fee at ${gwei(gasPrice)}; scales with gas; excess refunded`} />
        <Stat label="Total to send" value={eth(quote ? quote.fee + vrfMargin : undefined, 5)} hint="ticket + VRF (with margin)" />
      </div>
      <p className="note">The ticket and randomness fee above are a <b>live</b> on-chain quote at the current gas price,
        not an illustration. Your own transaction gas is extra and paid to the network. Most draws return less than they
        cost; a listed notional above the ticket is not a profit once fees and gas are counted.</p>
      {!open ? <p className="err">Draws are closed right now: the protocol is halted, retiring or between listings. Nothing is charged.</p> : null}
      <button className="btn-filled big" disabled={!address || !quote || !open || isPending || version === undefined} onClick={draw}>
        {address ? "Draw once" : "Connect a wallet to draw"}
      </button>
      <TxStatus hash={hash as Hash | undefined} error={error} />
      <p className="note">Your prize is delivered when the randomness settles. If the pool moves beyond the slippage
        tolerance first, FWA refunds your ticket to claim below.</p>
      <YourDraws pool={pool} />
    </div>
  );
}

/// The connected wallet's own draws (from FWA's AcquisitionRequested events) with live status, and any refund credit.
function YourDraws({ pool }: { pool?: Address }) {
  const { address } = useAccount();
  const client = usePublicClient();
  const { writeContract, data: hash, error, isPending } = useWriteContract();
  const [reqs, setReqs] = useState<bigint[]>([]);
  const { data: credit } = useReadContract({
    address: pool, abi: fwaPoolAbi, functionName: "acquisitionRefundCredit", args: [address ?? ZERO],
    query: { enabled: !!pool && !!address, refetchInterval: 12_000 },
  });

  useEffect(() => {
    if (!client || !pool || !address) return;
    let alive = true;
    (async () => {
      const head = await client.getBlockNumber();
      const logs = await client.getContractEvents({
        address: pool, abi: fwaPoolAbi, eventName: "AcquisitionRequested", args: { purchaser: address },
        fromBlock: head > 200_000n ? head - 200_000n : 0n,
      });
      const ids = [...new Set(logs.map((l) => (l.args as { requestId?: bigint }).requestId).filter((x): x is bigint => x !== undefined))];
      if (alive) setReqs(ids.slice(-10).reverse());
    })().catch(() => {});
    return () => { alive = false; };
  }, [client, pool, address, hash]);

  const statuses = useReadContracts({
    contracts: reqs.map((id) => ({ address: pool, abi: fwaPoolAbi, functionName: "acquisitions", args: [id] }) as const),
    query: { enabled: !!pool && reqs.length > 0, refetchInterval: 10_000 },
  });

  if (!pool || !address) return null;
  if (reqs.length === 0 && (!credit || credit === 0n)) return <p className="note">No draws from this wallet yet.</p>;
  return (
    <div className="card">
      <h3>Your draws</h3>
      {credit && credit > 0n ? (
        <p>Refund credit: <b>{eth(credit, 5)}</b>{" "}
          <button className="btn-outline" disabled={isPending} onClick={() => writeContract({ address: pool, abi: fwaPoolAbi, functionName: "withdrawAcquisitionRefund" })}>Withdraw refund</button></p>
      ) : null}
      {reqs.length > 0 ? (
        <div className="scroll">
          <table>
            <thead><tr><th>Request</th><th>Status</th></tr></thead>
            <tbody>
              {reqs.map((id, i) => {
                const r = statuses.data?.[i]?.result as readonly [Address, bigint, bigint, bigint, number] | undefined;
                const s = r ? ACQ_STATUS[Number(r[4])] ?? "?" : "…";
                const settled = r && [2, 3, 4, 7, 8].includes(Number(r[4]));
                return <tr key={id.toString()}><td>{short(`0x${id.toString(16)}`)}</td><td className={settled ? "" : "ok"}>{s}</td></tr>;
              })}
            </tbody>
          </table>
        </div>
      ) : null}
      <TxStatus hash={hash as Hash | undefined} error={error} />
    </div>
  );
}
