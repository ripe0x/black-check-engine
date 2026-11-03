"use client";

import { useAccount } from "wagmi";
import { deployment } from "./deployment";
import { chainOf } from "./wagmi";

/** The deployment's network by name, for prompts ("Switch to Anvil"). */
export const chainName = chainOf(deployment.chainId).name;

/** False while a connected wallet is on any network but the deployment's: every action waits for a switch. */
export function useOnChain() {
  const { address, chainId } = useAccount();
  return !address || chainId === deployment.chainId;
}

/**
 * The chain's time for the next transaction, for deadlines: the pending block's timestamp (a node that mines only
 * on demand, like a local fork, has a stale latest block; its pending block carries its own current time), else the
 * latest block's. Never this browser's clock, which a fork's can differ from by weeks.
 */
export async function chainNow(client: { getBlock: (a?: { blockTag: "pending" }) => Promise<{ timestamp: bigint }> }) {
  const latest = (await client.getBlock()).timestamp;
  const pending = await client.getBlock({ blockTag: "pending" }).then((b) => b.timestamp, () => latest);
  return pending > latest ? pending : latest;
}

/** The deployment chain's block explorer, if it has one (a local chain has none). */
const explorerBase = chainOf(deployment.chainId).blockExplorers?.default.url;
export const txUrl = (hash: string) => (explorerBase ? `${explorerBase}/tx/${hash}` : undefined);
export const addressUrl = (a: string) => (explorerBase ? `${explorerBase}/address/${a}` : undefined);
export const nftUrl = (nft: string, id: bigint | string) => (explorerBase ? `${explorerBase}/nft/${nft}/${id}` : undefined);
