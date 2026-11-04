"use client";

import { useEffect, useState } from "react";
import { Dome, type DomeBall } from "./Dome";
import BAKED from "../lib/promo-apes.json";

// How many balls each load, from the holdings baked into the site (scripts/promo-apes.mjs): Apes from ApeStrategy,
// live Shapes small and on black, as in the live dome. The dome sizes balls to the mix, so more means smaller.
const APES: [number, number] = [4, 14], SHAPES: [number, number] = [4, 24]; // inclusive ranges
const between = ([lo, hi]: [number, number]) => lo + Math.floor(Math.random() * (hi - lo + 1));

const pick = (ids: number[], n: number) => {
  const a = [...ids];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a.slice(0, n);
};

/** The promo: the dome and its balls, nothing else. Drag and throw the balls, tap the glass or press its button (or Space). */
export function Promo() {
  // a fresh random set, and a fresh number of each, on every load, picked after mount so the static HTML and the first render agree
  const [balls, setBalls] = useState<DomeBall[]>([]);
  useEffect(() => {
    setBalls([
      // Shapes first, so they settle at the bottom and the Apes sit on top
      ...pick(BAKED.shapes, between(SHAPES)).map((id, i) => ({ key: `s${id}`, i, tokenId: BigInt(id), small: true, src: `/promo/shape-${id}.svg` })),
      ...pick(BAKED.apes, between(APES)).map((id, i) => ({ key: `a${id}`, i, tokenId: BigInt(id), src: `/promo/${id}.jpg` })),
    ]);
  }, []);
  return (
    <div className="promo">
      <div className="promo-dome"><Dome balls={balls} /></div>
    </div>
  );
}
