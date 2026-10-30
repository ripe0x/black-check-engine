"use client";

import { useMemo } from "react";
import Link from "next/link";
import type { Address } from "viem";
import { useReadContract, useReadContracts } from "wagmi";
import { config, deployed, tierName } from "../lib/config";
import { engineAbi } from "../lib/abi.generated";
import { checksAbi, controllerAbi, useListedEvents, useSystem } from "../lib/chain";
import { coin, eth } from "../lib/format";
import { NotDeployed } from "../components/NotDeployed";
import { Stat } from "../components/Stat";

export default function ChecksPage() {
  if (!deployed) return <NotDeployed />;
  return <Checks />;
}

function Checks() {
  const { checks, controller, pool } = useSystem();
  const records = useListedEvents();
  const tokens = useMemo(
    () => (checks ? records.filter((r) => r.collection.toLowerCase() === checks.toLowerCase()).map((r) => ({ tokenId: r.tokenId, listingId: r.listingId })) : []),
    [records, checks],
  );
  const { data: halted } = useReadContract({ address: config.engine, abi: engineAbi, functionName: "halted", query: { refetchInterval: 12_000 } });

  return (
    <>
      <h1>Checks held or in the draw</h1>
      <p className="note">Every Check the protocol holds in custody or has listed in the FWA pool, with its canonical
        tier, on-chain art, draws survived at this tier, current notional, whether it can be composed, and its buyout
        prices. Survival is derived from FWA&apos;s own draw count; a Check must pass its tier threshold to compose.
        Checks won or bought leave the protocol and drop off this list.</p>
      <div className="stats">
        <Stat label="Checks tracked" value={tokens.length} />
        <Stat label="New purchases" value={halted === undefined ? "–" : halted ? "halted" : "open"} hint="buyouts require the game not halted" />
      </div>
      {tokens.length === 0 ? (
        <div className="card">No Checks have been listed yet from this deployment.</div>
      ) : (
        <div className="scroll">
          <table>
            <thead>
              <tr><th>Check</th><th>Tier</th><th>State</th><th>Survived</th><th>Notional</th><th>Compose</th><th>ETH buyout</th><th>Coin buyout</th></tr>
            </thead>
            <tbody>
              {tokens.map((t) => <CheckRow key={t.tokenId.toString()} tokenId={t.tokenId} listingId={t.listingId} checks={checks} controller={controller} pool={pool} />)}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}

function CheckRow({ tokenId, listingId, checks, controller, pool }: { tokenId: bigint; listingId: bigint; checks?: Address; controller?: Address; pool?: Address }) {
  const { data: owner } = useReadContract({ address: checks, abi: checksAbi, functionName: "ownerOf", args: [tokenId], query: { enabled: !!checks, refetchInterval: 15_000 } });
  const { data: info } = useReadContract({ address: checks, abi: checksAbi, functionName: "getCheck", args: [tokenId], query: { enabled: !!checks } });
  const { data: isListed } = useReadContract({ address: controller, abi: controllerAbi, functionName: "isListed", args: [listingId], query: { enabled: !!controller, refetchInterval: 12_000 } });

  const engine = { address: config.engine, abi: engineAbi } as const;
  const token = useReadContracts({
    contracts: [
      { ...engine, functionName: "survivedDraws", args: [tokenId] },
      { ...engine, functionName: "eligible", args: [tokenId] },
      { ...engine, functionName: "checkListing", args: [tokenId] },
    ],
    query: { refetchInterval: 12_000 },
  });
  const tier = info ? Number((info as { stored: { divisorIndex: number } }).stored.divisorIndex) : undefined;
  const prices = useReadContracts({
    contracts: tier === undefined ? [] : [
      { ...engine, functionName: "ethPrice", args: [tier] },
      { ...engine, functionName: "coinPrice", args: [BigInt(tier)] },
    ],
    query: { enabled: tier !== undefined },
  });

  // Checks no longer owned by the engine or the pool have left the protocol.
  const inSystem = owner !== undefined && (owner === config.engine || (!!pool && owner.toLowerCase() === pool.toLowerCase()) || (!!controller && owner.toLowerCase() === controller.toLowerCase()));
  if (owner !== undefined && !inSystem) return null;

  const survived = token.data?.[0]?.result as bigint | undefined;
  const eligible = token.data?.[1]?.result as boolean | undefined;
  const listing = token.data?.[2]?.result as readonly [Address, bigint, bigint] | undefined;
  const ethBuy = prices.data?.[0]?.result as bigint | undefined;
  const coinBuy = prices.data?.[1]?.result as bigint | undefined;
  const state = isListed ? "in the draw" : "in custody";

  return (
    <tr>
      <td>#{tokenId.toString()}</td>
      <td>{tier === undefined ? "…" : tierName(tier)}</td>
      <td><span className={isListed ? "pill live" : "pill"}>{state}</span></td>
      <td>{survived === undefined ? "…" : survived.toString()}</td>
      <td>{listing && listing[2] > 0n && isListed ? eth(listing[2], 3) : "–"}</td>
      <td>{eligible === undefined ? "…" : eligible ? <Link href="/compose/">eligible</Link> : "no"}</td>
      <td>{ethBuy === undefined ? "…" : ethBuy === 0n ? "n/a" : eth(ethBuy, 3)}</td>
      <td>{coinBuy === undefined ? "…" : coinBuy === 0n ? "disabled" : `${coin(coinBuy)} ${config.coinSymbol}`}</td>
    </tr>
  );
}
