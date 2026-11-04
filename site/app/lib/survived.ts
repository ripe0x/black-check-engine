"use client";

import { useEffect, useRef, useState } from "react";
import { parseAbiItem } from "viem";
import { usePublicClient, useReadContract } from "wagmi";
import { deployment } from "./deployment";
import { gameAbi } from "./abi.generated";

const listed = parseAbiItem("event CollectionListed(uint256 indexed listingId, uint256 indexed tokenId, uint256 notional)");

/**
 * Pulls each Ape has survived: the game's `pullsFulfilled` now, less the same counter at the block its listing entered
 * the draw (the pool owner's CollectionListed). Nothing on chain counts this per Ape, so it needs a node that serves
 * past state; where that read fails the Ape is simply left out.
 */
export function useSurvived(listingIds: bigint[]) {
  const client = usePublicClient();
  const { data: now } = useReadContract({ address: deployment.game, abi: gameAbi, functionName: "pullsFulfilled", query: { enabled: deployment.deployed, refetchInterval: 15_000 } });
  const at = useRef(new Map<string, bigint>()); // listingId -> pullsFulfilled when it was listed; never changes
  const [, bump] = useState(0);
  const key = listingIds.map(String).join(",");

  useEffect(() => {
    const todo = listingIds.filter((id) => !at.current.has(id.toString()));
    if (!client || todo.length === 0) return;
    let live = true;
    (async () => {
      const logs = await client.getLogs({ address: deployment.poolOwner, event: listed, args: { listingId: todo }, fromBlock: BigInt(deployment.block ?? 0) });
      for (const l of logs) {
        const n = await client.readContract({ address: deployment.game, abi: gameAbi, functionName: "pullsFulfilled", blockNumber: l.blockNumber! }).catch(() => undefined);
        if (n !== undefined) at.current.set(l.args.listingId!.toString(), n);
      }
      if (live) bump((x) => x + 1);
    })().catch(() => {});
    return () => { live = false; };
  }, [client, key]);

  return (listingId: bigint) => {
    const a = at.current.get(listingId.toString());
    return a !== undefined && now !== undefined ? Number(now - a) : undefined;
  };
}
