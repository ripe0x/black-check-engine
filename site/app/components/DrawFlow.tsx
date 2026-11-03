"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";
import { flushSync } from "react-dom";
import { decodeErrorResult, encodeFunctionData, formatEther, parseAbi, parseEventLogs, type Address, type Hash, type Hex } from "viem";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import { useBalance, useCapabilities, useConfig, usePublicClient, useReadContract, useSendCalls, useSendTransaction, useSwitchChain, useWriteContract } from "wagmi";
import { waitForCallsStatus } from "wagmi/actions";
import { useQueryClient } from "@tanstack/react-query";
import { HELD_KEY } from "../lib/held";
import { deployment, collectionMeta } from "../lib/deployment";
import { fwaPoolAbi, poolOwnerAbi } from "../lib/abi.generated";
import { chainNow, txUrl } from "../lib/chain";
import { amtDown, amtUp, fmtEth } from "../lib/format";
import { Art, Ball } from "./Ball";
import { Ext } from "./Ext";
import { BurnLine } from "./BurnPot";

export const MAX_DRAWS = 5; // FWA's per-transaction limit (maxAcquisitionsPerTx) at launch: one VRF request per draw

const events = parseAbi([
  "event AcquisitionRequested(uint256 indexed requestId, address indexed purchaser, uint256 acquisitionFee, uint256 totalWeight)",
  "event AcquisitionRefundedNoListing(uint256 indexed requestId, address indexed purchaser, uint256 refund)",
]);
// FWA's own errors, which the router passes through: the ones a draw can hit between its quote and its inclusion
const fwaErrors = parseAbi([
  "error TransactionExpired(uint256 deadline)",
  "error AcquisitionFeeTooHigh()",
  "error InventoryVersionMismatch(uint256 expected, uint256 actual)",
  "error InventoryChangeCooldownActive(uint256 purchasesResumeAt)",
  "error PoolValueTooLow()",
  "error InsufficientPayment()",
]);
const valueAbi = parseAbi(["function valueOf(uint256 tokenId) view returns (uint256)"]);
const vrfAbi = parseAbi(["function requestStatus(uint256) view returns (uint8)"]);
// cashing won prizes out for their ETH without drawing: Shapes in one batch, each Pack on its own
const cashAbi = parseAbi(["function redeemBatch(uint256[] tokenIds) returns (uint256)", "function redeem(uint256 tokenId)"]);
const nftAbi = parseAbi(["function ownerOf(uint256 tokenId) view returns (address)",
  "function isApprovedForAll(address owner, address operator) view returns (bool)", "function setApprovalForAll(address operator, bool approved)"]);
// FWA AcquisitionStatus: Pending 1, Fulfilled 2, Expired 3, Refunded 4, Ready 5, TimedOut 6, DeliveryPending 7,
// DeliveryRefunded 8. A draw's request id is also its VRF service request id; the service's WordStored (2) and
// EmptyWordArrayStored (3) mean the word arrived but was not handed to the pool yet (deferred for gas).
// a sent draw with no receipt after STUCK_MS is checked every CHECK_MS for why, and the player may stop waiting
const STUCK_MS = 60_000, CHECK_MS = 10_000;
type Stuck = "dropped" | "replaced" | "order" | "slow";
const STUCK_NOTE: Record<Stuck, string> = {
  dropped: "The network no longer has this transaction, so nothing was drawn.",
  replaced: "Another transaction from your wallet took its place, so this one can't go through.",
  order: "It's waiting behind an earlier transaction from your wallet that hasn't gone through. Speed up or cancel that one in your wallet.",
  slow: "Not confirmed yet. Gas may be high: you can speed it up in your wallet.",
};
const PENDING = 1, FULFILLED = 2, EXPIRED = 3, REFUNDED = 4, READY = 5, TIMED_OUT = 6, DELIVERY_PENDING = 7;
const ENDED = new Set([FULFILLED, EXPIRED, REFUNDED, DELIVERY_PENDING, 8]);
const REFUNDS = new Set([EXPIRED, REFUNDED, 8]);
const WORD_STORED = new Set([2, 3]);

export type Block = "connect" | "network" | "paused" | null;
export type DrawApi = {
  fee?: bigint; quoting: boolean; ready: boolean; block: Block; reason: string | null;
  address?: Address; pool?: Address; send: () => Promise<Hash>; requote: () => void;
  /** What the draws cost now, the randomness fee included. */
  value?: bigint;
  /** The most a sent draw can take: `value` with the randomness fee's 30% margin (the unused part is refunded). */
  maxValue?: bigint;
  /** The draw paid with these won Shapes and Packs (worth `back`), redeemed by the router in the same transaction. */
  sendRedeem: (shapeIds: bigint[], packIds: bigint[], back: bigint) => Promise<Hash>;
  redeemCall: (shapeIds: bigint[], packIds: bigint[], back: bigint) => Promise<{ to: Address; data: Hex; value: bigint }>;
};
/** An Ape in the draw when the draw was sent: its odds and listed price then (a won Ape leaves the board). */
export type ApeOdds = { listingId: bigint; probabilityE18: bigint; price: bigint };

type Prize = { ape: boolean; tokenId: bigint; nft: Address; listingId: bigint; value?: bigint };
type Draw = { req: bigint; fee: bigint; status: number; word?: boolean; prize?: Prize; refund?: string };
type Msg = { title: string; sub: string; warn?: boolean };
// a draw in flight, kept per wallet so a reload picks it up again (the copy says it is safe to leave)
type Run = { hash: Hash; block?: bigint; count: number; draws?: Draw[]; apes: ApeOdds[] };
type View = "idle" | "wallet" | "redeeming" | "sent" | "picking" | "reveal" | "results";

// keyed by game too, so a new deployment on the same chain does not pick up (or hide) a draw made at the old one
const storeKey = (a: Address) => `cg-draw-${deployment.chainId}-${deployment.game.toLowerCase()}-${a.toLowerCase()}`;
const save = (a: Address, r: Run | null) => {
  try {
    if (r) localStorage.setItem(storeKey(a), JSON.stringify(r, (_, v) => (typeof v === "bigint" ? `${v}n` : v)));
    else localStorage.removeItem(storeKey(a));
  } catch {
    // storage unavailable: the draw is followed for this page view only
  }
};
const load = (a: Address): Run | null => {
  try {
    const s = localStorage.getItem(storeKey(a));
    return s ? JSON.parse(s, (_, v) => (typeof v === "string" && /^\d+n$/.test(v) ? BigInt(v.slice(0, -1)) : v)) : null;
  } catch {
    return null;
  }
};

/** An amount as the site writes it (lib/format `fmt`), unsigned: "0.02", "0.0012". */
const amt = (wei: bigint) => fmtEth(Number(formatEther(wei < 0n ? -wei : wei)));
const eth = (wei: bigint) => `${amt(wei)} ETH`;
/** What the player receives (a refund, a withdrawal, a prize's backing, redeem change): rounded down. */
const got = (wei: bigint) => `${amtDown(wei)} ETH`;
const oneIn = (p: bigint) => `1 in ${Math.round(1e18 / Number(p)).toLocaleString()}`;
const draws = (n: number) => `${n} draw${n === 1 ? "" : "s"}`;
const ape = collectionMeta.short;

/** What a failed send means to the player: cancelled, the wallet failed, or the contract refused (and why). */
function why(e: unknown): Msg {
  const err = e as { name?: string; shortMessage?: string; message?: string; code?: number; walk?: (f: (x: unknown) => boolean) => unknown };
  const text = `${err.name ?? ""} ${err.shortMessage ?? ""} ${err.message ?? ""}`;
  if (err.code === 4001 || /UserRejected|rejected|denied|cancel/i.test(text)) {
    return { title: "Cancelled in wallet", sub: "Nothing was sent." };
  }
  // checked before anything is sent (a prize won since the price was shown moved it): no transaction, no gas
  if (text.includes("PriceMoved")) {
    return { title: "Price updated", sub: "The ticket moved since it was shown. Nothing was sent: check the new price and draw again." };
  }
  // the reason: from the revert data, or (when a wallet passes only text) its name in the message
  const data = (err.walk?.((x) => typeof (x as { data?: unknown }).data === "string") as { data?: Hex } | undefined)?.data;
  let name = "";
  try {
    if (data) name = decodeErrorResult({ abi: fwaErrors, data }).errorName;
  } catch {
    // not one of FWA's
  }
  name ||= fwaErrors.map((x) => x.name).find((x) => text.includes(x)) ?? "";
  const cause = name === "TransactionExpired" ? "Deadline passed." : name === "AcquisitionFeeTooHigh" ? "Fee rose above your cap."
    : name.startsWith("Inventory") ? "Prize pool changed." : name === "PoolValueTooLow" ? "Pool fell below its floor."
      : name === "InsufficientPayment" ? "Gas rose past the randomness fee sent." : null;
  if (cause || /revert/i.test(text)) {
    return { title: "Draw didn't go through", sub: `${cause ?? ""} Only gas was spent. Price refreshed.`.trim(), warn: true };
  }
  return { title: "Wallet couldn't send", sub: "Try again.", warn: true };
}

const isPack = (x: Draw) => x.prize?.nft.toLowerCase() === deployment.packs.toLowerCase();
const prizeName = (x: Draw) => `${isPack(x) ? "Shapes Pack" : "Shape"} ${x.prize!.tokenId}`;
// the prize's page on the Shapes site; a Pack's names its contract, as this game's Packs are its own deployment of the
// Packs contract, not the canonical one (that page is still to be built: ripe0x/shape-packs#1)
const prizeUrl = (x: Draw) => `https://shapes.ripe.wtf/${isPack(x) ? `pack/${x.prize!.nft}` : "shape"}/${x.prize!.tokenId}`;
const sum = (xs: Draw[]) => xs.reduce((t, x) => t + (x.prize?.value ?? 0n), 0n);

/** What the draw asks of the dome: the blower (0-1) and the won Apes to raise (token ids). */
export type DomeCue = { mixing: number; lift: bigint[] };

const LAND_MS = 900, LIFT_MS = 1600; // the blower stops and the balls drop; then a won Ape rises and glows

/** A state change as a view transition where the browser has them (a won Ape's ball flies from the dome to its
 *  screen, `ape-<id>` on both); otherwise, or with reduced motion, at once. */
function morph(fn: () => void) {
  if (!document.startViewTransition || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return fn();
  document.startViewTransition(() => flushSync(fn));
}
const morphs = () => typeof document !== "undefined" && !!document.startViewTransition && !window.matchMedia("(prefers-reduced-motion: reduce)").matches;

/**
 * The draw, start to finish, around the dome: pick how many, confirm in the wallet, then each draw is followed on
 * chain until it ends. While it is drawn the dome's blower tumbles the balls; when every draw has ended the blower
 * stops, won Apes rise in the glass and fly out to the win screen, and the receipt rises over the dome. An Ape win takes
 * over the screen; the batch ends on a receipt of what came back against what it cost (the randomness fee and gas left
 * out, as the copy says).
 */
export function DrawFlow({ d, count, setCount, dome, apes }: { d: DrawApi; count: number; setCount: (n: number) => void; dome: (cue: DomeCue) => ReactNode; apes: ApeOdds[] }) {
  const client = usePublicClient();
  const { openConnectModal } = useConnectModal();
  const { switchChain } = useSwitchChain();
  const { writeContractAsync } = useWriteContract();
  const { sendTransactionAsync } = useSendTransaction();
  const { sendCallsAsync } = useSendCalls();
  const config = useConfig();
  // EIP-5792: a wallet that runs a batch atomically gets redeem + draw as one confirmation ("ready": it can upgrade the
  // account to do so); any other, or one without the method (an error here), gets one transaction per step
  const { data: caps } = useCapabilities({ chainId: deployment.chainId, query: { enabled: !!d.address, retry: false } });
  const cap = caps as { atomic?: { status?: string }; atomicBatch?: { supported?: boolean } } | undefined;
  const atomic = cap?.atomic?.status === "supported" || cap?.atomic?.status === "ready" || cap?.atomicBatch?.supported === true;
  const { data: balance } = useBalance({ address: d.address, query: { enabled: !!d.address } });
  const queries = useQueryClient();
  const live = useRef(d); // the latest quote, for a draw sent after awaiting a redeem
  live.current = d;
  const [view, setView] = useState<View>("idle");
  const [msg, setMsg] = useState<Msg | null>(null);
  const [run, setRun] = useState<Run | null>(null);
  const [shown, setShown] = useState(0); // Ape reveals seen so far
  const [busy, setBusy] = useState(false);
  const [now, setNow] = useState<bigint>();
  const [landing, setLanding] = useState<bigint[] | null>(null); // every draw ended: the won Apes, rising before the reveal
  const timer = useRef<ReturnType<typeof setInterval>>(undefined);
  const [stuck, setStuck] = useState<Stuck | null>(null);
  const stuckTimer = useRef<ReturnType<typeof setInterval>>(undefined);
  const following = useRef<Hash>(undefined); // the sent transaction being waited on (cleared when the player stops)
  const land = useRef<ReturnType<typeof setTimeout>>(undefined);
  useEffect(() => () => clearTimeout(land.current), []);
  const prizes = useRef(new Map<bigint, Prize | string>()); // per draw: its prize, or why it was refunded
  const [held, setHeld] = useState<Set<bigint>>(new Set()); // draws whose Shape or Pack is still in the wallet
  const [pay, setPay] = useState(true); // "Pay with my winnings": redeem them into the next draw
  const counted = useRef<Hash>(undefined); // the run whose results last set the draw count
  useEffect(() => () => { clearInterval(timer.current); clearInterval(stuckTimer.current); }, []);

  const { data: credit, refetch: refetchCredit } = useReadContract({ address: d.pool, abi: fwaPoolAbi, functionName: "acquisitionRefundCredit", args: [d.address ?? "0x0000000000000000000000000000000000000000"], query: { enabled: !!d.pool && !!d.address } });
  const { data: shapesNft } = useReadContract({ address: deployment.poolOwner, abi: poolOwnerAbi, functionName: "shapes" });
  const { data: vrfService } = useReadContract({ address: d.pool, abi: fwaPoolAbi, functionName: "vrfService", query: { enabled: !!d.pool } });

  const update = (r: Run | null) => {
    setRun(r);
    if (d.address) save(d.address, r);
  };

  // follow a sent transaction: its receipt, then each draw until every one has ended
  const follow = async (r: Run) => {
    if (!client || !d.pool || !d.address) return;
    let cur = r;
    if (!cur.draws) {
      setView("sent");
      following.current = cur.hash;
      setStuck(null);
      const since = Date.now();
      clearInterval(stuckTimer.current);
      stuckTimer.current = setInterval(async () => {
        if (Date.now() - since >= STUCK_MS) setStuck(await whyStuck(cur.hash));
      }, CHECK_MS);
      const receipt = await client.waitForTransactionReceipt({
        hash: cur.hash,
        // sped up in the wallet: the same draw under a new hash
        onReplaced: (x) => {
          // follow the sped-up transaction only while this draw is still the one followed: after "Stop waiting" and a
          // newer draw, the newer one stays (round 7 F7-3)
          const mine = following.current === cur.hash;
          if (x.reason === "repriced") cur = { ...cur, hash: x.transaction.hash };
          if (mine) {
            update(cur);
            following.current = cur.hash;
          }
        },
      }).catch(() => undefined);
      if (following.current !== cur.hash) {
        // the player stopped waiting (or sent another draw): a draw mined after all is taken up again, unless another
        // has been sent since (round 6 F6-5)
        if (following.current !== undefined || receipt?.status !== "success") return; // a newer draw is being followed
        following.current = cur.hash;
        update(cur);
        setMsg({ title: "Your earlier draw went through", sub: "Following it now." });
      }
      clearInterval(stuckTimer.current);
      setStuck(null);
      if (!receipt) return; // still pending: a reload picks it up again
      const reqs = receipt.status === "success"
        ? parseEventLogs({ abi: events, logs: receipt.logs, eventName: "AcquisitionRequested" }).filter((l) => l.args.purchaser.toLowerCase() === d.address!.toLowerCase())
        : [];
      if (reqs.length === 0) {
        update(null);
        setView("idle");
        d.requote();
        setMsg(receipt.status === "success"
          ? { title: "Cancelled in wallet", sub: "Replaced in your wallet. Nothing was drawn." }
          : { title: "Draw didn't go through", sub: "Only gas was spent. Price refreshed.", warn: true });
        return;
      }
      cur = { ...cur, block: receipt.blockNumber, draws: reqs.map((l) => ({ req: l.args.requestId, fee: l.args.acquisitionFee, status: PENDING })) };
      update(cur);
    }
    setView("picking");
    const pool = d.pool;
    const poll = async () => {
      const next = await Promise.all(cur.draws!.map(async (x): Promise<Draw> => {
        const a = await client.readContract({ address: pool, abi: fwaPoolAbi, functionName: "acquisitions", args: [x.req] });
        const status = Number(a[4]);
        const out: Draw = { req: x.req, fee: x.fee, status };
        if (status === PENDING && vrfService) {
          out.word = WORD_STORED.has(await client.readContract({ address: vrfService, abi: vrfAbi, functionName: "requestStatus", args: [x.req] }));
        }
        if (!ENDED.has(status)) return out;
        let p = prizes.current.get(x.req);
        if (p === undefined && (status === FULFILLED || status === DELIVERY_PENDING)) {
          const l = await client.readContract({ address: pool, abi: fwaPoolAbi, functionName: "listings", args: [a[3]] });
          const isApe = l[0].toLowerCase() === deployment.collection.toLowerCase();
          const value = isApe ? undefined : await client.readContract({ address: l[0], abi: valueAbi, functionName: "valueOf", args: [l[3]] }).catch(() => undefined);
          p = { ape: isApe, tokenId: l[3], nft: l[0], listingId: a[3], value };
        } else if (p === undefined && status === REFUNDED) {
          // FWA refunds a settled draw when the pool is empty or the price moved too far: its event tells which
          const logs = await client.getContractEvents({ address: pool, abi: events, eventName: "AcquisitionRefundedNoListing", args: { requestId: x.req }, fromBlock: cur.block });
          p = logs.length ? "pool emptied" : "fee moved";
        } else if (p === undefined) {
          p = status === EXPIRED ? "expired" : "not delivered";
        }
        prizes.current.set(x.req, p);
        return typeof p === "string" ? { ...out, refund: p } : { ...out, prize: p };
      })).catch(() => undefined);
      if (!next) return;
      cur = { ...cur, draws: next };
      update(cur);
      if (next.every((x) => ENDED.has(x.status))) {
        clearInterval(timer.current);
        refetchCredit();
        setShown(0);
        const won = next.filter((x) => x.prize?.ape).map((x) => x.prize!.tokenId);
        setLanding(won);
        clearTimeout(land.current);
        land.current = setTimeout(() => morph(() => {
          setLanding(null);
          setView(won.length ? "reveal" : "results");
        }), won.length ? LIFT_MS : LAND_MS);
      }
    };
    clearInterval(timer.current);
    timer.current = setInterval(poll, 2000);
    poll();
  };

  // a draw left in flight on this wallet (the page was closed or reloaded): pick it up where it is
  useEffect(() => {
    if (!d.address || !client || !d.pool || run) return;
    const r = load(d.address);
    if (r) {
      setRun(r);
      follow(r);
    }
  }, [d.address, client, d.pool]); // eslint-disable-line react-hooks/exhaustive-deps

  const start = (hash: Hash, snapshot: ApeOdds[]) => {
    prizes.current.clear();
    setMsg(null);
    const r: Run = { hash, count, apes: snapshot };
    update(r);
    follow(r);
  };
  const go = async () => {
    if (!client || !d.address || !live.current.ready) return;
    setMsg(null);
    setView("wallet");
    const snapshot = apes; // the Apes' odds as drawn: what the reveal quotes
    let hash: Hash;
    try {
      hash = await live.current.send();
    } catch (e) {
      const m = why(e);
      setMsg(m);
      setView("idle");
      if (m.warn) live.current.requote();
      return;
    }
    start(hash, snapshot);
  };

  /** Pay the next draws with these won Shapes and Packs: the router redeems them and draws in one transaction, all or
   *  nothing (a failure leaves the prizes in the wallet). The first time, the router needs the player's approval on
   *  Shapes and on Packs: a batching wallet puts the approvals and the draw under one confirmation; any other sends
   *  each approval first (once, ever), then the draw. */
  const redeem = async (xs: Draw[]) => {
    if (!client || !d.address || !xs.length) return;
    const back = sum(xs), snapshot = apes, me = d.address;
    const shapeIds = xs.filter((x) => !isPack(x)).map((x) => x.prize!.tokenId);
    const packIds = xs.filter(isPack).map((x) => x.prize!.tokenId);
    // both contracts at the first use, whichever these prizes are on: the setup is one event, not one per kind of prize
    const nfts = shapesNft ? [shapesNft, deployment.packs] : [...new Set(xs.map((x) => x.prize!.nft))];
    const approved = await Promise.all(nfts.map((a) =>
      client.readContract({ address: a, abi: nftAbi, functionName: "isApprovedForAll", args: [me, deployment.drawRouter] })));
    const todo = nfts.filter((_, k) => !approved[k]);
    const approve = (a: Address) =>
      ({ to: a, data: encodeFunctionData({ abi: nftAbi, functionName: "setApprovalForAll", args: [deployment.drawRouter, true] }), value: 0n });
    const failed = (e: unknown) => {
      const m = why(e);
      setMsg(m.warn ? { title: "Draw didn't go through", sub: "Nothing was redeemed: your prizes are still in your wallet. Only gas was spent.", warn: true } : m);
      setView("results");
      if (m.warn) live.current.requote();
    };
    setMsg(null);
    if (todo.length && atomic) {
      setView("wallet");
      let hash: Hash | undefined;
      try {
        const { id } = await sendCallsAsync({ chainId: deployment.chainId, forceAtomic: true,
          calls: [...todo.map(approve), await d.redeemCall(shapeIds, packIds, back)] });
        setView("sent");
        // ponytail: the batch id is not kept across a reload (only a draw's hash is); the draw still lands on chain
        const st = await waitForCallsStatus(config, { id, timeout: 900_000 }); // the draw's own deadline
        hash = st.status === "success" ? st.receipts?.at(-1)?.transactionHash : undefined;
        if (!hash) throw new Error("reverted");
      } catch (e) {
        return failed(e);
      }
      return start(hash, snapshot);
    }
    const steps = todo.length + 1;
    for (const [k, a] of todo.entries()) {
      setView("redeeming");
      setMsg({ title: `One-time setup · step ${k + 1} of ${steps}`,
        sub: `Allow ApeBall to redeem your ${a.toLowerCase() === deployment.packs.toLowerCase() ? "Shapes Packs" : "Shapes"} when you pay with your winnings.` });
      try {
        const r = await client.waitForTransactionReceipt({ hash: await sendTransactionAsync({ chainId: deployment.chainId, ...approve(a) }) });
        if (r.status !== "success") throw new Error("reverted");
      } catch (e) {
        const m = why(e);
        setMsg(m.warn ? { title: "Approval didn't go through", sub: "Nothing was redeemed. Only gas was spent.", warn: true } : { ...m, sub: "Nothing was redeemed." });
        setView("results");
        return;
      }
    }
    setView("wallet");
    setMsg(steps > 1 ? { title: `Step ${steps} of ${steps}: redeem and draw`, sub: `${got(back)} from your prizes pays for the draw.` } : null);
    let hash: Hash;
    try {
      hash = await live.current.sendRedeem(shapeIds, packIds, back);
    } catch (e) {
      return failed(e);
    }
    start(hash, snapshot);
  };

  // why a sent draw has no receipt yet: gone from the network, its nonce used by another transaction, waiting behind a
  // missing earlier nonce, or only slow (null once mined: the receipt arrives with the next poll)
  const whyStuck = async (hash: Hash): Promise<Stuck | null> => {
    if (!client || !d.address) return null;
    const tx = await client.getTransaction({ hash }).catch(() => undefined);
    if (!tx) return "dropped";
    if (tx.blockNumber) return null;
    const used = await client.getTransactionCount({ address: d.address, blockTag: "latest" }).catch(() => undefined);
    if (used === undefined) return "slow";
    return tx.nonce < used ? "replaced" : tx.nonce > used ? "order" : "slow";
  };
  // the player gives up on a sent draw that will not confirm: stop showing it (its receipt is still watched, and if it
  // is mined later anyway while this page is open, it is shown again; its draws count either way)
  const stopWaiting = () => {
    following.current = undefined;
    clearInterval(stuckTimer.current);
    setStuck(null);
    finish();
    d.requote();
    setMsg({ title: "Stopped waiting", sub: "If that transaction still goes through, its draws count and prizes reach your wallet." });
  };
  const finish = () => {
    clearInterval(timer.current);
    clearTimeout(land.current);
    setLanding(null);
    update(null);
    setView("idle");
    setMsg(null);
  };
  const again = () => {
    finish();
    go();
  };
  const act = async (fn: () => Promise<Hash>) => {
    if (!client) return;
    setBusy(true);
    try {
      await client.waitForTransactionReceipt({ hash: await fn() });
      refetchCredit();
    } catch {
      // cancelled or failed: the button stays for another try
    } finally {
      setBusy(false);
    }
  };
  const withdraw = () => act(() => writeContractAsync({ chainId: deployment.chainId, address: d.pool!, abi: fwaPoolAbi, functionName: "withdrawAcquisitionRefund" }));
  /** Redeem won Shapes and Packs for their ETH, without drawing ("Pay with my winnings" off): one batch for the Shapes,
   *  one call per Pack; a batching wallet takes them under one confirmation. */
  const cashOut = async (xs: Draw[]) => {
    if (!client || !xs.length) return;
    const shapeIds = xs.filter((x) => !isPack(x)).map((x) => x.prize!.tokenId);
    const shapes = xs.find((x) => !isPack(x))?.prize!.nft;
    const calls = [
      ...(shapes && shapeIds.length ? [{ to: shapes, data: encodeFunctionData({ abi: cashAbi, functionName: "redeemBatch", args: [shapeIds] }), value: 0n }] : []),
      ...xs.filter(isPack).map((x) => ({ to: deployment.packs, data: encodeFunctionData({ abi: cashAbi, functionName: "redeem", args: [x.prize!.tokenId] }), value: 0n })),
    ];
    setBusy(true);
    try {
      if (atomic && calls.length > 1) {
        const { id } = await sendCallsAsync({ chainId: deployment.chainId, forceAtomic: true, calls });
        await waitForCallsStatus(config, { id, timeout: 900_000 });
      } else {
        for (const c of calls) {
          await client.waitForTransactionReceipt({ hash: await sendTransactionAsync({ chainId: deployment.chainId, ...c }) });
        }
      }
    } catch {
      // cancelled or failed: what was redeemed stays redeemed; the rest stays in the wallet for another try
    } finally {
      setBusy(false);
      setHeld(new Set()); // re-read below
      queries.invalidateQueries({ queryKey: [HELD_KEY] });
      setView("results");
      const me = d.address?.toLowerCase();
      Promise.all(owns.map((x) => client.readContract({ address: x.prize!.nft, abi: nftAbi, functionName: "ownerOf", args: [x.prize!.tokenId] })
        .then((o) => (o.toLowerCase() === me ? x.req : null)).catch(() => null)))
        .then((r) => setHeld(new Set(r.filter((v): v is bigint => v !== null))));
    }
  };

  const n = run?.count ?? count;
  const total = d.fee !== undefined ? d.fee * BigInt(count) : undefined;
  const txLink = run?.hash && txUrl(run.hash) ? <Ext className="dd-link" href={txUrl(run.hash)!}>View transaction</Ext> : null;
  const list = run?.draws ?? [];

  useEffect(() => {
    if (view === "reveal" && client) chainNow(client).then(setNow).catch(() => {});
  }, [view, client]);

  // on the receipt: which Shapes and Packs are still in the wallet (a reload can come after they were redeemed or
  // sent on), and, once per run, as many draws as they pay for
  const owns = list.filter((x) => x.status === FULFILLED && x.prize && !x.prize.ape && x.prize.value);
  const redeemable = owns.filter((x) => held.has(x.req));
  useEffect(() => {
    if (view !== "results" || !client || !d.address) return;
    const me = d.address.toLowerCase();
    Promise.all(owns.map((x) => client.readContract({ address: x.prize!.nft, abi: nftAbi, functionName: "ownerOf", args: [x.prize!.tokenId] })
      .then((o) => (o.toLowerCase() === me ? x.req : null)).catch(() => null)))
      .then((r) => setHeld(new Set(r.filter((v): v is bigint => v !== null))));
  }, [view, client, d.address, run?.hash]); // eslint-disable-line react-hooks/exhaustive-deps
  // again means as many draws as these results came from (the count can move since, as after a reload)
  useEffect(() => {
    if (view !== "results" || !run?.hash || counted.current === run.hash) return;
    counted.current = run.hash;
    setCount(Math.min(run.count, MAX_DRAWS));
    queries.invalidateQueries({ queryKey: [HELD_KEY] }); // the header's Shapes count these prizes now
  }, [view, run?.hash]); // eslint-disable-line react-hooks/exhaustive-deps

  // the reveal, one Ape at a time in draw order; a failed delivery shows its own screen in place of the takeover
  const queue = list.filter((x) => x.prize?.ape);
  // the dome: the blower while sending (gently) and picking; the won Apes raised while they land, and those not yet
  // revealed during the reveal, so each next one flies out of the glass in turn
  const cue: DomeCue = {
    mixing: view === "sent" ? 0.35 : view === "picking" && !landing ? 1 : 0,
    lift: landing ?? (view === "reveal" ? queue.slice(shown + 1).map((x) => x.prize!.tokenId) : []),
  };
  const domeNode = dome(cue);
  if (view === "reveal" && queue[shown]) {
    const x = queue[shown], i = list.indexOf(x) + 1, more = shown + 1 < queue.length;
    const nextLabel = more ? "NEXT" : n === 1 ? "SEE RESULTS" : `SEE ALL ${n} DRAWS`;
    const next = () => morph(() => (more ? setShown(shown + 1) : setView("results")));
    return (
      <div className="dd">
        <div className="dd-dome">{domeNode}</div>
        {x.status === DELIVERY_PENDING ? (
          <Undelivered x={x} nextLabel={nextLabel} next={next} now={now} pool={d.pool} busy={busy}
            retry={(fn) => act(() => writeContractAsync({ chainId: deployment.chainId, address: d.pool!, abi: fwaPoolAbi, functionName: fn, args: [x.prize!.listingId] })).then(() => follow({ ...run!, draws: list }))} />
        ) : <Takeover x={x} i={i} n={n} odds={run?.apes.find((a) => a.listingId === x.prize!.listingId)} nextLabel={nextLabel} next={next} flown={morphs()} />}
      </div>
    );
  }

  if (view === "results") {
    const refunds = list.filter((x) => REFUNDS.has(x.status));
    const owed = credit ?? 0n;
    const withdrawBtn = <button className="dd-btn" disabled={busy} onClick={withdraw}>{busy ? <Spin /> : null}WITHDRAW {amtDown(owed)} ETH</button>;
    if (refunds.length === list.length) {
      const reasons = new Set(refunds.map((x) => x.refund));
      const one = list.length === 1;
      const cause = reasons.size !== 1 ? `${one ? "Draw" : "Draws"} refunded.`
        : reasons.has("expired") ? "No randomness in time."
          : reasons.has("pool emptied") ? "The prize pool was empty."
            : reasons.has("fee moved") ? "The price moved too far before settling." : "Delivery failed.";
      return (
        <div className="dd">
          <div className="dd-dome">{domeNode}</div>
          <div className="dd-controls">
            <div className="dd-msg"><b>{one ? "Draw refunded" : `${list.length} draws refunded`}</b>
              <span>{cause} Draw {one ? "fee is" : "fees are"} back; VRF {one ? "fee isn't" : "fees aren't"}.</span></div>
            {owed > 0n ? withdrawBtn : <DrawAgain d={d} count={count} total={total} onClick={again} />}
            <button className="dd-quiet" onClick={finish}>Done</button>
          </div>
        </div>
      );
    }
    const lines = list.filter((x) => !x.prize?.ape);
    const won = list.filter((x) => x.prize?.ape);
    return (
      <div className="dd">
        {/* the receipt rises over the dimmed dome, so it is in view without scrolling */}
        <div className="dd-stage">
        <div className="dd-dome backdrop">{domeNode}</div>
        <div className="dd-receipt over">
          {won.map((x, k) => {
            const o = run?.apes.find((a) => a.listingId === x.prize!.listingId);
            return (
              <div key={x.req.toString()} className="dd-banner" style={{ "--k": k } as React.CSSProperties}>
                <span className="dd-banner-ball" style={{ viewTransitionName: `ape-${x.prize!.tokenId}` }}><Ball tokenId={x.prize!.tokenId} /></span>
                <div><b>{ape} #{x.prize!.tokenId.toString()}</b>
                  <span>Draw {list.indexOf(x) + 1}{o ? ` · listed at ${eth(o.price)}` : ""} · {x.status === DELIVERY_PENDING ? "not delivered yet" : "in your wallet"}</span></div>
              </div>
            );
          })}
          {lines.length ? (
            <>
              <span className="dd-eyebrow">Results</span>
              <div className="dd-lines">
                {lines.map((x, k) => {
                  const refund = REFUNDS.has(x.status);
                  return (
                    <div key={x.req.toString()} className="dd-line" style={{ "--k": k + won.length } as React.CSSProperties}>
                      {refund || !x.prize ? <span className="dd-line-empty" /> : <span className="dd-line-art"><Art tokenId={x.prize.tokenId} nft={x.prize.nft} alt={prizeName(x)} /></span>}
                      <span className={refund ? "warm" : undefined}>
                        {refund ? `Refund · ${x.refund}` : <Ext href={prizeUrl(x)}>{prizeName(x)}</Ext>}{x.status === DELIVERY_PENDING ? " · not delivered yet" : ""}</span>
                      <b>{got(refund ? x.fee : x.prize?.value ?? 0n)}</b>
                    </div>
                  );
                })}
              </div>
            </>
          ) : null}
        </div>
        </div>
        <div className="dd-controls">
          {msg ? <div className="dd-msg"><b className={msg.warn ? "warm" : undefined}>{msg.title}</b><span>{msg.sub}</span></div> : null}
          {refunds.length && owed > 0n ? (
            <>
              {withdrawBtn}
              <button className="dd-btn ghost" disabled={!d.ready} onClick={again}>DRAW AGAIN</button>
            </>
          ) : <PayAgain d={d} count={count} setCount={setCount} total={total} prizes={redeemable} balance={balance?.value} pay={pay} setPay={setPay}
            onDraw={() => (pay && redeemable.length ? redeem(redeemable) : again())} onCash={() => cashOut(redeemable)} busy={busy} />}
          <button className="dd-quiet" onClick={finish}>Done</button>
        </div>
      </div>
    );
  }

  if (view === "sent" || view === "picking") {
    const settled = list.filter((x) => ENDED.has(x.status)).length;
    const head = list.findIndex((x) => !ENDED.has(x.status));
    // the first draw still open is the one being drawn; the rest wait their turn (FWA settles strictly in order)
    const chip = (x: Draw, k: number) => {
      if (ENDED.has(x.status)) return REFUNDS.has(x.status) ? ["done warm", "Refunded"] : ["done", "Picked"];
      if (x.status === TIMED_OUT) return ["late", "Late"];
      if (k !== head || x.status === READY) return ["", "In line"];
      return x.word ? ["delivering", "Delivering"] : ["drawing", "Drawing"];
    };
    const late = list.findIndex((x) => x.status === TIMED_OUT);
    const delivering = head >= 0 && list[head].status === PENDING && list[head].word;
    const note = view === "sent" ? <>{stuck ? STUCK_NOTE[stuck] : "Waiting for confirmation."} {txLink}</>
      : late >= 0 ? <>No randomness for {n === 1 ? "your draw" : `draw ${late + 1}`} yet. If none arrives, it&apos;s refunded. {txLink}</>
        : delivering ? <>{n === 1 ? "Randomness" : `Draw ${head + 1}'s randomness`} arrived, delivering now.{n > 1 ? " Others wait their turn." : ""} Safe to leave. {txLink}</>
          : <>Randomness on its way. Safe to leave: prizes go to your wallet. {txLink}</>;
    return (
      <div className="dd">
        <div className={`dd-dome${view === "picking" ? " picking" : ""}${landing ? " landed" : ""}`}>{domeNode}</div>
        <div className="dd-controls">
          {view === "picking" ? (
            <div className="dd-chips" style={{ gridTemplateColumns: `repeat(${Math.max(list.length, 1)}, minmax(0, 1fr))` }}>
              {list.map((x, k) => {
                const [c, t] = chip(x, k);
                return <div key={x.req.toString()} className={`dd-chip ${c}`}><b><i />{k + 1}</b><span>{t}</span></div>;
              })}
            </div>
          ) : null}
          <div className="dd-progress" role="status">
            <div className="dd-fill" style={{ width: view === "sent" ? "100%" : `${Math.max(8, (settled / Math.max(list.length, 1)) * 100)}%` }}><i /></div>
            <span>{view === "sent" ? `SENDING ${draws(n).toUpperCase()}` : landing ? (landing.length ? `YOU WON ${landing.length > 1 ? `${landing.length} ${ape.toUpperCase()}S` : `${collectionMeta.article.toUpperCase()} ${ape.toUpperCase()}`}` : "PRIZES PICKED") : `PICKING PRIZES · ${settled} OF ${list.length}`}</span>
          </div>
          <p className="dd-note">{note}</p>
          {view === "sent" && stuck ? <button type="button" className="dd-quiet" onClick={stopWaiting}>Stop waiting</button> : null}
        </div>
      </div>
    );
  }

  // the panel: ready, not ready (the first check that fails), checking the price, or waiting on the wallet
  const blocked = d.block;
  const label = blocked === "connect" ? "CONNECT WALLET" : blocked === "network" ? "SWITCH NETWORK" : "DRAWS PAUSED";
  const onBlocked = blocked === "connect" ? openConnectModal : blocked === "network" ? () => switchChain({ chainId: deployment.chainId }) : undefined;
  const price = `${count} · ${amtUp(total ?? 0n)} ETH`;
  const wallet = view === "wallet";
  const quoting = !blocked && d.quoting;
  const lock = wallet || quoting || blocked === "paused";
  const tap = (fn: () => void) => () => { setMsg(null); fn(); };
  return (
    <div className="dd">
      <div className={`dd-dome${wallet || quoting ? " dim" : ""}`}>{domeNode}</div>
      <div className="dd-controls">
        {msg ? <div className="dd-msg"><b className={msg.warn ? "warm" : undefined}>{msg.title}</b><span>{msg.sub}</span></div> : null}
        <div className="dd-row" role="group" aria-label="How many draws">
          <button type="button" className="dd-step" aria-label="One fewer draw" disabled={lock || count <= 1} onClick={tap(() => setCount(count - 1))}>−</button>
          {blocked ? (
            <button className={`dd-btn${blocked === "paused" ? " off" : ""}${blocked !== "paused" && total !== undefined ? " two" : ""}`} disabled={!onBlocked} onClick={onBlocked}>
              {/* the price stays on the button, under the step that comes first */}
              {blocked !== "paused" && total !== undefined ? <><span>{label}</span><small>to draw {price}</small></> : label}
            </button>
          )
              : wallet ? <button className="dd-btn wallet" disabled aria-live="polite"><Spin />CONFIRM IN WALLET</button>
                : quoting ? <button className="dd-btn off light" disabled aria-live="polite"><Spin />CHECKING PRICE</button>
                  : <button className="dd-btn" disabled={!d.ready} onClick={tap(go)}>DRAW {price}</button>}
          <button type="button" className="dd-step" aria-label="One more draw" disabled={lock || count >= MAX_DRAWS} onClick={tap(() => setCount(count + 1))}>+</button>
          {/* the notes sit under the main button only, between the steppers' columns */}
          <p className="dd-note dd-under">
            {wallet ? `${draws(count)} · ${amtUp(total ?? 0n)} ETH, plus gas and VRF fees.`
              : quoting ? `Checking the price for ${draws(count)}.`
                : "Gas and VRF fees are priced at draw time."}
          </p>
          {d.reason && !blocked ? <p className="dd-note dd-under warm">{d.reason}</p> : null}
        </div>
      </div>
    </div>
  );
}

function Spin() {
  return <span className="dd-spin" aria-hidden />;
}

function DrawAgain({ d, count, total, onClick }: { d: DrawApi; count: number; total?: bigint; onClick: () => void }) {
  return <button className="dd-btn" disabled={!d.ready} onClick={onClick}>{d.ready && total !== undefined ? `DRAW ${count} AGAIN · ${amtUp(total)} ETH` : "DRAW AGAIN"}</button>;
}

/** Draw again, how many, and "Pay with my winnings": on (the default, when prizes are still in the wallet) redeems them
 *  into the draw, the sub-line saying what they cover and what the wallet adds or keeps; off keeps them. The button
 *  shows the draws' price either way. */
function PayAgain({ d, count, setCount, total, prizes, balance, pay, setPay, onDraw, onCash, busy }: { d: DrawApi; count: number;
  setCount: (n: number) => void; total?: bigint; prizes: Draw[]; balance?: bigint; pay: boolean; setPay: (on: boolean) => void;
  onDraw: () => void; onCash: () => void; busy: boolean }) {
  const on = pay && prizes.length > 0;
  // what the change and the wallet's part are counted against: the most the draw can take at the randomness fee quoted
  // (round 6 F6-4). FWA can still raise that fee before the transaction lands, so the change is "about" (round 7 F7-2)
  const back = sum(prizes), cost = d.maxValue;
  const kind = prizes.every(isPack) ? "Pack" : prizes.some(isPack) ? "prize" : "Shape";
  const named = `${prizes.length === 1 ? "your" : `your ${prizes.length}`} ${kind}${prizes.length === 1 ? "" : "s"}`;
  // the wallet must hold what the prizes do not cover (the redeem's and draw's gas come on top)
  const short = on && cost !== undefined && balance !== undefined && balance + back < cost;
  const sub = !on ? `Off · ${named} stay${prizes.length === 1 ? "s" : ""} in your wallet`
    : short ? `Not enough ETH in your wallet for the rest`
      : cost === undefined ? `Redeems ${got(back)}`
        : `Redeems ${got(back)} · ${back >= cost ? `about ${got(back - cost)} stays in your wallet` : `${amtUp(cost - back)} ETH from your wallet`}`;
  return (
    <>
      <div className="dd-row" role="group" aria-label="How many draws">
        <button type="button" className="dd-step" aria-label="One fewer draw" disabled={count <= 1} onClick={() => setCount(count - 1)}>−</button>
        <button className="dd-btn" disabled={!d.ready || short} onClick={onDraw}>
          <span>DRAW {count} AGAIN</span>{d.ready && total !== undefined ? <span className="dd-price">{amtUp(total)} ETH</span> : null}
        </button>
        <button type="button" className="dd-step" aria-label="One more draw" disabled={count >= MAX_DRAWS} onClick={() => setCount(count + 1)}>+</button>
      </div>
      {prizes.length ? (
        <div className="dd-pay">
          <div><b id="dd-pay-label">Pay with my winnings</b><span className={short ? "warm" : undefined}>{sub}</span></div>
          <button type="button" role="switch" aria-checked={pay} aria-labelledby="dd-pay-label" className="dd-switch" onClick={() => setPay(!pay)}><i /></button>
        </div>
      ) : null}
      {prizes.length && !pay ? (
        <button type="button" className="dd-btn ghost" disabled={busy} onClick={onCash}>{busy ? <Spin /> : null}REDEEM FOR {amtDown(back)} ETH</button>
      ) : null}
    </>
  );
}

// fixed confetti (position, size, shape, colour, timing), so it never reshuffles between renders
const CONFETTI = Array.from({ length: 26 }, (_, k) => {
  const r = (s: number) => (((Math.sin(k * 12.9898 + s * 78.233) * 43758.5453) % 1) + 1) % 1;
  return { left: `${(r(1) * 100).toFixed(1)}%`, w: 6 + Math.round(r(2) * 5), h: 10 + Math.round(r(3) * 8), round: r(4) > 0.6,
    bg: ["#ffa063", "#ff6b14", "#4fd67a", "#f4f6fb", "#ffd34d", "#0d1530"][k % 6], dur: `${(2.2 + r(5) * 2).toFixed(2)}s`, delay: `${(0.6 + r(6) * 1.9).toFixed(2)}s` };
});

function Takeover({ x, i, n, odds, nextLabel, next, flown }: { x: Draw; i: number; n: number; odds?: ApeOdds; nextLabel: string; next: () => void; flown: boolean }) {
  const btn = useRef<HTMLButtonElement>(null);
  useEffect(() => btn.current?.focus(), [x.req]);
  const id = x.prize!.tokenId.toString(), word = `${ape.toUpperCase()} #${id}`;
  const row = (dir: "l" | "r") => (
    <div className={`dd-marq ${dir}`} aria-hidden><div>{Array.from({ length: 8 }, (_, k) => <span key={k}>{word}</span>)}</div></div>
  );
  return (
    <div className="dd-takeover" role="dialog" aria-modal="true" aria-labelledby="dd-won-title" key={id}>
      <div className="dd-flash" aria-hidden />
      {row("l")}{row("r")}
      <div className="dd-confetti" aria-hidden>
        {CONFETTI.map((c, k) => <span key={k} style={{ left: c.left, width: c.w, height: c.h, borderRadius: c.round ? "50%" : 2, background: c.bg, animationDuration: c.dur, animationDelay: c.delay }} />)}
      </div>
      <div className="dd-won">
        {/* flown: the ball arrives from the dome by a view transition, so it does not also slam in */}
        <div className={`dd-won-ball${flown ? " flown" : ""}`} style={{ viewTransitionName: `ape-${id}` }}><Ball tokenId={x.prize!.tokenId} rot={-6} /></div>
        <span className="dd-eyebrow r1">{n > 1 ? `Draw ${i} of ${n} · ` : ""}You won {collectionMeta.article} {ape}</span>
        <b id="dd-won-title" className="r2">{ape} #{id}</b>
        <span className="r3">{odds ? `${oneIn(odds.probabilityE18)} · listed at ${eth(odds.price)} · ` : ""}in your wallet</span>
        <BurnLine listingId={x.prize!.listingId} />
      </div>
      <div className="dd-takeover-foot"><button ref={btn} className="dd-btn white" onClick={next}>{nextLabel}</button></div>
    </div>
  );
}

function Undelivered({ x, nextLabel, next, now, pool, busy, retry }: { x: Draw; nextLabel: string; next: () => void; now?: bigint; pool?: Address; busy: boolean; retry: (fn: "retryNFTDelivery" | "refundFailedDelivery") => void }) {
  const { data: pend } = useReadContract({ address: pool, abi: fwaPoolAbi, functionName: "pendingDeliveries", args: [x.prize!.listingId], query: { enabled: !!pool } });
  // inside FWA's 7-day window anyone may retry the delivery; after it only the winner may take a refund instead
  const over = pend && pend[1] > 0n && now !== undefined ? now > pend[1] : false;
  return (
    <div className="dd-undelivered">
      <div className="dd-undelivered-ball"><Ball tokenId={x.prize!.tokenId} /><span>Not delivered yet</span></div>
      <div className="dd-msg"><b>You won {ape} #{x.prize!.tokenId.toString()}</b><span>Yours, but delivery to your wallet failed.</span></div>
      <div className="dd-controls">
        <button className="dd-btn" disabled={busy || !pool} onClick={() => retry(over ? "refundFailedDelivery" : "retryNFTDelivery")}>
          {busy ? <Spin /> : null}{over ? "CLAIM REFUND" : "RETRY DELIVERY"}</button>
        <p className="dd-note">Anyone can retry for 7 days, then only you can claim a refund.</p>
        <button className="dd-quiet" onClick={next}>{nextLabel.charAt(0) + nextLabel.slice(1).toLowerCase()}</button>
      </div>
    </div>
  );
}
