"use client";

import { useState } from "react";
import type { Address, Hash } from "viem";
import { useAccount, useReadContract, useWriteContract } from "wagmi";
import { config, deployed, tierName } from "../lib/config";
import { engineAbi } from "../lib/abi.generated";
import { checksAbi, coinAbi, useCheckSvg, useSystem } from "../lib/chain";
import { coin as fmtCoin, eth } from "../lib/format";
import { NotDeployed } from "../components/NotDeployed";
import { TxStatus } from "../components/Tx";

const ZERO = "0x0000000000000000000000000000000000000000" as const;

export default function CollectPage() {
  if (!deployed) return <NotDeployed />;
  return <Collect />;
}

function Collect() {
  const { data: halted } = useReadContract({ address: config.engine, abi: engineAbi, functionName: "halted", query: { refetchInterval: 12_000 } });
  const [id, setId] = useState("");
  return (
    <>
      <h1>Collect: buy a Check outright</h1>
      <div className="card warn">
        <b>Buying is not winning.</b> A buyout takes a specific Check out of the game at a published price. It is the
        opposite of a draw: no chance, no odds, you choose the token. An ETH buyout pays the treasury; a coin buyout
        burns your coin and removes the Check from inventory forever. A Check stays winnable by draw until a buyout
        actually completes, and a buyout reverts if a draw is mid-flight.
      </div>
      {halted ? <p className="err">Buyouts are closed while the game is halted.</p> : null}
      <div className="card">
        <label htmlFor="tid">Check token ID</label>
        <input id="tid" inputMode="numeric" placeholder="e.g. 1234" value={id} onChange={(e) => setId(e.target.value.replace(/\D/g, ""))} />
      </div>
      {id ? <BuyPanel tokenId={BigInt(id)} halted={!!halted} /> : null}
    </>
  );
}

function BuyPanel({ tokenId, halted }: { tokenId: bigint; halted: boolean }) {
  const { address } = useAccount();
  const { checks, coin: coinAddr } = useSystem();
  const img = useCheckSvg(checks, tokenId);
  const { writeContract, data: hash, error, isPending } = useWriteContract();
  const { data: info } = useReadContract({ address: checks, abi: checksAbi, functionName: "getCheck", args: [tokenId], query: { enabled: !!checks } });
  const { data: owner } = useReadContract({ address: checks, abi: checksAbi, functionName: "ownerOf", args: [tokenId], query: { enabled: !!checks } });
  const tier = info ? Number((info as { stored: { divisorIndex: number } }).stored.divisorIndex) : undefined;
  const { data: ethP } = useReadContract({ address: config.engine, abi: engineAbi, functionName: "ethPrice", args: tier === undefined ? undefined : [tier], query: { enabled: tier !== undefined } });
  const { data: coinP } = useReadContract({ address: config.engine, abi: engineAbi, functionName: "coinPrice", args: tier === undefined ? undefined : [BigInt(tier)], query: { enabled: tier !== undefined } });
  const { data: allowance } = useReadContract({ address: coinAddr, abi: coinAbi, functionName: "allowance", args: [address ?? ZERO, config.engine], query: { enabled: !!coinAddr && !!address, refetchInterval: 10_000 } });

  const ethPrice = ethP as bigint | undefined;
  const coinPrice = coinP as bigint | undefined;
  const needsApprove = coinPrice !== undefined && coinPrice > 0n && (allowance === undefined || allowance < coinPrice);

  return (
    <div className="card">
      <div className="row" style={{ alignItems: "flex-start" }}>
        {img ? <img src={img} alt={`Check #${tokenId}`} width={88} height={88} style={{ borderRadius: 8 }} /> : null}
        <div>
          <div><b>Check #{tokenId.toString()}</b> · tier {tier === undefined ? "…" : tierName(tier)}</div>
          <div className="note">Owner: {owner ? (owner as string) : "…"}</div>
        </div>
      </div>
      <div className="stats" style={{ marginTop: 12 }}>
        <div className="stat"><div className="stat-label">ETH buyout</div><div className="stat-value">{ethPrice === undefined ? "…" : ethPrice === 0n ? "n/a" : eth(ethPrice, 3)}</div><div className="stat-hint">schedule × (1 + markup), paid to treasury</div></div>
        <div className="stat"><div className="stat-label">Coin buyout</div><div className="stat-value">{coinPrice === undefined ? "…" : coinPrice === 0n ? "disabled" : `${fmtCoin(coinPrice)} ${config.coinSymbol}`}</div><div className="stat-hint">burned; removes the Check forever</div></div>
      </div>
      <div className="row" style={{ marginTop: 12 }}>
        <button className="btn-filled" disabled={!address || halted || !ethPrice || ethPrice === 0n || isPending}
          onClick={() => ethPrice && writeContract({ address: config.engine, abi: engineAbi, functionName: "buyWithEth", args: [tokenId], value: ethPrice })}>
          Buy with ETH
        </button>
        {coinPrice !== undefined && coinPrice > 0n ? (
          needsApprove ? (
            <button className="btn-outline" disabled={!address || !coinAddr} onClick={() => writeContract({ address: coinAddr!, abi: coinAbi, functionName: "approve", args: [config.engine, coinPrice] })}>
              Approve {fmtCoin(coinPrice)} {config.coinSymbol}
            </button>
          ) : (
            <button className="btn-outline" disabled={!address || halted || isPending}
              onClick={() => writeContract({ address: config.engine, abi: engineAbi, functionName: "buyWithCoin", args: [tokenId] })}>
              Buy by burning coin
            </button>
          )
        ) : null}
      </div>
      <TxStatus hash={hash as Hash | undefined} error={error} />
    </div>
  );
}
