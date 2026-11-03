"use client";

import { useQuery } from "@tanstack/react-query";
import { parseAbi, parseAbiItem, type Address } from "viem";
import { usePublicClient, useReadContract } from "wagmi";
import { deployment } from "./deployment";
import { poolOwnerAbi } from "./abi.generated";

const transfer = parseAbiItem("event Transfer(address indexed from, address indexed to, uint256 indexed id)");
const nftAbi = parseAbi(["function ownerOf(uint256) view returns (address)", "function valueOf(uint256) view returns (uint256)"]);

/** The query key of `useHeldValue`: invalidate it to read again at once (the draw flow does when prizes land). */
export const HELD_KEY = "held-shapes";

/** What the Shapes and Packs `owner` holds redeem for, in wei. Neither contract lists an owner's tokens, so this
 *  follows transfers to the owner since the game was deployed and keeps those still owned (Shapes held from before
 *  are not counted). Read again when `key` changes, when HELD_KEY is invalidated, and every 30 seconds. */
export function useHeldValue(owner?: Address, key?: bigint) {
  const client = usePublicClient();
  const { data: shapes } = useReadContract({ address: deployment.poolOwner, abi: poolOwnerAbi, functionName: "shapes", query: { enabled: deployment.deployed } });
  const { data } = useQuery({
    queryKey: [HELD_KEY, deployment.chainId, owner, shapes, key?.toString()],
    enabled: !!client && !!owner && !!shapes,
    refetchInterval: 30_000,
    queryFn: async () => {
      const me = owner!.toLowerCase();
      const fromBlock = BigInt(deployment.block ?? 0);
      const found = new Map<string, [Address, bigint]>();
      for (const address of [shapes!, deployment.packs]) {
        const logs = await client!.getLogs({ address, event: transfer, args: { to: owner }, fromBlock });
        for (const l of logs) found.set(`${address}-${l.args.id}`, [address, l.args.id!]);
      }
      const values = await Promise.all([...found.values()].map(async ([address, id]) => {
        const o = await client!.readContract({ address, abi: nftAbi, functionName: "ownerOf", args: [id] }).catch(() => undefined);
        if (o?.toLowerCase() !== me) return 0n; // since redeemed (burned) or sent on
        return client!.readContract({ address, abi: nftAbi, functionName: "valueOf", args: [id] }).catch(() => 0n);
      }));
      return values.reduce((t, v) => t + v, 0n).toString(); // a string: query data is kept serialisable
    },
  });
  return data === undefined ? undefined : BigInt(data);
}
