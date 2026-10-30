import { formatEther } from "viem";

export const eth = (wei?: bigint, digits = 4) =>
  wei === undefined ? "–" : `${Number(formatEther(wei)).toLocaleString(undefined, { maximumFractionDigits: digits })} ETH`;

export const coin = (wei?: bigint, digits = 0) =>
  wei === undefined ? "–" : Number(formatEther(wei)).toLocaleString(undefined, { maximumFractionDigits: digits });

// A probability in [0,1] as a percentage, or "1 in N" when small. Keeps rare odds honest instead of showing "0.00%".
export const odds = (p?: number) => {
  if (p === undefined || !isFinite(p) || p <= 0) return "–";
  return p >= 0.01 ? `${(p * 100).toFixed(2)}%` : `1 in ${Math.round(1 / p).toLocaleString()}`;
};

export const short = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "–");
export const gwei = (wei?: bigint) => (wei === undefined ? "–" : `${(Number(wei) / 1e9).toFixed(2)} gwei`);
