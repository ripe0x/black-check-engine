"use client";

import type { Address } from "viem";
import { useSampleArt, useTokenImage } from "../lib/nft";

// Ball colours by listing order, for screens that take a ball's colour (the Poster) until the art's own background is
// known (useTokenColour). The ball itself stays empty while its art loads, or if it never does.
const COLOURS = ["#1f4dff", "#e5262c", "#ff6b14", "#161616", "#e9e8e3", "#7b3fe4", "#14843a", "#ffb400"];

/** An empty glass ball: the funding pile, and any ball whose art has not loaded. */
export const EMPTY = "radial-gradient(circle at 34% 28%, #3a3f4a 0, #16181e 38%, #050608 78%)";
export const ballColour = (i: number) => COLOURS[i % COLOURS.length];
/** Ink that reads on a colour (Poster screens take the ball's colour as their background). */
export function inkFor(hex: string) {
  const v = parseInt(hex.slice(1), 16), r = v >> 16, g = (v >> 8) & 255, b = v & 255;
  return 0.299 * r + 0.587 * g + 0.114 * b > 160 ? "#170c05" : "#ffffff";
}

/**
 * A token as a glossy ball: its own art, from its tokenURI (a collection NFT unless `nft` says otherwise). Apes fill
 * the ball; `fit` (Shapes and Packs) shrinks the whole artwork inside it on black, which matches their black art.
 */
export function Ball({ tokenId, nft, rot = 0, fit = false }: { tokenId: bigint; nft?: Address; rot?: number; fit?: boolean }) {
  const img = useTokenImage(tokenId, nft);
  return (
    <div className={fit ? "ball fit" : "ball"} style={{ background: img && fit ? "#000000" : EMPTY }}>
      {img ? <img src={img} alt="" style={rot ? { transform: `rotate(${rot}deg) scale(1.06)` } : undefined} /> : null}
    </div>
  );
}

/** A token's art in its standard square format (Shapes and Packs outside the dome). */
export function Art({ tokenId, nft, alt }: { tokenId: bigint; nft?: Address; alt: string }) {
  const img = useTokenImage(tokenId, nft);
  return <span className="art">{img ? <img src={img} alt={alt} /> : null}</span>;
}

/** Sample art for a prize of `value` that does not exist yet: a random Shape of that value, or a Pack's fan of them. */
export function SampleArt({ value, shapes, packs, alt }: { value: bigint; shapes?: Address; packs?: Address; alt: string }) {
  const img = useSampleArt(value, shapes, packs);
  return <span className="art">{img ? <img src={img} alt={alt} /> : null}</span>;
}
