"use client";

import { useEffect, useState } from "react";
import { parseAbi, type Abi, type Address } from "viem";
import { usePublicClient, useReadContract } from "wagmi";
import { config, deployed } from "./config";
import { engineAbi } from "./abi.generated";

// Minimal ABIs for the external contracts we only touch for their own getters. getCheck's full struct lets viem decode
// the tier (stored.divisorIndex) and isRevealed; svg(tokenId) returns on-chain SVG markup.
export const checksAbi = [
  {
    type: "function",
    name: "getCheck",
    stateMutability: "view",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [
      {
        name: "check",
        type: "tuple",
        components: [
          {
            name: "stored",
            type: "tuple",
            components: [
              { name: "composites", type: "uint16[6]" },
              { name: "colorBands", type: "uint8[5]" },
              { name: "gradients", type: "uint8[5]" },
              { name: "divisorIndex", type: "uint8" },
              { name: "epoch", type: "uint32" },
              { name: "seed", type: "uint16" },
              { name: "day", type: "uint24" },
            ],
          },
          { name: "isRevealed", type: "bool" },
          { name: "seed", type: "uint256" },
          { name: "checksCount", type: "uint8" },
          { name: "hasManyChecks", type: "bool" },
          { name: "composite", type: "uint16" },
          { name: "isRoot", type: "bool" },
          { name: "colorBand", type: "uint8" },
          { name: "gradient", type: "uint8" },
          { name: "direction", type: "uint8" },
          { name: "speed", type: "uint8" },
        ],
      },
    ],
  },
  { type: "function", name: "svg", stateMutability: "view", inputs: [{ name: "tokenId", type: "uint256" }], outputs: [{ type: "string" }] },
  { type: "function", name: "ownerOf", stateMutability: "view", inputs: [{ name: "tokenId", type: "uint256" }], outputs: [{ type: "address" }] },
  { type: "function", name: "isApprovedForAll", stateMutability: "view", inputs: [{ type: "address" }, { type: "address" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "setApprovalForAll", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "bool" }], outputs: [] },
] as const satisfies Abi;

export const coinAbi = parseAbi([
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function symbol() view returns (string)",
  "function approve(address spender, uint256 amount) returns (bool)",
]);

export const controllerAbi = parseAbi([
  "function pool() view returns (address)",
  "function isListed(uint256 listingId) view returns (bool)",
  "function survived(uint256 listingId) view returns (uint256)",
  "function unsettled() view returns (uint256)",
]);

const poll = { enabled: deployed, refetchInterval: 12_000 };

/// The core addresses, all read from the engine proxy (the only configured address). Pool comes from the controller.
export function useSystem() {
  const e = { address: config.engine, abi: engineAbi, query: poll } as const;
  const { data: controller } = useReadContract({ ...e, functionName: "controller" });
  const { data: checks } = useReadContract({ ...e, functionName: "checks" });
  const { data: coin } = useReadContract({ ...e, functionName: "coin" });
  const { data: shapes } = useReadContract({ ...e, functionName: "shapes" });
  const { data: pool } = useReadContract({
    address: controller as Address | undefined,
    abi: controllerAbi,
    functionName: "pool",
    query: { enabled: deployed && !!controller },
  });
  return {
    controller: controller as Address | undefined,
    pool: pool as Address | undefined,
    checks: checks as Address | undefined,
    coin: coin as Address | undefined,
    shapes: shapes as Address | undefined,
  };
}

export type ListedRecord = { collection: Address; tokenId: bigint; listingId: bigint };

/// Every NFT the engine has ever listed, from its own `Listed` events (checks and shapes). Pages read each listing's
/// live state (still active? won? in custody?) from the pool and engine; this just enumerates candidates trustlessly.
export function useListedEvents() {
  const client = usePublicClient();
  const [records, setRecords] = useState<ListedRecord[]>([]);
  useEffect(() => {
    if (!client || !deployed) return;
    let live = true;
    (async () => {
      const logs = await client.getContractEvents({
        address: config.engine,
        abi: engineAbi,
        eventName: "Listed",
        fromBlock: config.deployBlock,
      });
      const seen = new Map<string, ListedRecord>();
      for (const l of logs) {
        const a = l.args as { collection?: Address; tokenId?: bigint; listingId?: bigint };
        if (a.collection === undefined || a.tokenId === undefined || a.listingId === undefined) continue;
        seen.set(`${a.collection}-${a.tokenId}`, { collection: a.collection, tokenId: a.tokenId, listingId: a.listingId });
      }
      if (live) setRecords([...seen.values()]);
    })().catch(() => {});
    return () => {
      live = false;
    };
  }, [client]);
  return records;
}

/// On-chain SVG of a Check as a data URI (no IPFS, no gateway). Empty until loaded.
export function useCheckSvg(checks?: Address, tokenId?: bigint) {
  const { data } = useReadContract({
    address: checks,
    abi: checksAbi,
    functionName: "svg",
    args: tokenId === undefined ? undefined : [tokenId],
    query: { enabled: deployed && !!checks && tokenId !== undefined },
  });
  if (!data) return "";
  return `data:image/svg+xml;utf8,${encodeURIComponent(data as string)}`;
}
