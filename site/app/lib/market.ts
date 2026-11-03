"use client";
import { fmt, fmtEth } from "./format";

import { useEffect, useState } from "react";
import { encodeAbiParameters, keccak256, parseAbi, parseAbiItem, type Hex } from "viem";
import { usePublicClient, useReadContract } from "wagmi";
import { deployment } from "./deployment";
import { hookAbi, tokenAbi } from "./abi.generated";

// Market figures for the coin, all read from the chain: the price from the pool's own slot0 in the v4 PoolManager,
// the ETH/USD rate from Chainlink's feed, 24h volume from the PoolManager's Swap events for this pool.
const POOL_MANAGER = "0x000000000004444c5dc75cB358380D2e3dE08A90" as const;
const ETH_USD = "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419" as const; // Chainlink ETH / USD, 8 decimals
const POOLS_SLOT = 6n; // PoolManager's `_pools` mapping (v4-core StateLibrary.POOLS_SLOT)
const DAY_BLOCKS = 7200n; // about 24 hours of 12-second blocks
const pmAbi = parseAbi(["function extsload(bytes32 slot) view returns (bytes32)"]);
const feedAbi = parseAbi(["function latestRoundData() view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80)"]);
const swapEvent = parseAbiItem("event Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)");

export type Market = { priceEth?: number; ethUsd?: number; capEth?: number; volumeEth?: number };

// ETH is currency0, so a sqrtPriceX96 is the square root of coins per ETH: the coin's ETH price is its inverse square
const priceOf = (sqrtPriceX96: bigint) => {
  const r = Number(sqrtPriceX96) / 2 ** 96;
  return r > 0 ? 1 / (r * r) : undefined;
};

export function useMarket(): Market {
  const client = usePublicClient();
  const on = { enabled: deployment.deployed, refetchInterval: 30_000 };
  const { data: poolId } = useReadContract({ address: deployment.hook, abi: hookAbi, functionName: "poolId", query: { enabled: deployment.deployed } });
  const slot = poolId ? keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [poolId as Hex, POOLS_SLOT])) : undefined;
  const { data: slot0 } = useReadContract({ address: POOL_MANAGER, abi: pmAbi, functionName: "extsload", args: slot ? [slot] : undefined, query: { ...on, enabled: !!slot } });
  const { data: feed } = useReadContract({ address: ETH_USD, abi: feedAbi, functionName: "latestRoundData", query: on });
  const { data: supply } = useReadContract({ address: deployment.token, abi: tokenAbi, functionName: "totalSupply", query: on });
  const [volumeEth, setVolume] = useState<number>();

  useEffect(() => {
    if (!client || !poolId) return;
    let live = true;
    const load = async () => {
      const head = await client.getBlockNumber();
      const logs = await client.getLogs({ address: POOL_MANAGER, event: swapEvent, args: { id: poolId as Hex }, fromBlock: head > DAY_BLOCKS ? head - DAY_BLOCKS : 0n });
      // amount0 is the pool's ETH side of each swap, either sign
      const wei = logs.reduce((a, l) => a + (l.args.amount0! < 0n ? -l.args.amount0! : l.args.amount0!), 0n);
      if (live) setVolume(Number(wei) / 1e18);
    };
    load().catch(() => {});
    const t = setInterval(() => load().catch(() => {}), 60_000);
    return () => { live = false; clearInterval(t); };
  }, [client, poolId]);

  // slot0's low 160 bits are sqrtPriceX96
  const priceEth = slot0 ? priceOf(BigInt(slot0) & ((1n << 160n) - 1n)) : undefined;
  const ethUsd = feed ? Number(feed[1]) / 1e8 : undefined;
  return { priceEth, ethUsd, capEth: priceEth !== undefined && supply ? (priceEth * Number(supply)) / 1e18 : undefined, volumeEth };
}

/** Compact money: USD when the rate is known, else ETH. */
export function money(eth: number | undefined, ethUsd: number | undefined) {
  if (eth === undefined) return "–";
  if (ethUsd === undefined) return `${fmtEth(eth)} ETH`;
  const usd = eth * ethUsd;
  if (usd >= 1000) return `$${Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 2 }).format(usd)}`;
  if (usd >= 1) return `$${usd.toFixed(2)}`;
  return `$${fmt(usd)}`; // under $1: cents, or two significant digits under a cent
}

