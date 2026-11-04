"use client";

import { useEffect, useState } from "react";
import { parseAbi, parseAbiItem, type Address } from "viem";
import { useAccount, usePublicClient, useReadContract } from "wagmi";
import { deployment, collectionMeta } from "../lib/deployment";
import { fwaPoolAbi, gameAbi, poolOwnerAbi } from "../lib/abi.generated";
import { eth, num, short } from "../lib/format";
import { Ball } from "./Ball";
import { Ext } from "./Ext";
import { txUrl } from "../lib/chain";

const LOOKBACK = 50_000n; // blocks, about a week
const SHOW = 14;
const delivered = parseAbiItem("event NFTDeliveryCompleted(uint256 indexed listingId, uint256 indexed requestId, address indexed purchaser)");
const listed = parseAbiItem("event CollectionListed(uint256 indexed listingId, uint256 indexed tokenId, uint256 notional)");
const burned = parseAbiItem("event Bought(bool milestone, uint256 ethSpent, uint256 tokensBurned)");
const acquired = parseAbiItem("event Acquired(uint256 indexed tokenId, address indexed seller, address adapter, uint256 price)");
const activated = parseAbiItem("event Activated(uint256 boardSize, uint256 cash)");
const prizeListed = parseAbiItem("event Listed(uint256 indexed listingId, uint256 indexed row, uint256 price)");
const launched = parseAbiItem("event Launched(int24 startTick, uint256 coins, uint128 coinLiquidity)");
// Shapes and Packs both report a token's ETH value (IERC721Value); it reverts once the prize is redeemed
const valueAbi = parseAbi(["function valueOf(uint256 tokenId) view returns (uint256)"]);

type Item = {
  key: string; block: bigint; at?: number; tx: string;
  kind: "win" | "joined" | "burn" | "bought" | "open" | "added";
  ape?: boolean; tokenId?: bigint; nft?: Address; title: string; detail: string; who?: string;
};

/** Age against the chain's own latest block time (a fork's clock can run far from this browser's). */
const ago = (t?: number, now?: number) => {
  if (!t || !now) return "";
  const s = Math.max(0, now - t);
  return s < 60 ? `${s}s ago` : s < 3600 ? `${Math.floor(s / 60)}m ago` : s < 86_400 ? `${Math.floor(s / 3600)}h ago` : `${Math.floor(s / 86_400)}d ago`;
};

/**
 * What is happening in the game, newest first: prizes won (FWA's own delivery events, with the prize's art), Apes the
 * vault bought and Apes entering the dome (the pool owner's listings), the opening board's Shapes (the game's
 * activation, once; restocks are not shown), buy-and-burns of the coin (the burner's buys).
 * While `funding`, the market's opening too (it starts the funding period), from the deployment block.
 */
export function Activity({ pool, funding }: { pool?: Address; funding?: boolean }) {
  const client = usePublicClient();
  const { address } = useAccount();
  const { data: shapes } = useReadContract({ address: deployment.poolOwner, abi: poolOwnerAbi, functionName: "shapes" });
  const [items, setItems] = useState<Item[] | null>(null);
  const [now, setNow] = useState<number>();

  useEffect(() => {
    if (!client || !pool) return;
    let live = true;
    const load = async () => {
      const top = await client.getBlock(), head = top.number!, fromBlock = head > LOOKBACK ? head - LOOKBACK : 0n;
      const [wins, joins, burns, buys, opens, boards] = await Promise.all([
        client.getLogs({ address: pool, event: delivered, fromBlock }),
        client.getLogs({ address: deployment.poolOwner, event: listed, fromBlock }),
        client.getLogs({ address: deployment.burner, event: burned, fromBlock }),
        client.getLogs({ address: deployment.vault, event: acquired, fromBlock }),
        funding ? client.getLogs({ address: deployment.liquidity, event: launched, fromBlock: BigInt(deployment.block ?? 0) }) : [],
        client.getLogs({ address: deployment.game, event: activated, fromBlock: BigInt(deployment.block ?? 0) }),
      ]);
      const recent = [...wins.map((l) => ({ l, k: "win" as const })), ...joins.map((l) => ({ l, k: "joined" as const })), ...burns.map((l) => ({ l, k: "burn" as const })),
        ...buys.map((l) => ({ l, k: "bought" as const })), ...opens.map((l) => ({ l, k: "open" as const })),
        ...boards.map((l) => ({ l, k: "added" as const }))]
        .sort((a, z) => (a.l.blockNumber! === z.l.blockNumber! ? z.l.logIndex! - a.l.logIndex! : a.l.blockNumber! > z.l.blockNumber! ? -1 : 1))
        .slice(0, SHOW);
      const out: Item[] = [];
      for (const { l, k } of recent) {
        const base = { key: `${l.transactionHash}:${l.logIndex}`, block: l.blockNumber!, tx: l.transactionHash! };
        if (k === "win") {
          const id = (l.args as { listingId: bigint }).listingId;
          const who = (l.args as { purchaser: Address }).purchaser;
          const listing = await client.readContract({ address: pool, abi: fwaPoolAbi, functionName: "listings", args: [id] });
          const ape = listing[0].toLowerCase() === deployment.collection.toLowerCase();
          if (ape) {
            out.push({ ...base, kind: "win", ape, tokenId: listing[3], title: `${collectionMeta.short} #${listing[3]} won`, detail: `listed at ${eth(listing[5])}`, who });
          } else {
            const kind = "Shape"; // Packs are bundles of Shapes: players see one kind of ETH-backed prize
            const value = await client.readContract({ address: listing[0], abi: valueAbi, functionName: "valueOf", args: [listing[3]] }).catch(() => undefined);
            out.push({ ...base, kind: "win", ape, tokenId: listing[3], nft: listing[0], who,
              title: value !== undefined ? `${eth(value)} ${kind} won` : `${kind} #${listing[3]} won`,
              detail: value !== undefined ? `redeemable for ${eth(value)}` : `listed at ${eth(listing[5])}, since redeemed` });
          }
        } else if (k === "joined") {
          const a = l.args as { tokenId: bigint; notional: bigint };
          out.push({ ...base, kind: "joined", ape: true, tokenId: a.tokenId, title: `${collectionMeta.short} #${a.tokenId} joined the dome`, detail: `listed at ${eth(a.notional)}` });
        } else if (k === "bought") {
          const a = l.args as { tokenId: bigint; price: bigint };
          out.push({ ...base, kind: "bought", ape: true, tokenId: a.tokenId, title: `${collectionMeta.short} #${a.tokenId} bought`, detail: `by the vault for ${eth(a.price)}` });
        } else if (k === "added") {
          // the board's backing as it opened (a node without that block's state leaves the worth out); Packs are
          // bundles of Shapes, so the whole board is counted in Shapes
          const n = (l.args as { boardSize: bigint }).boardSize;
          const worth = await client.readContract({ address: deployment.game, abi: gameAbi, functionName: "inventoryBacking", blockNumber: l.blockNumber! }).catch(() => undefined);
          // its art: the board's first prize
          const [first] = await client.getLogs({ address: deployment.game, event: prizeListed, fromBlock: BigInt(deployment.block ?? 0), toBlock: l.blockNumber! });
          const listing = first ? await client.readContract({ address: pool, abi: fwaPoolAbi, functionName: "listings", args: [first.args.listingId!] }) : undefined;
          out.push({ ...base, kind: "added", tokenId: listing?.[3], nft: listing?.[0],
            title: `${n} Shapes${worth !== undefined ? ` worth ${eth(worth)}` : ""} added`, detail: "the opening prize board" });
        } else if (k === "open") {
          out.push({ ...base, kind: "open", title: "Funding period open", detail: `Trading fees fund the first ${collectionMeta.short} and the prize board` });
        } else {
          const a = l.args as { milestone: boolean; ethSpent: bigint; tokensBurned: bigint };
          out.push({ ...base, kind: "burn", title: `${num(a.tokensBurned)} ${collectionMeta.ticker} burned`, detail: `${eth(a.ethSpent)} of ${a.milestone ? `${collectionMeta.short}-win` : "game"} surplus` });
        }
      }
      const blocks = [...new Set(out.map((i) => i.block))];
      const times = new Map(await Promise.all(blocks.map(async (b) => [b, Number((await client.getBlock({ blockNumber: b })).timestamp)] as const)));
      if (live) { setItems(out.map((i) => ({ ...i, at: times.get(i.block) }))); setNow(Number(top.timestamp)); }
    };
    load().catch(() => live && setItems([]));
    const t = setInterval(() => load().catch(() => {}), 30_000);
    return () => { live = false; clearInterval(t); };
  }, [client, pool, funding]);

  return (
    <section className="activity" aria-labelledby="activity-title">
      <h2 id="activity-title">Activity</h2>
      {items === null ? <p className="note">Reading the chain…</p> : items.length === 0 ? <p className="note">Nothing yet this week.</p> : (
        <ul className="feed">
          {items.map((i) => (
            <li key={i.key} className={`feed-item ${i.kind}${i.kind === "win" && i.ape ? " big" : ""}`}>
              <span className="feed-ball">
                {i.kind === "burn" ? <span className="feed-burn" aria-hidden>BURN</span>
                  : i.kind === "open" || i.tokenId === undefined ? <span className="feed-burn open" aria-hidden>{i.kind === "open" ? "OPEN" : "BOARD"}</span>
                  : <Ball tokenId={i.tokenId!} nft={i.ape ? undefined : (i.nft ?? shapes)} fit={!i.ape} />}
              </span>
              <span className="feed-mid">
                <b>{i.title}</b>
                <span>{i.detail}{i.who ? <> · by {address && i.who.toLowerCase() === address.toLowerCase() ? "you" : short(i.who)}</> : null}</span>
              </span>
              <Ext className="feed-end" href={txUrl(i.tx)}>{ago(i.at, now)}</Ext>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
