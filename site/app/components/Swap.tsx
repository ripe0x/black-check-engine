"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";
import { formatEther, maxUint256, parseEther, type Hash } from "viem";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import { useAccount, useBalance, useSwitchChain, usePublicClient, useReadContract, useSendTransaction, useWaitForTransactionReceipt, useWriteContract } from "wagmi";
import { deployment, collectionMeta } from "../lib/deployment";
import { hookAbi, liquidityAbi, tokenAbi } from "../lib/abi.generated";
import { PERMIT2, UNIVERSAL_ROUTER, V4_QUOTER, minOut, permit2Abi, quoteArgs, quoterAbi, swapTx, coinPoolKey } from "../lib/swap";
import { eth, ethDown, num, numDown } from "../lib/format";
import { TxStatus } from "./Tx";
import { chainName, chainNow, txUrl, useOnChain } from "../lib/chain";
import { Ext } from "./Ext";
import { money, useMarket } from "../lib/market";

const key = deployment.deployed ? coinPoolKey(deployment.token, deployment.hook) : undefined;
// slippage: the swap reverts if it would pay out less than the quote minus this. 1% unless the trader picks another,
// from 0.1% to 50%; above 5% the panel warns
const SLIPPAGES = [50n, 100n, 300n], SLIP_MIN = 10n, SLIP_MAX = 5_000n, SLIP_WARN = 500n;
const ALLOW_FOR = 1800; // seconds a sell's Permit2 allowance to the router lasts

const parse = (s: string) => { try { const v = parseEther(s.trim() || "0"); return v > 0n ? v : 0n; } catch { return 0n; } };

/** What a trade being typed or sent would pay into the vault, for a panel beside the swap (the funding ring). */
export type SwapPreview = { fee?: bigint; status: "idle" | "preview" | "pending" | "confirmed" | "failed" };

const pctBps = (b: bigint | undefined) => (b === undefined ? "–" : `${Number(b) / 100}%`);
const clock = (s: number) => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;

/**
 * Buy or sell the coin against ETH in the protocol's own Uniswap v4 pool, through Uniswap's Universal Router.
 * Exact input only (the hook refuses exact-output sells). A sell first lets Permit2 move the coin (once), then lets
 * the router take this amount through Permit2 for half an hour.
 *
 * `rows` adds the funding screen's lines (what the board still needs); `footnote` replaces the
 * default; `onPreview` reports the fee the trade being typed or sent would pay into the vault.
 */
export function Swap({ rows, footnote, onPreview }: { rows?: ReactNode; footnote?: string; onPreview?: (p: SwapPreview) => void } = {}) {
  const { address } = useAccount();
  const onChain = useOnChain();
  const { openConnectModal } = useConnectModal();
  const { switchChain } = useSwitchChain();
  const client = usePublicClient();
  const coin = deployment.token, sym = collectionMeta.ticker, plain = collectionMeta.coin;
  const [buy, setBuy] = useState(true);
  const [text, setText] = useState("");
  const [slip, setSlip] = useState(100n);
  const [custom, setCustom] = useState("");
  const [slipOpen, setSlipOpen] = useState(false);
  const m = useMarket();
  const amountIn = parse(text);
  const { data: launched } = useReadContract({ address: deployment.liquidity, abi: liquidityAbi, functionName: "launched" });
  const { data: fee } = useReadContract({ address: deployment.hook, abi: hookAbi, functionName: "currentFeeBps", args: [buy], query: { refetchInterval: 15_000 } });
  const { data: opening } = useReadContract({ address: deployment.hook, abi: hookAbi, functionName: "openingFee", query: { refetchInterval: 15_000 } });
  const { data: baseBuy } = useReadContract({ address: deployment.hook, abi: hookAbi, functionName: "buyFeeBps" });
  const { data: baseSell } = useReadContract({ address: deployment.hook, abi: hookAbi, functionName: "sellFeeBps" });
  const { data: ethBal, refetch: refetchEth } = useBalance({ address, query: { enabled: !!address } });
  const { data: coinBal, refetch: refetchCoin } = useReadContract({ address: coin, abi: tokenAbi, functionName: "balanceOf", args: [address!], query: { enabled: !!address } });
  const { data: toPermit2, refetch: refetchA } = useReadContract({ address: coin, abi: tokenAbi, functionName: "allowance", args: [address!, PERMIT2], query: { enabled: !!address } });
  const { data: toRouter, refetch: refetchP } = useReadContract({ address: PERMIT2, abi: permit2Abi, functionName: "allowance", args: [address!, coin, UNIVERSAL_ROUTER], query: { enabled: !!address } });
  const [quote, setQuote] = useState<{ out: bigint; for: string } | null>(null);
  const { sendTransaction, data: swapHash, error: swapErr, isPending: swapping } = useSendTransaction();
  const { writeContract, data: approveHash, error: approveErr, isPending: approving } = useWriteContract();
  const { isSuccess: swapped, isLoading: swapWaiting } = useWaitForTransactionReceipt({ hash: swapHash });
  const { isSuccess: approved, isLoading: approveWaiting } = useWaitForTransactionReceipt({ hash: approveHash });
  // one action at a time: set on click, before any await, and held until the wallet returns; the waiting flags above
  // then hold the button until the receipt, so a second click cannot send the same swap again
  const busy = useRef(false);
  const [, rerender] = useState(0);
  // the steps this trade takes (a sell may first let Permit2 move the coin, then allow this sell) and which one runs
  const plan = useRef<{ for: string; of: number; n: number } | null>(null);
  // what the last swap brought in, shown until dismissed
  const before = useRef<{ eth?: bigint; coin?: bigint; buy: boolean; fee?: bigint } | null>(null);
  const [toast, setToast] = useState<{ title: string; sub: string; hash: string } | null>(null);

  // quote the amount typed, after a short pause, and again after each swap
  const tag = `${buy}:${amountIn}`;
  useEffect(() => {
    setQuote(null);
    if (!client || !key || !amountIn) return;
    let live = true;
    const t = setTimeout(() => {
      client.simulateContract({ address: V4_QUOTER, abi: quoterAbi, functionName: "quoteExactInputSingle", args: quoteArgs(key, buy, amountIn) })
        .then((r) => live && setQuote({ out: r.result[0], for: tag }))
        .catch(() => live && setQuote({ out: 0n, for: tag }));
    }, 150);
    return () => { live = false; clearTimeout(t); };
  }, [client, tag, swapped]);

  useEffect(() => { if (approved) { refetchA(); refetchP(); if (plan.current) plan.current.n++; } }, [approved]);
  useEffect(() => {
    if (!swapped || !swapHash) return;
    (async () => {
      const b = before.current;
      const [e, c] = await Promise.all([refetchEth(), refetchCoin()]);
      refetchP();
      setText("");
      plan.current = null;
      if (!b) return;
      const got = b.buy ? (c.data ?? 0n) - (b.coin ?? 0n) : (e.data?.value ?? 0n) - (b.eth ?? 0n);
      // what arrived, rounded down so the message never says more than was received (round 6 F6-3)
      const amount = b.buy ? `${numDown(got > 0n ? got : 0n, 0)} ${plain}` : `${ethDown(got > 0n ? got : 0n)}`;
      const value = usd(got > 0n ? got : undefined, !b.buy);
      setToast({ title: `${b.buy ? "Bought" : "Sold for"} ${amount}${value ? ` · ${value}` : ""}`,
        sub: b.fee !== undefined ? `About ${eth(b.fee)} went to the vault` : "The fee went to the vault", hash: swapHash });
    })();
  }, [swapped]); // eslint-disable-line react-hooks/exhaustive-deps

  const out = quote?.for === tag ? quote.out : undefined;
  const balance = buy ? ethBal?.value : coinBal;
  // allowances still loading are unknown, not zero: the button waits for them
  const allowKnown = buy || (toPermit2 !== undefined && toRouter !== undefined);
  const needApprove = !buy && amountIn > 0n && toPermit2 !== undefined && toPermit2 < amountIn;
  // shown from the browser's clock; checked again against the chain's clock before sending
  const needPermit = !buy && !needApprove && amountIn > 0n && !!toRouter && (toRouter[0] < amountIn || toRouter[1] < Date.now() / 1000 + 60);
  const tooMuch = balance !== undefined && amountIn > balance;
  const chainId = deployment.chainId; // every write asserts the wallet is on this chain, or the wallet refuses it
  // the fee this trade pays into the vault, all in ETH: out of the ETH paid on a buy, out of the ETH received on a sell
  // (the quote is the ETH after it, so the fee is quote × f / (1 − f))
  const feeWei = fee === undefined || !amountIn ? undefined
    : buy ? (amountIn * fee) / 10_000n : out ? (out * fee) / (10_000n - fee) : undefined;
  const base = buy ? baseBuy : baseSell;

  // the opening curve's countdown to the ordinary fee, ticking each second between reads
  const [left, setLeft] = useState<number | null>(null);
  useEffect(() => { setLeft(opening ? Number(opening[2]) : null); }, [opening]);
  useEffect(() => {
    if (!left) return;
    const t = setInterval(() => setLeft((s) => (s && s > 0 ? s - 1 : 0)), 1000);
    return () => clearInterval(t);
  }, [left !== null && left > 0]); // eslint-disable-line react-hooks/exhaustive-deps
  const curve = !!left && left > 0;

  const go = async () => {
    if (busy.current || !client || !key || !amountIn) return;
    if (plan.current?.for !== tag) plan.current = { for: tag, of: 1 + (needApprove ? 1 : 0) + (needPermit || needApprove ? 1 : 0), n: 1 };
    busy.current = true;
    setToast(null);
    rerender((n) => n + 1);
    const done = { onSettled: () => { busy.current = false; rerender((n) => n + 1); } };
    try {
      if (needApprove) return writeContract({ chainId, address: coin, abi: tokenAbi, functionName: "approve", args: [PERMIT2, maxUint256] }, done);
      // deadlines and the allowance's expiry count from the chain's own clock, not this browser's
      const t = await chainNow(client);
      if (!buy) {
        const p = (await refetchP()).data;
        if (!p || p[0] < amountIn || BigInt(p[1]) < t + 60n) {
          return writeContract({ chainId, address: PERMIT2, abi: permit2Abi, functionName: "approve", args: [coin, UNIVERSAL_ROUTER, amountIn, Number(t) + ALLOW_FOR] }, done);
        }
      }
      if (!out) throw new Error("no quote");
      const tx = swapTx(key, buy, amountIn, minOut(out, slip), t + 900n);
      // a gas limit 30% above the estimate: during the opening curve the fee falls every second, so a buy mined after
      // the wallet's estimate puts more ETH through the pool and can need more gas than estimated (it ran out of gas
      // in the coin transfer on a local fork)
      const gas = (await client.estimateGas({ account: address, ...tx })) * 13n / 10n;
      before.current = { eth: ethBal?.value, coin: coinBal, buy, fee: feeWei };
      sendTransaction({ chainId, ...tx, gas }, done);
    } catch {
      done.onSettled();
    }
  };

  const pending = busy.current || swapping || approving || swapWaiting || approveWaiting;
  const swapPending = swapping || swapWaiting;
  const label = !address ? "CONNECT TO TRADE" : !onChain ? `SWITCH TO ${chainName.toUpperCase()}` : !launched ? "MARKET NOT OPEN YET"
    : pending && plan.current ? `CONFIRMING · ${Math.min(plan.current.n, plan.current.of)} OF ${plan.current.of}`
      : !amountIn ? "ENTER AN AMOUNT" : tooMuch ? "NOT ENOUGH BALANCE" : needApprove ? `LET PERMIT2 MOVE ${plain}` : needPermit ? "ALLOW THIS SELL"
        : out === 0n ? "NO QUOTE" : buy ? `BUY ${plain}` : `SELL ${plain}`;
  const ready = !!address && onChain && !!launched && amountIn > 0n && !tooMuch && allowKnown && !pending
    && (needApprove || needPermit || (out !== undefined && out > 0n));
  // the dollar value of an amount on either side: ETH at the ETH price, the coin at its pool price
  function usd(wei: bigint | undefined, isEth: boolean) {
    return wei === undefined || wei === 0n || m.ethUsd === undefined ? null
      : money(isEth ? Number(formatEther(wei)) : m.priceEth === undefined ? undefined : Number(formatEther(wei)) * m.priceEth, m.ethUsd);
  }
  const pick = (v: string) => {
    const t = v.replace(",", ".");
    if (!/^\d{0,2}(\.\d{0,2})?$/.test(t)) return;
    setCustom(t);
    const b = BigInt(Math.round(Number(t || "0") * 100));
    if (b >= SLIP_MIN && b <= SLIP_MAX) setSlip(b);
  };

  // what this trade would pay into the vault, for the ring beside the swap
  const status: SwapPreview["status"] = swapPending ? "pending" : toast ? "confirmed" : swapErr ? "failed" : feeWei ? "preview" : "idle";
  const reported = useRef("");
  useEffect(() => {
    const k = `${status}:${feeWei ?? ""}`;
    if (!onPreview || k === reported.current) return;
    reported.current = k;
    onPreview({ fee: status === "idle" ? undefined : status === "confirmed" ? before.current?.fee : feeWei, status });
  });
  // the confirmation stays until dismissed or the trader starts another trade in the fields
  const type = (v: string) => { setText(v); setToast(null); };
  const side = (b: boolean) => { setBuy(b); type(""); plan.current = null; };
  const token = (isEth: boolean) => <span className="swap-token"><i className={isEth ? "eth" : "coin"} />{isEth ? "ETH" : plain}</span>;
  return (
    <div className={`swap${swapPending ? " locked" : ""}`}>
      <div className="swap-head">
        <div className="swap-tabs" role="group" aria-label="Buy or sell">
          <button type="button" aria-pressed={buy} onClick={() => side(true)}>Buy</button>
          <button type="button" aria-pressed={!buy} onClick={() => side(false)}>Sell</button>
        </div>
        <button type="button" className="swap-slip-toggle" aria-expanded={slipOpen} aria-controls="swap-slip" onClick={() => setSlipOpen((o) => !o)}>
          Slippage {pctBps(slip)}</button>
      </div>
      {/* slippage: collapsed by default; 1% unless the trader picks a preset or types one */}
      {slipOpen ? (
        <div id="swap-slip" className="swap-slip">
          <div className="swap-slip-row" role="group" aria-label="Slippage">
            {SLIPPAGES.map((b) => (
              <button key={b.toString()} type="button" aria-pressed={slip === b && !custom} onClick={() => { setSlip(b); setCustom(""); }}>{pctBps(b)}</button>
            ))}
            <label className={custom ? "on" : undefined}>
              <input inputMode="decimal" placeholder="Custom" value={custom} aria-label="Custom slippage, percent" onChange={(e) => pick(e.target.value)}
                onBlur={() => { if (custom && (Number(custom) * 100 < Number(SLIP_MIN) || Number(custom) * 100 > Number(SLIP_MAX))) setCustom(""); }} />%
            </label>
          </div>
          <p className={`swap-slip-note${slip > SLIP_WARN ? " warm" : ""}`}>{slip > SLIP_WARN
            ? "High slippage: the trade can fill well below the quote, and bots can take the difference."
            : "The trade reverts if it would get less than the quote minus this. The trading fee is separate."}</p>
        </div>
      ) : null}
      <label className="swap-box">
        <span className="swap-row"><span>You pay</span>
          <span>Balance {buy ? eth(balance) : num(balance, 0)}{usd(balance, buy) ? ` · ${usd(balance, buy)}` : ""}
            {!buy && coinBal ? <button type="button" onClick={() => type(formatEther(coinBal))}>Max</button> : null}</span></span>
        <span className="swap-row">
          {/* only a plain decimal is taken (a comma reads as the point); anything else is refused, never reshaped into another number */}
          <input className="swap-amount" inputMode="decimal" placeholder="0" value={text} disabled={swapPending} aria-label={`Amount of ${buy ? "ETH" : sym} to pay`}
            onChange={(e) => { const v = e.target.value.replace(",", "."); if (/^\d*\.?\d{0,18}$/.test(v)) type(v); }} />
          {token(buy)}
        </span>
        <span className="swap-usd">{usd(amountIn, buy) ?? "$0.00"}</span>
      </label>
      <button type="button" className="swap-flip" aria-label={buy ? "Switch to selling" : "Switch to buying"} disabled={swapPending} onClick={() => side(!buy)}>↓</button>
      <div className="swap-box">
        <span className="swap-row"><span>You get</span><span>after {pctBps(fee)} fee</span></span>
        <span className="swap-row">
          <span className={`swap-amount${out ? "" : " empty"}`}>{out === undefined ? (amountIn ? "…" : "0") : out === 0n ? "0" : buy ? num(out, 0) : eth(out).replace(" ETH", "")}</span>
          {token(!buy)}
        </span>
        <span className="swap-usd">{usd(out, !buy) ?? "$0.00"}</span>
      </div>
      <div className="swap-rows">
        {curve ? <div><span>Launch fee</span><b className="hi">{pctBps(fee)} now · {pctBps(base)} in {clock(left!)}</b></div>
          : <div><span>Trade fee</span><b>{pctBps(baseBuy)} buy · {pctBps(baseSell)} sell</b></div>}
        {out ? <div><span>At least</span><b>{buy ? `${numDown(minOut(out, slip), 0)} ${plain}` : ethDown(minOut(out, slip))} ({pctBps(slip)} slippage)</b></div> : null}
        {rows}
      </div>
      {swapPending && fee !== undefined && curve ? <p className="swap-note">Fee is at most {pctBps(fee)}: it only falls until this confirms.</p> : null}
      {/* disconnected or on another network, the button opens the wallet's own step */}
      <button className={`draw-btn swap-btn${pending ? " pending" : !amountIn && address && onChain ? " empty" : ""}`} disabled={!ready && !!address && onChain}
        onClick={!address ? openConnectModal : !onChain ? () => switchChain({ chainId: deployment.chainId }) : go}>
        {pending && plan.current ? <span className="swap-spin" aria-hidden /> : null}{label}</button>
      {toast ? (
        <div className="swap-toast" role="status">
          <i aria-hidden>✓</i>
          <span><b>{toast.title}</b><span>{toast.sub}</span>
            {/* a link on any chain with an explorer; a local chain has none, so there it is plain text */}
            <Ext className="tx" href={txUrl(toast.hash)}>View tx ↗</Ext></span>
          <button type="button" aria-label="Dismiss" onClick={() => setToast(null)}>×</button>
        </div>
      ) : null}
      <TxStatus hash={approveHash as Hash | undefined} error={approveErr} />
      {swapErr ? <TxStatus hash={swapHash as Hash | undefined} error={swapErr} /> : null}
      <p className="swap-foot">{footnote ?? "Every buy and sell pays its fee into the game vault."}</p>
      {/* the hook's opening curve: LAUNCH_FEE_BPS (69%) less LAUNCH_DECAY_BPS_PER_MINUTE (1 point) a minute */}
      {curve && base !== undefined ? <p className="swap-foot">Launch fee decays from 69% to resting fee of {pctBps(base)} over {(6_900 - Number(base)) / 100} minutes.</p> : null}
    </div>
  );
}
