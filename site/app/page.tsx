"use client";

import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import Link from "next/link";
import { encodeFunctionData, decodeFunctionResult, formatEther, parseAbi, type Address, type Hash } from "viem";
import { useAccount, useBlockNumber, useGasPrice, usePublicClient, useReadContract, useReadContracts, useWatchContractEvent, useWriteContract } from "wagmi";
import { deployment, collectionMeta } from "./lib/deployment";
import { drawRouterAbi, fwaPoolAbi, gameAbi, hookAbi, poolOwnerAbi, tokenAbi, vaultAbi } from "./lib/abi.generated";
import { useFunding, useQuote, usePrizes, useBuybacks } from "./lib/reads";
import { eth, ethDown, ethUp, fmt, odds, num, short, mgas, bps } from "./lib/format";
import { hasPendingMigration, useMigration } from "./lib/governance";
import { NotDeployed } from "./components/NotDeployed";
import { TxStatus } from "./components/Tx";
import { Art, Ball, EMPTY, SampleArt } from "./components/Ball";
import { Dome, type DomeBall } from "./components/Dome";
import { PosterSelected, type ApeView } from "./components/Poster";
import { DrawFlow, type Block } from "./components/DrawFlow";
import { Wallet } from "./components/Nav";
import { Swap, type SwapPreview } from "./components/Swap";
import { FundingRing } from "./components/FundingRing";
import { BurnPot } from "./components/BurnPot";
import { HowItWorks } from "./components/HowItWorks";
import { Activity } from "./components/Activity";
import { useMarket, money } from "./lib/market";
import { useSurvived } from "./lib/survived";
import { chainNow, nftUrl, txUrl, useOnChain } from "./lib/chain";

/// Upkeep a draw runs after buying (booking, replacements), at the player's cost and unpaid (D76: the router sends the
/// game's tip and the sweep reward to the vault).
const SYNC_ITEMS = 10n;
/// A draw asks for the upkeep only when the router's measurement (`measureUpkeep`, simulated) is at most this; heavier
/// maintenance (a full listing batch, board growth) is left to keepers' own calls (D60).
const PLAYER_UPKEEP_LIMIT = 2_500_000n;
const SETTLE_MAX = 10n; // the in-flight limit: never more than ten draws wait

// FWA acquisition statuses that ordered processing can settle now: Ready (5), TimedOut (6)
const SETTLEABLE = new Set([5, 6]);

const deliveryEvent = parseAbi([
  "event NFTDeliveryCompleted(uint256 indexed listingId, uint256 indexed requestId, address indexed purchaser)",
]);
const failedEvent = parseAbi([
  "event NFTDeliveryFailed(uint256 indexed listingId, address indexed recipient, address collection, uint256 tokenId)",
]);

type Prize = { listingId: bigint; collection: boolean; tokenId: bigint; price: bigint; backing: bigint; refCost: bigint; probabilityE18: bigint };

export default function Play() {
  if (!deployment.deployed) return <NotDeployed />;
  return <Game />;
}

function Game() {
  const { data: f } = useFunding();
  if (!f) return <Shell field={<p className="note">Reading the chain…</p>} side={null} />;
  return f.activated ? <Live /> : <Funding />;
}

/// The home page's first screen: the open field (the dome and what is done with it) beside a full-height sidebar with
/// the pitch, the coin's figures and the swap. On narrow screens one column: the pitch, the field, then the sidebar as
/// a sheet below. `children` is the rest of the page.
function Shell({ field, side, children }: { field: ReactNode; side: ReactNode; children?: ReactNode }) {
  return (
    <div className="home">
      <div className="home-top">
        <div className="home-side-bg" aria-hidden />
        <div className="home-nav">
          <Link href="/" className="brand">{collectionMeta.game}</Link>
          <nav className="home-links" aria-label="Site"><a href="#how">How it works</a><Link href="/docs/">Docs</Link></nav>
          <span className="home-wallet"><Wallet /></span>
          <details className="home-menu">
            <summary aria-label="Menu"><span aria-hidden /></summary>
            <nav aria-label="Site"><a href="#how">How it works</a><Link href="/docs/">Docs</Link><Link href="/coin/">{collectionMeta.ticker}</Link></nav>
          </details>
        </div>
        <div className="home-field-bg" aria-hidden />
        {/* the sidebar's column on wide screens (centred vertically); on narrow ones its two parts sit apart, the pitch
            above the dome and the swap below it */}
        <div className="home-col">
          <header className="intro">
            <h1>The coin builds the pool. The pool feeds the coin.</h1>
            <p className="lede">Trading fees from $APEBALL acquire Bored Apes for an FWA custom pool. Pool revenue goes to buy and burn the coin.</p>
          </header>
          <aside className="home-side" aria-label={`Trade ${collectionMeta.ticker}`}><CoinLine />{side}</aside>
        </div>
        <section className="home-field"><MigrationBanner />{field}</section>
      </div>
      {children ? <div className="dome-app home-rest">{children}</div> : null}
    </div>
  );
}

/// The coin's figures on one line above the swap: price, market cap and 24h volume, read from the chain.
function CoinLine() {
  const m = useMarket();
  return (
    <div className="coinline">
      <Link href="/coin/" className="coinbar-name">{collectionMeta.ticker}</Link>
      <span><b>{money(m.priceEth, m.ethUsd)}</b><span className="cap">MC</span><b>{money(m.capEth, m.ethUsd)}</b><span className="cap">24H</span><b>{money(m.volumeEth, m.ethUsd)}</b></span>
    </div>
  );
}

/// A proposed or running migration: shown before anyone plays.
function MigrationBanner() {
  const m = useMigration();
  if (!m) return null;
  const now = Math.floor(Date.now() / 1000);
  if (m.started) {
    return (
      <div className="card"><b>This game is moving to a new pool system.</b> No new draws. Draws already made settle
        normally; refunds stay claimable from FWA. The {collectionMeta.short}s and treasury go to the successor at{" "}
        <code>{m.successor}</code> as the old game settles. Details: <Link href="/docs/governance/">Governance</Link>.</div>
    );
  }
  if (!hasPendingMigration(m)) return null;
  return (
    <div className="card"><b>A migration has been proposed</b> to <code>{m.pending}</code>. {m.executableAt > now
      ? `It can execute from ${new Date(m.executableAt * 1000).toUTCString()}.` : "It can execute now."} When it
      executes, new draws stop for good and the game moves to the successor. Details: <Link href="/docs/governance/">Governance</Link>.</div>
  );
}

// ------------------------------------------------------------------ funding mode

// Before the game opens (design handoff "pre-funded dome"): the vault puts everything into the live bid until it holds
// the first Ape, then funds the board, reserve and opening keeper pay at once; keepers list the board and anyone
// activates. The ring around the machine shows both costs; the glass holds empty balls (no prizes exist yet) and the
// real first Ape once bought; the swap beside it is the action, since trading fees are what fund it.
const PILE = 18; // empty balls in the glass while funding (the ring shows the progress)
type Stage = "funding_bid" | "bid_live" | "funding_board" | "listing" | "opening";
const toN = (w: bigint | undefined) => (w === undefined ? 0 : Number(formatEther(w)));

function Funding() {
  const { data: f, refetch } = useFunding();
  const held = !!f && f.collectionHeld > 0n;
  // the first Ape once held: from custody, or its listing once the board work has listed it
  const { data: inCustody } = useReadContract({ address: deployment.poolOwner, abi: poolOwnerAbi, functionName: "custodyCount", query: { enabled: held } });
  const { data: custodyId } = useReadContract({ address: deployment.poolOwner, abi: poolOwnerAbi, functionName: "custodyAt", args: [0n], query: { enabled: held && !!inCustody } });
  const { data: listedId } = useReadContract({ address: deployment.poolOwner, abi: poolOwnerAbi, functionName: "listedAt", args: [0n], query: { enabled: held && inCustody === 0n } });
  const { data: listing } = useReadContract({ address: deployment.poolOwner, abi: poolOwnerAbi, functionName: "cListings", args: [listedId ?? 0n], query: { enabled: listedId !== undefined } });
  const { data: live } = useReadContract({ address: deployment.game, abi: gameAbi, functionName: "liveCount", query: { refetchInterval: 12_000 } });
  const { data: boardSize } = useReadContract({ address: deployment.game, abi: gameAbi, functionName: "boardSize" });
  const { data: allowance } = useReadContract({ address: deployment.game, abi: gameAbi, functionName: "keeperAvailable", query: { refetchInterval: 12_000 } });
  const { data: pool } = useReadContract({ address: deployment.game, abi: gameAbi, functionName: "pool" });
  const { data: patternLen } = useReadContract({ address: deployment.game, abi: gameAbi, functionName: "patternLength" });
  const { data: rows } = useReadContracts({ contracts: Array.from({ length: Number(patternLen ?? 0n) }, (_, r) =>
    ({ address: deployment.game, abi: gameAbi, functionName: "rowAt", args: [BigInt(r)] }) as const) });
  const plan = useMemo(() => [...new Set((rows ?? []).flatMap((x) => (x.status === "success" ? [x.result as bigint] : [])))]
    .sort((a, z) => (a < z ? -1 : 1)), [rows]);
  const { data: sent, refetch: refetchSent } = useReadContract({ address: deployment.vault, abi: vaultAbi, functionName: "gameCapitalSent", query: { refetchInterval: 12_000 } });
  // read again with the funding figures, so the stage never mixes a fresh need with a stale amount sent
  useEffect(() => { refetchSent(); }, [f?.capitalNeed, f?.collectionHeld]); // eslint-disable-line react-hooks/exhaustive-deps
  // every trading fee as it arrives: a tag at the ring's end for two seconds, a nudge through the pile, fresh figures
  const [pulse, setPulse] = useState<{ n: number; tag?: string }>({ n: 0 });
  useWatchContractEvent({ address: deployment.hook, abi: hookAbi, eventName: "FeeTaken", onLogs: (logs) => {
    const l = logs[logs.length - 1];
    setPulse((p) => ({ n: p.n + 1, tag: `+${fmt(toN(l.args.fee))} ETH · ${l.args.buy ? "buy" : "sell"}` }));
    refetch();
  } });
  useEffect(() => {
    if (!pulse.tag) return;
    const t = setTimeout(() => setPulse((p) => ({ ...p, tag: undefined })), 2000);
    return () => clearTimeout(t);
  }, [pulse.n]); // eslint-disable-line react-hooks/exhaustive-deps
  const [preview, setPreview] = useState<SwapPreview>({ status: "idle" });

  const apeId = inCustody ? custodyId : listing?.[0];
  const thr = f?.activationThreshold ?? 0n, bal = f?.balance ?? 0n, need = f?.capitalNeed ?? 0n;
  // funded: the vault has sent the board's capital (the game's need then falls to the keeper pay listing has used,
  // topped up at activation)
  // the board's capital is in: sent to the game, or in the vault ready for the next keeper call to send and list
  const listed = held && ((sent ?? 0n) > 0n || (!!f && f.capitalNeed + (allowance ?? 0n) > 0n && f.balance >= f.capitalNeed + (allowance ?? 0n)));
  const stage: Stage = !f ? "funding_bid" : f.ready ? "opening" : listed ? "listing" : held ? "funding_board"
    : f.liveBid >= thr && thr > 0n ? "bid_live" : "funding_bid";
  // the Ape's segment: the threshold the bid fills to at once, or the live bid once metering has raised it beyond that
  // (a floor above the reference price: the bid keeps climbing until a holder sells); once bought, the price paid (the
  // threshold then resets to 75% of it, for the next Ape)
  const apeT = toN(!f ? 0n : held ? f.lastPrice : f.liveBid > thr ? f.liveBid : thr);
  // the board's cost: what it still needs (board, reserve, opening keeper pay) until funded, then what was sent for it
  const boardT = listed ? toN(sent) : toN(need + (allowance ?? 0n));
  const after = stage === "listing" || stage === "opening";
  const ape = held || stage === "bid_live" ? apeT : Math.min(toN(bal), apeT);
  const board = after ? boardT : stage === "funding_board" ? Math.min(toN(bal), boardT) : 0;
  const provisional = stage === "bid_live" ? Math.min(toN(bal - f!.liveBid), boardT) : stage === "funding_bid" ? Math.max(0, Math.min(toN(bal) - apeT, boardT)) : 0;
  const fee = preview.status === "preview" || preview.status === "pending" ? toN(preview.fee) : 0;
  // the glass's one figure: what is in toward opening draws (while the bid fills, the bid itself)
  const balls: DomeBall[] = [
    ...Array.from({ length: PILE }, (_, k) => ({ key: `e${k}`, i: k, tokenId: 0n, small: true, colour: EMPTY })),
    ...(held && apeId !== undefined ? [{ key: `ape${apeId}`, i: 1, tokenId: apeId, label: `${collectionMeta.short} #${apeId}` }] : []),
  ];
  if (!f) return null;
  const ape1 = collectionMeta.short;
  const prizes = Number(boardSize ?? 50n), listedN = Number(live ?? 0n);

  const steps: [string, "done" | "active" | "todo", string][] = [
    ["First " + ape1, held ? "done" : "active", held ? `${apeId !== undefined ? `#${apeId} · ` : ""}${fmt(toN(f.lastPrice))} ETH`
      : stage === "bid_live" ? "Bid live · any holder can sell" : fee ? `${fmt(Math.min(ape + fee, apeT))} / ${fmt(apeT)} ETH after this trade` : `${fmt(ape)} / ${fmt(apeT)} ETH bid`],
    ["Prize board", after ? "done" : stage === "funding_board" || stage === "bid_live" ? "active" : "todo",
      after ? `${fmt(boardT)} ETH funded` : stage === "bid_live" ? `${fmt(provisional)} / ${fmt(boardT)} ETH waiting` : `${fmt(board)} / ${fmt(boardT)} ETH`],
    ["Draws open", after ? "active" : "todo", stage === "opening" ? "Opening now" : stage === "listing" ? `Listing prizes · ${listedN} / ${prizes}` : `${ape1} + ${prizes} Shapes NFTs`],
  ];
  return (
    <Shell field={
        <div className="fund-main" aria-label={`The first ${ape1} is being funded`}>
          <div className="fund-dome">
            {/* listing and opening: the balls stir while the keepers build the board */}
            <div className="fund-machine"><Dome balls={balls} nudge={pulse.n} mixing={after ? 0.45 : 0} /></div>
            {after ? (
              <div className="fund-label" role="status">
                <b>{stage === "opening" ? "Draws opening" : "Building the prize board"}</b>
                <span>{stage === "opening" ? `${listedN} prizes and the ${ape1} are ready` : `${listedN} of ${prizes} prizes listed`}</span>
              </div>
            ) : null}
            <FundingRing apeT={apeT} boardT={boardT || 1} ape={ape} board={board} provisional={provisional}
              preview={fee || undefined} pending={preview.status === "pending"} glow={stage === "bid_live"}
              tag={pulse.tag ?? (stage === "bid_live" ? "BID LIVE" : undefined)}
              apeState={held || stage === "bid_live" ? "done" : "active"} boardState={after ? "done" : stage === "funding_board" ? "active" : stage === "bid_live" ? "provisional" : "upcoming"}
              apeValue={`${fmt(apeT)} ETH`} boardValue={`${fmt(boardT)} ETH`} />
          </div>
          <ol className="fund-steps">
            {steps.map(([t, st, sub], k) => (
              <li key={t} className={st}><i aria-hidden>{st === "done" ? "✓" : k + 1}</i><span><b>{t}</b><span>{sub}</span></span></li>
            ))}
          </ol>
          <LockedDraw ape={ape1} opening={after} />
        </div>
      } side={
        <Swap onPreview={setPreview}
          rows={stage === "funding_board" ? <div><span>Board needs</span><b>{fmt(Math.max(0, boardT - board))} ETH more</b></div> : undefined}
          footnote={`Every buy and sell pays its fee into the game vault. The vault buys the first ${ape1}, then funds the prize board.`} />
      }>
      <HowItWorks />
      <div className="lower">
        <Activity pool={pool} funding />
        <aside className="inventory" aria-label="In the draw">
          <h2>{held ? 1 : 0} {ape1}{held ? "" : "s"} in the draw</h2>
          {held && apeId !== undefined ? (
            <div className="rows">
              <div className="row-ape">
                <span className="row-ball"><Ball tokenId={apeId} /></span>
                <span className="row-mid"><span className="row-name"><b>{ape1} #{apeId.toString()}</b></span><span className="row-tag">joins when draws open</span></span>
                <span className="row-end"><b>{eth(f.lastPrice)}</b></span>
              </div>
            </div>
          ) : <p className="note">The first {ape1} joins when the vault buys it.</p>}
          <h3 className="cap">Other prizes on the board</h3>
          <BoardTiers tiers={plan.map((backing) => ({ backing, sub: "Funding pending" }))} />
          <p className="note">Every Shape is redeemable for its ETH. <Link href="/docs/shapes/">More</Link></p>
        </aside>
      </div>
    </Shell>
  );
}

/// The board's prize tiers, smallest first: one listed prize's art (or, before any is minted, a random sample of that
/// value), and a line under each name.
function BoardTiers({ tiers }: { tiers: { backing: bigint; sub: string; sample?: bigint }[] }) {
  const { data: shapesNft } = useReadContract({ address: deployment.poolOwner, abi: poolOwnerAbi, functionName: "shapes" });
  const { data: packsNft } = useReadContract({ address: deployment.poolOwner, abi: poolOwnerAbi, functionName: "packs" });
  return (
    <div className="board-tiers">
      {tiers.map((t) => {
        const pack = isPack(t.backing);
        const name = `${eth(t.backing)} ${pack ? "Pack" : "Shape"}`;
        return (
          <div key={t.backing.toString()} className="board-tier">
            {t.sample === undefined ? <SampleArt value={t.backing} shapes={shapesNft} packs={packsNft} alt={`A sample ${name}`} />
              : shapesNft && packsNft ? <Art tokenId={t.sample} nft={pack ? packsNft : shapesNft} alt={`A ${name}`} /> : <span className="art" />}
            <b>{name}</b>
            <span>{t.sub}</span>
          </div>
        );
      })}
    </div>
  );
}

/// The draw panel as it will look once the game is live, locked: there is a game here, and funding opens it.
function LockedDraw({ ape, opening }: { ape: string; opening: boolean }) {
  return (
    <div className="fund-draw" role="group" aria-label="Draws, not open yet">
      <div className="dd-row" aria-hidden>
        <button type="button" className="dd-step" tabIndex={-1} disabled>−</button>
        <button type="button" className="dd-btn off two" tabIndex={-1} disabled><span>DRAWS LOCKED</span><small>{opening ? "Opening now" : "Opens when fully funded"}</small></button>
        <button type="button" className="dd-step" tabIndex={-1} disabled>+</button>
      </div>
      <p className="dd-note">Each draw wins the {ape} or an ETH-backed Shape.</p>
    </div>
  );
}

// ------------------------------------------------------------------ live game

/// "1 in N" denominator of a 1e18-scaled probability.
const denom = (p: bigint) => (p > 0n ? Math.round(1e18 / Number(p)).toLocaleString() : "–");

function Live() {
  const { data: prizes } = usePrizes();
  const { data: q } = useQuote();
  const { data: b } = useBuybacks();
  const { data: f } = useFunding();
  const [count, setCount] = useState(1);
  const d = useDraw(BigInt(count));
  const [sel, setSel] = useState<number | null>(null);
  const list = (prizes ?? []) as readonly Prize[];
  const shapes = list.filter((p) => !p.collection);
  // A ball's fallback colour follows listing order, so it keeps it while its odds move; the likeliest is lowest in
  // the dome and first everywhere else.
  const coll = useMemo(() => {
    const c = list.filter((p) => p.collection).sort((a, z) => (a.listingId < z.listingId ? -1 : 1));
    return c.map((p, i) => ({ p, i })).sort((a, z) => (a.p.probabilityE18 > z.p.probabilityE18 ? -1 : 1));
  }, [list]);
  const survived = useSurvived(coll.map(({ p }) => p.listingId));
  const apes: ApeView[] = coll.map(({ p, i: k }, i) => {
    const n = survived(p.listingId);
    return { key: p.listingId.toString(), i: k, tokenId: p.tokenId, likeliest: i === 0 && (coll.length === 1 || p.probabilityE18 > coll[1].p.probabilityE18), odds: odds(p.probabilityE18), denom: denom(p.probabilityE18), price: eth(p.price),
      tag: n === undefined ? "in the draw" : `survived ${n.toLocaleString()} pull${n === 1 ? "" : "s"}` };
  });
  // the next Ape: the vault's live bid, fed by every trade's fee, against the last price it paid for one
  const bid = f?.liveBid, last = f?.lastPrice;
  const toNext = bid !== undefined && last ? Math.min(1, Number((bid * 10_000n) / last) / 10_000) : 0;
  const anyApe = coll.reduce((a, { p }) => a + p.probabilityE18, 0n);
  // the board by tier: how many prizes of each backing are listed now, and one of them to show its art
  const tiers = useMemo(() => {
    const m = new Map<bigint, { n: number; sample: bigint }>();
    for (const s of shapes) {
      const t = m.get(s.backing);
      m.set(s.backing, { n: (t?.n ?? 0) + 1, sample: t?.sample ?? s.tokenId });
    }
    return [...m.entries()].sort((a, c) => (a[0] < c[0] ? -1 : 1));
  }, [shapes]);
  const { data: shapesNft } = useReadContract({ address: deployment.poolOwner, abi: poolOwnerAbi, functionName: "shapes" });
  const { data: packsNft } = useReadContract({ address: deployment.poolOwner, abi: poolOwnerAbi, functionName: "packs" });
  // A sample of the board for the dome, not every prize: each tier at least once, about one ball per 16 prizes,
  // at most 12 balls.
  const sample = useMemo(() => {
    const byTier = new Map<bigint, Prize[]>();
    for (const p of shapes) byTier.set(p.backing, [...(byTier.get(p.backing) ?? []), p]);
    const tiersUp = [...byTier.entries()].sort((a, z) => (a[0] < z[0] ? -1 : 1));
    const per = Math.max(16, Math.ceil(shapes.length / 12));
    const out: Prize[] = [];
    for (const [, ps] of tiersUp) out.push(...ps.slice(0, Math.max(1, Math.round(ps.length / per))));
    return out.slice(0, 12);
  }, [shapes]);
  // Shapes and Packs first, so they settle at the bottom (they are the likelier prizes) and the Apes sit on top
  const domeBalls: DomeBall[] = [
    ...(shapesNft && packsNft ? sample.map((p, i) => ({ key: `s${p.listingId}`, i: i + 3, tokenId: p.tokenId, small: true, nft: isPack(p.backing) ? packsNft : shapesNft })) : []),
    ...apes.map((a) => ({ key: a.key, i: a.i, tokenId: a.tokenId, label: `${collectionMeta.short} #${a.tokenId}, ${a.odds} per draw` })),
  ];
  const N = apes.length, many = `${collectionMeta.short}${N === 1 ? "" : "s"}`;

  const inventory = `${N} ${many} · ${shapes.length} Shapes`;
  // the Poster's own figures and DRAW: it closes and brings the draw panel into view, where the draw is followed
  const homeRef = useRef<HTMLElement>(null);
  const toDraw = () => { setSel(null); homeRef.current?.scrollIntoView({ behavior: "smooth", block: "end" }); };

  return (
    <Shell field={
      <section ref={homeRef} className="dome-home" aria-label={`Draw for ${collectionMeta.article} ${collectionMeta.short}`}>
        <DrawFlow d={d} count={count} setCount={setCount} apes={coll.map(({ p }) => p)} dome={(cue) => <>
          <Dome balls={domeBalls} mixing={cue.mixing} lift={cue.lift} />
          {N === 0 ? (
            <p className="note center">No {collectionMeta.short}s in the draw yet, only ETH-backed Shapes. The next {collectionMeta.short} joins when the vault buys one.</p>
          ) : null}
        </>} />
        <YourDraws pool={d.pool} />
      </section>
    } side={<><Swap /><div className="home-pot"><BurnPot /></div></>}>

      <HowItWorks />

      <div className="next-up">
        <span className="next-up-head"><span className="cap">Next {collectionMeta.short}</span><span className="cap">{Math.round(toNext * 100)}%</span></span>
        <b>{eth(bid)} <span>of {eth(last)}</span></b>
        <span className="next-up-bar"><span style={{ width: `${toNext * 100}%` }} /></span>
        <span className="sub">Live bid, funded by trading fees. Last {collectionMeta.short} bought at {eth(last)}.</span>
      </div>

      {/* the feed is the main column; the inventory sits beside it, narrower */}
      <div className="lower">
        <Activity pool={d.pool} />
        <aside className="inventory" aria-label="In the draw">
        <h2>{N} {many} in the draw</h2>
        <p className="note">Each pull an {collectionMeta.short} survives lowers its price and raises its odds.</p>
        <div className="rows">
          {apes.map((a, i) => (
            <button key={a.key} type="button" className="row-ape" onClick={() => setSel(i)}>
              <span className="row-ball"><Ball tokenId={a.tokenId} /></span>
              <span className="row-mid">
                <span className="row-name"><b>{collectionMeta.short} #{a.tokenId.toString()}</b>{a.likeliest ? <span>likeliest</span> : null}</span>
                <span className="row-tag">{a.tag}</span>
              </span>
              <span className="row-end"><b>{a.price}</b><span>{a.odds}</span></span>
            </button>
          ))}
        </div>
        <h3 className="cap">Other prizes on the board</h3>
        <BoardTiers tiers={tiers.map(([backing, t]) => ({ backing, sample: t.sample, sub: `${t.n} on the board` }))} />
        <p className="note">Every Shape is redeemable for its ETH. <Link href="/docs/shapes/">More</Link></p>
        </aside>
      </div>

      {sel !== null && apes[sel] ? (
        <PosterSelected apes={apes} i={sel} onPick={setSel} onClose={() => setSel(null)} chips={<CoinBar />}
          figures={<div className="figures"><div><span className="fig">{ethUp(d.fee)}</span><span className="cap">Cost per draw</span></div><div><span className="fig">{inventory}</span><span className="cap">In the draw</span></div></div>}
          draw={<button className="draw-btn" onClick={toDraw}>DRAW</button>} />
      ) : null}
    </Shell>
  );
}

/// The coin bar on the Poster: the ticker, its price, market cap and 24h volume, all read from the chain.
function CoinBar() {
  const m = useMarket();
  return (
    <div className="coinbar">
      <Link href="/coin/" className="coinbar-name">{collectionMeta.ticker}</Link>
      <span><b>{money(m.priceEth, m.ethUsd)}</b><span className="cap">Price</span></span>
      <span><b>{money(m.capEth, m.ethUsd)}</b><span className="cap">Market cap</span></span>
      <span><b>{money(m.volumeEth, m.ethUsd)}</b><span className="cap">24h vol</span></span>
    </div>
  );
}

/// Everything `count` draws in one transaction need and cost right now, and the call itself (it resolves to the
/// transaction hash once the wallet has sent it). The draw flow (DrawFlow) follows the transaction from there.
function useDraw(count: bigint) {
  const { address } = useAccount();
  const onChain = useOnChain();
  const client = usePublicClient();
  const { data: gasPrice } = useGasPrice({ query: { refetchInterval: 15_000 } });
  // the ticket moves with the board (a won prize leaves it until the next restock), so the price shown follows every
  // new block rather than only gas or gate changes
  const { data: head } = useBlockNumber({ watch: true });
  const { data: pool } = useReadContract({ address: deployment.game, abi: gameAbi, functionName: "pool" });
  const { data: open } = useReadContract({ address: pool as Address, abi: fwaPoolAbi, functionName: "localPurchasesEnabled", query: { enabled: !!pool, refetchInterval: 10_000 } });
  const { data: gate } = useReadContract({ address: deployment.poolOwner, abi: poolOwnerAbi, functionName: "canPurchase", args: [address ?? "0x0000000000000000000000000000000000000000"], query: { refetchInterval: 6_000 } });
  const [quote, setQuote] = useState<{ fee: bigint; vrf: bigint; version: bigint; count: bigint } | null>(null);
  const [fresh, setFresh] = useState(0); // bumped to re-read the price (after a draw the contract refused)
  const [settle, setSettle] = useState(0n);
  // the upkeep this draw would run (measured, an upper bound) and its gas budget
  const [upkeep, setUpkeep] = useState<{ gas: bigint; budget: bigint } | null>(null);
  const { writeContractAsync } = useWriteContract();

  // Earlier draws whose randomness has arrived but that nobody has settled yet (normally none: the randomness
  // callback settles them). The router settles them first, so a backlog never keeps the draw closed.
  useEffect(() => {
    if (!client || !pool) return;
    let live = true;
    (async () => {
      const p = pool as Address;
      const unsettled = await client.readContract({ address: p, abi: fwaPoolAbi, functionName: "unsettledAcquisitionCount" });
      let seq = await client.readContract({ address: p, abi: fwaPoolAbi, functionName: "nextSequenceToProcess" });
      let n = 0n;
      while (n < unsettled && n < SETTLE_MAX) {
        const id = await client.readContract({ address: p, abi: fwaPoolAbi, functionName: "requestIdAtSequence", args: [seq] });
        const a = await client.readContract({ address: p, abi: fwaPoolAbi, functionName: "acquisitions", args: [id] });
        if (!SETTLEABLE.has(Number(a[a.length - 1]))) break;
        n += 1n;
        seq += 1n;
      }
      if (live) setSettle(n);
    })().catch(() => {});
    return () => {
      live = false;
    };
  }, [client, pool, gate]);

  useEffect(() => {
    if (!client || !pool || !gasPrice) return;
    let live = true;
    (async () => {
      // The price after the settlement this draw will make (settling removes prizes and moves the ticket), simulated
      // through the router. FWA's VRF fee depends on the transaction's gas price: quote with it.
      // fee and vrf are per draw (FWA charges count × (fee + vrf))
      const data = encodeFunctionData({ abi: drawRouterAbi, functionName: "quote", args: [pool as Address, settle, count] });
      const r = await client.call({ to: deployment.drawRouter, data, gasPrice });
      const [fee, vrf] = decodeFunctionResult({ abi: drawRouterAbi, functionName: "quote", data: r.data! }) as readonly [bigint, bigint, bigint];
      const version = await client.readContract({ address: pool as Address, abi: fwaPoolAbi, functionName: "inventoryVersion" });
      if (live) setQuote({ fee, vrf, version, count });
    })().catch(() => live && setQuote(null));
    return () => {
      live = false;
    };
  }, [client, pool, gasPrice, settle, count, gate, fresh, head]);

  // The upkeep this draw would run: the router measures the game's unpaid `upkeep` in a simulation (an upper bound: with the player's own
  // draw in flight the game lists replacements only when the board is low). Asked for only when it is light; the
  // budget is 30% above the measurement, so a state change before inclusion rarely makes it fall short (and if it
  // does, only the upkeep fails, never the draw).
  useEffect(() => {
    if (!client || !gasPrice) return;
    let live = true;
    (async () => {
      const data = encodeFunctionData({ abi: drawRouterAbi, functionName: "measureUpkeep", args: [deployment.game, SYNC_ITEMS] });
      const r = await client.call({ to: deployment.drawRouter, data, gasPrice, account: address });
      const [ran, used] = decodeFunctionResult({ abi: drawRouterAbi, functionName: "measureUpkeep", data: r.data! }) as readonly [boolean, bigint];
      if (live) setUpkeep(ran && used <= PLAYER_UPKEEP_LIMIT ? { gas: used, budget: (used * 13n) / 10n + 50_000n } : null);
    })().catch(() => live && setUpkeep(null));
    return () => {
      live = false;
    };
  }, [client, gasPrice, address, gate]);

  // the draw call as it would be sent now (price and inventory version read again): `send` sends it; `sendRedeem` and
  // `redeemCall` (for a batch) send it paid with won prizes
  const prepare = async () => {
    if (!quote || !address || !pool || !client) throw new Error("not ready");
    // FWA's inventory version moves whenever a draw settles or the keeper restocks (seconds after any draw), and a draw
    // carrying an older one reverts (InventoryVersionMismatch): read it, and the price, again now. The fee cap stays
    // the price shown; if the ticket or the randomness fee has risen, refresh the shown price instead of sending, so
    // the wallet never opens on more than the panel showed.
    // FWA charges the randomness fee at the transaction's own gas price, and a wallet may send above the price it was
    // given (or prices rise before inclusion): quote at the gas price now, not the last poll, and send 30% over the
    // randomness fee (a 21% rise was seen from a wallet's own pricing; FWA refunds any excess in the same transaction)
    const gp = await client.getGasPrice().then((g) => (gasPrice && gasPrice > g ? gasPrice : g));
    const fresh = await client.call({ to: deployment.drawRouter, gasPrice: gp,
      data: encodeFunctionData({ abi: drawRouterAbi, functionName: "quote", args: [pool as Address, settle, count] }) });
    const [feeNow, vrfNow] = decodeFunctionResult({ abi: drawRouterAbi, functionName: "quote", data: fresh.data! }) as readonly [bigint, bigint, bigint];
    if (feeNow > quote.fee || vrfNow > quote.vrf) {
      requote();
      throw new Error("PriceMoved"); // nothing was sent: the panel shows the new price for another press
    }
    const version = await client.readContract({ address: pool as Address, abi: fwaPoolAbi, functionName: "inventoryVersion" });
    const vrfWithMargin = (quote.vrf * 13n) / 10n; // per draw
    // the deadline counts from the chain's own clock (chainNow), not this browser's: FWA reverts a draw whose
    // deadline has passed, and a fork's clock can be weeks from the browser's
    const now = await chainNow(client);
    return {
      abi: drawRouterAbi, address: deployment.drawRouter, functionName: "draw" as const,
      // settle the ready backlog; `count` draws; then, when it is light, the game's upkeep (sync, up to 10 items)
      // within its budget and the bid sweep, unpaid (D76); maxAcquisitionFee = the quoted fee per draw; negative
      // slippage tolerance 10% (FWA's UI default); 15-minute deadline. The router buys for the connected wallet and
      // returns the change. The wallet's gas estimate includes the budget (the router requires it).
      args: [pool as Address, deployment.game, settle, upkeep ? SYNC_ITEMS : 0n, upkeep?.budget ?? 0n, count, quote.fee, 0n,
        1_000n, version, now + 900n] as const,
      value: count * (quote.fee + vrfWithMargin),
      gasPrice: gp,
    };
  };
  // The keeper relists won prizes as soon as no draw is in flight, which moves FWA's inventory version seconds after
  // a run settles: a call prepared just before would fail in the wallet's own simulation. So simulate it here first,
  // as the player, and on a version mismatch prepare it once more (the version and price read again, so a price rise
  // stops here) and simulate that too; any other failure goes to the wallet unchanged, which shows it.
  const checked = async <C extends { address: Address; value: bigint }>(make: () => Promise<C>): Promise<C> => {
    let c = await make();
    if (!client || !address) return c;
    for (let retried = false; ; retried = true) {
      try {
        await client.call({ account: address, to: c.address, value: c.value, data: encodeFunctionData(c as never) });
        return c;
      } catch (e) {
        if (retried || !versionMoved(e)) return c;
        c = await make();
      }
    }
  };
  // the wallet must be on the deployment's chain, or it refuses
  const send = async () => writeContractAsync({ chainId: deployment.chainId, ...(await checked(prepare)) });
  // the same draw paid with won prizes: the router takes and redeems the player's Shapes and Packs first (they must
  // have approved it), so the wallet sends only what the prizes do not cover; anything over comes back as change
  const prepareRedeem = async (shapeIds: bigint[], packIds: bigint[], back: bigint) => {
    const c = await prepare();
    const [p, game, s, syncCount, upkeepGas, n, maxFee, minWeightedValue, maxSlippageBps, expectedInventoryVersion, deadline] = c.args;
    return {
      abi: drawRouterAbi, address: deployment.drawRouter, functionName: "redeemAndDraw" as const,
      args: [{ pool: p, game, settle: s, syncCount, upkeepGas, count: n, maxFee, minWeightedValue, maxSlippageBps, expectedInventoryVersion, deadline },
        shapeIds, packIds] as const,
      value: c.value > back ? c.value - back : 0n,
      gasPrice: c.gasPrice,
    };
  };
  const sendRedeem = async (shapeIds: bigint[], packIds: bigint[], back: bigint) =>
    writeContractAsync({ chainId: deployment.chainId, ...(await checked(() => prepareRedeem(shapeIds, packIds, back))) });
  const redeemCall = async (shapeIds: bigint[], packIds: bigint[], back: bigint) => {
    const c = await checked(() => prepareRedeem(shapeIds, packIds, back));
    return { to: c.address, data: encodeFunctionData(c), value: c.value }; // a batch takes no gas price per call
  };
  // the gate is closed by a settleable backlog: drawing settles it first, so the button stays enabled
  const busy = gate === false && settle === 0n;
  const reason = open === undefined ? null : !open ? "Draws are paused. Try again shortly."
    : busy ? "Earlier draws are settling. Try again shortly." : null;
  // shown to the player: the ticket per draw. The randomness fee and gas come on top, both priced at gas at draw time.
  const fee = quote?.fee;
  // the price check is the first read only: a count change keeps showing the last per-draw price while the new one
  // loads (no flash), and the draw waits for the quote of this count
  const quoting = !quote;
  const ready = !!address && onChain && quote?.count === count && !!open && !busy;
  const block: Block = !address ? "connect" : !onChain ? "network" : open === false ? "paused" : null;
  const requote = useCallback(() => { setQuote(null); setFresh((x) => x + 1); }, []);
  // what the draws cost, the randomness fee included (the send adds 30% on that fee, refunded)
  const value = quote ? count * (quote.fee + quote.vrf) : undefined;
  // the most a sent draw can take: what it sends, the randomness fee with its 30% margin (FWA refunds the unused part)
  const maxValue = quote ? count * (quote.fee + (quote.vrf * 13n) / 10n) : undefined;
  return { pool: pool as Address | undefined, address, fee, value, maxValue, quoting, reason, ready, block, send, sendRedeem, redeemCall, requote };
}

/// FWA's own buyer actions, the same as on FWA's site: withdraw refunded tickets; retry or refund a prize whose
/// delivery to your wallet failed.
function YourDraws({ pool }: { pool?: Address }) {
  const { address } = useAccount();
  const client = usePublicClient();
  const { writeContract, data: hash, error, isPending } = useWriteContract();
  const { data: credit } = useReadContract({ address: pool, abi: fwaPoolAbi, functionName: "acquisitionRefundCredit", args: [address ?? "0x0000000000000000000000000000000000000000"], query: { enabled: !!pool && !!address, refetchInterval: 15_000 } });
  const [failed, setFailed] = useState<bigint[]>([]);
  useEffect(() => {
    if (!client || !pool || !address) return;
    (async () => {
      const head = await client.getBlockNumber();
      const logs = await client.getContractEvents({ address: pool, abi: failedEvent, eventName: "NFTDeliveryFailed", args: { recipient: address }, fromBlock: head > 200_000n ? head - 200_000n : 0n });
      const pending: bigint[] = [];
      for (const l of logs) {
        const listing = await client.readContract({ address: pool, abi: fwaPoolAbi, functionName: "listings", args: [l.args.listingId!] });
        if (Number(listing[listing.length - 1]) === 6) pending.push(l.args.listingId!); // DeliveryPending
      }
      setFailed([...new Set(pending)]);
    })().catch(() => {});
  }, [client, pool, address, hash]);
  if (!pool || !address || (!credit && failed.length === 0)) return null;
  return (
    <div className="card">
      <h3>Your draws</h3>
      {credit ? (
        <p>Refunded tickets: {ethDown(credit)}{" "}
          <button disabled={isPending} onClick={() => writeContract({ chainId: deployment.chainId, address: pool, abi: fwaPoolAbi, functionName: "withdrawAcquisitionRefund" })}>Withdraw</button></p>
      ) : null}
      {failed.map((id) => (
        <p key={id.toString()}>Prize from listing {id.toString()} could not be delivered to your wallet.{" "}
          <button disabled={isPending} onClick={() => writeContract({ chainId: deployment.chainId, address: pool, abi: fwaPoolAbi, functionName: "retryNFTDelivery", args: [id] })}>Retry delivery</button>{" "}
          <button disabled={isPending} onClick={() => writeContract({ chainId: deployment.chainId, address: pool, abi: fwaPoolAbi, functionName: "refundFailedDelivery", args: [id] })}>Refund instead</button></p>
      ))}
      <TxStatus hash={hash as Hash | undefined} error={error} />
    </div>
  );
}

/// Shapes denominations, largest first (the Shapes contract mints only these).
const DENOMS = [
  10n ** 20n, 5n * 10n ** 19n, 10n ** 19n, 5n * 10n ** 18n, 10n ** 18n, 5n * 10n ** 17n, 10n ** 17n, 5n * 10n ** 16n, 10n ** 16n,
];

/** FWA's `InventoryVersionMismatch(uint256,uint256)` revert, anywhere in an error's cause chain (raw data or message). */
const VERSION_MISMATCH = "0x843dd7be";
function versionMoved(e: unknown): boolean {
  for (let x = e as { data?: unknown; cause?: unknown; message?: unknown } | undefined, i = 0; x && i < 8; i++) {
    const d = typeof x.data === "string" ? x.data : (x.data as { data?: unknown } | undefined)?.data;
    if (typeof d === "string" && d.toLowerCase().startsWith(VERSION_MISMATCH)) return true;
    if (typeof x.message === "string" && x.message.toLowerCase().includes(VERSION_MISMATCH.slice(2))) return true;
    x = x.cause as typeof x;
  }
  return false;
}

/// A prize backing that is not a Shapes denomination is a Draw Pack.
function isPack(backing: bigint): boolean {
  return !DENOMS.includes(backing);
}
