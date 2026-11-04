import { formatEther } from "viem";

const upTo2 = new Intl.NumberFormat("en-US", { maximumFractionDigits: 2 });
const twoSig = new Intl.NumberFormat("en-US", { maximumSignificantDigits: 2 });
/** A number as the site writes it (the owner's rule): at most two decimals, trailing zeros dropped (0.5, 1,234.57); a
 *  non-zero amount under 0.01 to its first two significant digits (0.0012, 0.00043), so it never reads as 0. */
export const fmt = (v: number) => (v !== 0 && Math.abs(v) < 0.01 ? twoSig : upTo2).format(v);
/** The same, for a small USD price: cents from $1, two significant digits below it. */
export const fmtSmall = (v: number) => twoSig.format(v);
const upTo3 = new Intl.NumberFormat("en-US", { maximumFractionDigits: 3 });
/** An ETH amount as the site writes it (the owner's rule): at most three decimals, trailing zeros dropped (0.5,
 *  0.019, 1,234.568); a non-zero amount under 0.001 to its first two significant digits (0.00043), so it never reads
 *  as 0. USD keeps `fmt`'s two decimals. */
export const fmtEth = (v: number) => (v !== 0 && Math.abs(v) < 0.001 ? twoSig : upTo3).format(v);
export const eth = (wei?: bigint) => (wei === undefined ? "–" : `${fmtEth(Number(formatEther(wei)))} ETH`);
export const num = (wei?: bigint, digits = 0) =>
  wei === undefined ? "–" : Number(formatEther(wei)).toLocaleString(undefined, { maximumFractionDigits: digits });

/** The same rule, rounded toward the side that never misleads: what a user pays up (the transaction may charge up to
 *  the exact amount, never more than shown), what they receive down (never shown above what is given or guaranteed).
 *  Exact integer arithmetic on the wei amount, so the direction never depends on the browser's `Intl` support. */
const grouped = new Intl.NumberFormat("en-US");
const exact = (wei: bigint, decimals: number, up: boolean): string => {
  const w = wei < 0n ? -wei : wei;
  const unit = 10n ** BigInt(18 - decimals);
  const q = w / unit + (up && w % unit !== 0n ? 1n : 0n);
  const s = q.toString().padStart(decimals + 1, "0");
  const int = s.slice(0, s.length - decimals);
  const frac = s.slice(s.length - decimals).replace(/0+$/, "");
  return grouped.format(BigInt(int)) + (frac ? `.${frac}` : "");
};
/** An ETH amount at the site's precision (three decimals; under 0.001 ETH its first two significant digits). */
const rounded = (up: boolean) => (wei: bigint) => {
  const w = wei < 0n ? -wei : wei;
  const decimals = w !== 0n && w < 10n ** 15n ? Math.min(18, 20 - w.toString().length) : 3;
  return exact(w, decimals, up);
};
const up = rounded(true);
const down = rounded(false);
export const ethUp = (wei?: bigint) => (wei === undefined ? "–" : `${up(wei)} ETH`);
export const ethDown = (wei?: bigint) => (wei === undefined ? "–" : `${down(wei)} ETH`);
/** An unsigned amount without the unit, rounded up (paid) or down (received). */
export const amtUp = (wei: bigint) => up(wei);
export const amtDown = (wei: bigint) => down(wei);
/** A coin amount received, rounded down to `digits` decimals. */
export const numDown = (wei?: bigint, digits = 0) => (wei === undefined ? "–" : exact(wei, digits, false));
/** A 1e18-scaled probability as "1 in N" and a percentage. */
export const odds = (p?: bigint) => {
  if (!p || p === 0n) return "–";
  const f = Number(p) / 1e18;
  return f >= 0.01 ? `${(f * 100).toFixed(2)}%` : `1 in ${Math.round(1 / f).toLocaleString()}`;
};
/** Gas as millions, e.g. "1.40M". */
export const mgas = (g?: bigint) => (g === undefined ? "–" : `${(Number(g) / 1e6).toFixed(2)}M`);
export const short = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "–");
export const bps = (b?: bigint) => (b === undefined ? "–" : `${(Number(b) / 100).toFixed(2)}%`);
