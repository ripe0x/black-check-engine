"use client";

import { useEffect, type ReactNode } from "react";
import { Ball, ballColour, inkFor } from "./Ball";
import { collectionMeta } from "../lib/deployment";
import { useTokenColour } from "../lib/nft";

export type ApeView = { key: string; i: number; tokenId: bigint; likeliest: boolean; odds: string; denom: string; price: string; tag: string };

/** Full-screen Poster sheet: the screen takes the ball's colour. Escape or ‹ closes it. */
function Sheet({ bg, label, onClose, children }: { bg: string; label: string; onClose: () => void; children: ReactNode }) {
  useEffect(() => {
    const esc = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", esc);
    const overflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      window.removeEventListener("keydown", esc);
      document.body.style.overflow = overflow;
    };
  }, [onClose]);
  const ink = inkFor(bg);
  return (
    <div className="poster" role="dialog" aria-modal="true" aria-label={label} style={{ background: bg, color: ink, ["--ink" as string]: ink, ["--bg" as string]: bg }}>
      <div className="poster-top">
        <button type="button" className="poster-back" onClick={onClose} aria-label="Close">‹</button>
        <span className="poster-mark">{collectionMeta.game.toUpperCase()}</span>
        <span />
      </div>
      {children}
    </div>
  );
}

/**
 * The selected state: one Ape's odds as the headline, the rest in a strip. A draw is still from the whole pool:
 * selecting a ball does not choose the prize.
 */
export function PosterSelected({ apes, i, onPick, onClose, figures, draw, chips }: {
  apes: ApeView[]; i: number; onPick: (i: number) => void; onClose: () => void; figures: ReactNode; draw: ReactNode; chips: ReactNode;
}) {
  const a = apes[i];
  const bg = useTokenColour(a.tokenId) || ballColour(a.i);
  return (
    <Sheet bg={bg} label={`${collectionMeta.short} #${a.tokenId}`} onClose={onClose}>
      <div className="poster-hero">
        <div className="poster-head">
          <span className="poster-kicker">{a.likeliest ? "Likeliest · " : ""}{collectionMeta.short} #{a.tokenId.toString()}</span>
          <span className="poster-in">1 IN</span>
          <span className="poster-denom">{a.denom}</span>
          <span className="poster-sub">{a.price} listed · {a.tag}</span>
        </div>
        <div className="poster-ball"><Ball tokenId={a.tokenId} /></div>
      </div>
      <div className="poster-strip">
        <span>{apes.length === 1 ? `1 ${collectionMeta.short.toUpperCase()}` : `${apes.length} ${collectionMeta.short.toUpperCase()}S`}</span>
        {apes.map((o, j) => j === i ? null : (
          <button key={o.key} type="button" className="poster-mini" aria-label={`${collectionMeta.short} #${o.tokenId}, ${o.odds}`} onClick={() => onPick(j)}>
            <Ball tokenId={o.tokenId} />
          </button>
        ))}
      </div>
      {figures}
      {draw}
      <p className="poster-note">Draws pick from the whole pool, not this ball.</p>
      {chips}
    </Sheet>
  );
}
