"use client";

import { useEffect, useState } from "react";
import type { Hash } from "viem";
import { useAccount, useBlockNumber, usePublicClient, useReadContract, useReadContracts, useWriteContract } from "wagmi";
import { deployment, collectionMeta } from "../lib/deployment";
import { burnerAbi, gameAbi, poolOwnerAbi, vaultAbi } from "../lib/abi.generated";
import { useBooks, useBuybacks, useFunding, usePrizes, useQuote } from "../lib/reads";
import { bps, eth, num, odds, short } from "../lib/format";
import { hasPendingFeeRecipient, hasPendingMigration, useAdminChanges, useMigration } from "../lib/governance";
import { addressUrl, txUrl } from "../lib/chain";
import { Ext } from "../components/Ext";
import { Stat } from "../components/Stat";
import { TxStatus } from "../components/Tx";

// Docs pages that show live figures from the contracts. Each renders nothing live before a deployment exists.

const live = (el: React.ReactNode) => (deployment.deployed ? el : <p className="note">Live figures appear once the game is deployed.</p>);

export const BooksLive = () => live(<Books />);
function Books() {
  const { data: k } = useBooks();
  const { data: f } = useFunding();
  return (
    <>
      <h2>Funding vault</h2>
      <div className="stats">
        <Stat label="Trading fees" value={eth(f?.tradingFees)} />
        <Stat label="Contributions" value={eth(f?.contributions)} />
        <Stat label="Balance" value={eth(f?.balance)} />
        <Stat label={`Short of one ${collectionMeta.short}`} value={eth(f?.shortfall)} hint={f ? `at the funding reference, ${eth(f.referencePrice)}` : ""} />
      </div>
      <h2>Game</h2>
      <div className="stats">
        <Stat label="Gameplay ETH (settled)" value={eth(k?.turnover)} />
        <Stat label="Owner proceeds" value={eth(k?.revenue)} hint={k ? `${eth(k.collectionRevenue)} from ${collectionMeta.short} wins` : ""} />
        <Stat label="Shape prize expense" value={eth(k?.prizeExpense)} />
        <Stat label="Keeper pay" value={eth(k?.keeperPaid)} hint={k ? `allowance earned ${eth(k.keeperAllowance)}` : ""} />
        <Stat label="Realised profit" value={k ? `${k.profit < 0n ? "−" : ""}${eth(k.profit < 0n ? -k.profit : k.profit)}` : "–"} hint="cumulative; losses carry forward" />
        <Stat label="Distributed" value={eth(k?.distributed)} hint={k ? `${eth(k.toVault)} to the vault, ${eth(k.toBurner)} to buybacks` : ""} />
        <Stat label="Cash / protected" value={k ? `${eth(k.cash)} / ${eth(k.protectedCash)}` : "–"} />
        <Stat label="Shapes held (backing)" value={eth(k?.inventoryBacking)} />
        <Stat label="Draws fulfilled / refunded / expired" value={k ? `${k.pullsFulfilled} / ${k.pullsRefunded} / ${k.pullsExpired}` : "–"} />
        <Stat label={`${collectionMeta.short} wins`} value={k?.collectionWins.toString() ?? "–"} />
      </div>
    </>
  );
}

export const BurnsLive = () => live(<Burns />);
function Burns() {
  const { data: b } = useBuybacks();
  const client = usePublicClient();
  const [burns, setBurns] = useState<{ milestone: boolean; eth: bigint; tokens: bigint; tx: string }[]>([]);
  useEffect(() => {
    if (!client) return;
    client.getContractEvents({ address: deployment.burner, abi: burnerAbi, eventName: "Bought", fromBlock: BigInt(deployment.block ?? 0) })
      .then((logs) => setBurns(logs.slice(-30).reverse().map((l) => ({ milestone: l.args.milestone!, eth: l.args.ethSpent!, tokens: l.args.tokensBurned!, tx: l.transactionHash }))))
      .catch(() => {});
  }, [client]);
  return (
    <>
      <h2>Totals</h2>
      <div className="stats">
        <Stat label="Ongoing: committed / spent" value={b ? `${eth(b.ongoingIn)} / ${eth(b.ongoingSpent)}` : "–"} />
        <Stat label="Milestone: released / spent" value={b ? `${eth(b.milestoneIn)} / ${eth(b.milestoneSpent)}` : "–"} />
        <Stat label="Milestone reserve waiting" value={eth(b?.milestoneReserve)} />
        <Stat label="Coins burned" value={b ? num(b.burned) : "–"} />
      </div>
      <h2>Recent burns</h2>
      {burns.length === 0 ? <p className="note">None yet.</p> : (
        <table>
          <thead><tr><th>Bucket</th><th>ETH</th><th>Coins burned</th><th>Transaction</th></tr></thead>
          <tbody>{burns.map((x) => (
            <tr key={x.tx}><td>{x.milestone ? "milestone" : "ongoing"}</td><td>{eth(x.eth)}</td><td>{num(x.tokens)}</td>
              <td><Ext href={txUrl(x.tx)}>{x.tx.slice(0, 10)}…</Ext></td></tr>
          ))}</tbody>
        </table>
      )}
    </>
  );
}

const CONTRACTS: [string, keyof typeof deployment][] = [
  ["Game ledger", "game"], ["FWA pool owner and NFT custody", "poolOwner"], ["Funding vault (trading fees, the live bid)", "vault"],
  ["Burner (buy-and-burn)", "burner"], [`${collectionMeta.ticker} coin`, "token"], ["Uniswap v4 hook", "hook"],
  ["Protocol liquidity (no withdrawal)", "liquidity"], ["Migration authority (72-hour notice)", "migration"],
  ["Sunset (auctions every Ape, burns everything)", "sunset"], ["Seaport adapter", "adapter"], ["Admin (owner of every contract)", "admin"],
  ["Owner", "owner"], ["Draw router (no privileges)", "drawRouter"], ["Lens (read only)", "lens"],
];

export const ContractsLive = () => live(
  <table><tbody>{CONTRACTS.map(([label, k]) => (
    <tr key={k}><td>{label}</td><td><Ext href={addressUrl(String(deployment[k]))}><code>{short(String(deployment[k]))}</code></Ext></td></tr>
  ))}</tbody></table>,
);

export const MigrationLive = () => live(<Migration />);
function Migration() {
  const m = useMigration();
  const now = Math.floor(Date.now() / 1000);
  if (!m) return <p className="note">Reading…</p>;
  return (
    <>
      <p>{m.started ? <><b>Started.</b> New draws have stopped; the {collectionMeta.short}s and capital go to <code>{m.successor}</code>.</> : <><b>No migration has started.</b></>}</p>
      <p>{hasPendingMigration(m) ? <>Proposed successor <code>{m.pending}</code>, {m.executableAt > now ? `executable from ${new Date(m.executableAt * 1000).toUTCString()}` : "executable now"}.</> : "No migration is proposed."}{" "}
        {hasPendingFeeRecipient(m) ? <>Proposed trading-fee recipient <code>{m.pendingFee}</code>, {m.feeExecutableAt > now ? `executable from ${new Date(m.feeExecutableAt * 1000).toUTCString()}` : "executable now"}.</> : "No change of fee recipient is proposed."}</p>
      <p className="note">Current owner: <code>{m.owner}</code></p>
    </>
  );
}

export const ChangesLive = () => live(<Changes />);
function Changes() {
  const changes = useAdminChanges();
  if (!changes.length) return <p className="note">No administrative changes yet.</p>;
  return (
    <table><thead><tr><th>Block</th><th>Change</th><th>Contract</th><th>Details</th></tr></thead>
      <tbody>{changes.map((c) => (
        <tr key={c.tx + c.event + c.contract}><td>{c.block.toString()}</td><td><b>{c.label}</b><br /><code>{c.event}</code></td>
          <td>{c.contract}</td><td><code>{c.args.length > 160 ? c.args.slice(0, 160) + "…" : c.args}</code></td></tr>
      ))}</tbody>
    </table>
  );
}

/** The listing rule's live settings, and every Ape listed with its notional, what the rule says it is due, and its odds. */
export const ApesLive = () => live(<Apes />);
function Apes() {
  const { data: prizes } = usePrizes();
  const { data: q } = useQuote();
  const { data: credit } = useReadContract({ address: deployment.poolOwner, abi: poolOwnerAbi, functionName: "creditPerApe" });
  const { data: lp } = useReadContract({ address: deployment.poolOwner, abi: poolOwnerAbi, functionName: "listingParams" });
  const { data: n } = useReadContract({ address: deployment.poolOwner, abi: poolOwnerAbi, functionName: "listedCount" });
  const ids = useReadContracts({ contracts: Array.from({ length: Number(n ?? 0n) }, (_, i) => ({ address: deployment.poolOwner, abi: poolOwnerAbi, functionName: "listedAt", args: [BigInt(i)] } as const)) });
  const listingIds = (ids.data ?? []).map((r) => r.result as bigint | undefined).filter((x): x is bigint => x !== undefined);
  const recs = useReadContracts({ contracts: listingIds.flatMap((id) => [
    { address: deployment.poolOwner, abi: poolOwnerAbi, functionName: "cListings", args: [id] } as const,
    { address: deployment.poolOwner, abi: poolOwnerAbi, functionName: "notionalOf", args: [id] } as const,
  ]) });
  const probability = new Map((prizes ?? []).filter((p) => p.collection).map((p) => [p.listingId.toString(), p.probabilityE18]));
  return (
    <>
      <h2>The rule now</h2>
      <div className="stats">
        <Stat label="Opens at" value={lp ? `${Number(lp.startBps) / 100}% of its price, at least ${eth(lp.minNotionalWei)}` : "–"} />
        <Stat label="Falls by" value={lp ? `${Number(lp.decayBps) / 10_000} ETH per ETH credited` : "–"} />
        <Stat label="And by" value={lp ? (lp.dailyDecayBps ? `${Number(lp.dailyDecayBps) / 100}% of its price a day` : "nothing over time (off)") : "–"} />
        <Stat label="Never below" value={lp ? eth(lp.minNotionalWei) : "–"} />
        <Stat label="Exposure / target" value={q ? `${bps(q.exposureBps)} / ${bps(q.targetBps)}` : "–"} />
        <Stat label={`Gameplay credited to each ${collectionMeta.short}`} value={eth(credit)} />
      </div>
      <h2>{collectionMeta.short}s listed</h2>
      <table>
        <thead><tr><th>{collectionMeta.short}</th><th>Listed at</th><th>Due by the rule</th><th>Chance per draw</th></tr></thead>
        <tbody>{listingIds.map((id, i) => {
          const v = recs.data?.[2 * i]?.result as readonly [bigint, bigint, bigint, boolean, bigint] | undefined;
          const due = recs.data?.[2 * i + 1]?.result as bigint | undefined;
          if (!v) return null;
          return <tr key={id.toString()}><td>#{v[0].toString()}</td><td>{eth(v[1])}</td><td>{due !== undefined && due < v[1] ? `${eth(due)} (repriced at the next upkeep)` : eth(due)}</td><td>{odds(probability.get(id.toString()))}</td></tr>;
        })}</tbody>
      </table>
    </>
  );
}

/** The board's live size against what the Apes need. */
export const BoardLive = () => live(<Board />);
function Board() {
  const { data: q } = useQuote();
  const { data: turnover } = useReadContract({ address: deployment.game, abi: gameAbi, functionName: "turnover" });
  return (
    <div className="stats">
      <Stat label="Prize rows" value={q ? q.boardSize.toString() : "–"} hint={q && q.rowsShort > 0n ? `${q.rowsShort} more needed` : undefined} />
      <Stat label={`${collectionMeta.short}s in the draw`} value={q ? q.apesListed.toString() : "–"} hint={q && q.apesWaiting > 0n ? `${q.apesWaiting} waiting for rows` : undefined} />
      <Stat label="Exposure / target" value={q ? `${bps(q.exposureBps)} / ${bps(q.targetBps)}` : "–"} />
      <Stat label="Settled gameplay ETH" value={eth(turnover)} />
    </div>
  );
}

/** The live bid's settings and state, from the vault. */
export const BidLive = () => live(<Bid />);
function Bid() {
  const { data: bid } = useReadContract({ address: deployment.vault, abi: vaultAbi, functionName: "liveBid", query: { refetchInterval: 15_000 } });
  const { data: threshold } = useReadContract({ address: deployment.vault, abi: vaultAbi, functionName: "activationThreshold" });
  const { data: last } = useReadContract({ address: deployment.vault, abi: vaultAbi, functionName: "lastPrice" });
  const { data: ceiling } = useReadContract({ address: deployment.vault, abi: vaultAbi, functionName: "bidCeiling" });
  const { data: p } = useReadContract({ address: deployment.vault, abi: vaultAbi, functionName: "bidParams" });
  return (
    <div className="stats">
      <Stat label="Live bid" value={eth(bid)} />
      <Stat label="Last price paid" value={eth(last)} />
      <Stat label="Fills at once up to" value={eth(threshold)} hint={p ? `${Number(p.thresholdBps) / 100}% of the last price` : undefined} />
      <Stat label="Then, per sweep" value={p ? eth(p.maxSweepWei) : "–"} hint={p ? `at most once per ${p.minBlocksBetweenSweeps} blocks` : undefined} />
      <Stat label="Slower above" value={ceiling !== undefined && ceiling < 2n ** 255n ? eth(ceiling) : "no ceiling"} hint={p && p.ceilingBps > 0n ? `${Number(p.ceilingBps) / 100}% of the last price` : undefined} />
    </div>
  );
}

/** Anyone may sweep available ETH into the bid; the vault rewards it. */
export const SweepLive = () => live(<Sweep />);
function Sweep() {
  const { address } = useAccount();
  const { data: nextSweep } = useReadContract({ address: deployment.vault, abi: vaultAbi, functionName: "nextSweepBlock", query: { refetchInterval: 15_000 } });
  const { data: block } = useBlockNumber({ watch: true });
  const { writeContract, data: hash, error } = useWriteContract();
  return (
    <>
      <p>Next metered sweep: {nextSweep !== undefined && block !== undefined ? (block >= nextSweep ? "now" : `in ${(nextSweep - block).toString()} blocks`) : "–"}.</p>
      <button className="btn-outline" disabled={!address} onClick={() => writeContract({ chainId: deployment.chainId, address: deployment.vault, abi: vaultAbi, functionName: "sweep", args: [] })}>Sweep</button>
      <TxStatus hash={hash as Hash | undefined} error={error} />
    </>
  );
}
