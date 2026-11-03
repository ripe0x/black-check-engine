"use client";

import { useReadContract } from "wagmi";
import { deployment, collectionMeta } from "../lib/deployment";
import { hookAbi } from "../lib/abi.generated";
import { money, useMarket } from "../lib/market";
import { NotDeployed } from "../components/NotDeployed";
import { Swap } from "../components/Swap";
import { HowItWorks } from "../components/HowItWorks";

export default function Coin() {
  if (!deployment.deployed) return <NotDeployed />;
  return <Inner />;
}

function Inner() {
  const m = useMarket();
  const { data: poolId } = useReadContract({ address: deployment.hook, abi: hookAbi, functionName: "poolId" });
  return (
    <div className="trade">
      <div className="trade-head">
        <h1>{collectionMeta.ticker}</h1>
        <b>{money(m.priceEth, m.ethUsd)}</b>
        <span className="note">{money(m.capEth, m.ethUsd)} market cap · {money(m.volumeEth, m.ethUsd)} 24h volume</span>
      </div>
      <div className="trade-cols">
        <div className="trade-chart">
          {/* DexScreener lists the pool on Ethereum by its v4 pool id; on a fork or testnet there is nothing to show */}
          {deployment.chainId === 1 && poolId ? (
            <iframe title={`${collectionMeta.ticker} chart on DexScreener`} loading="lazy"
              src={`https://dexscreener.com/ethereum/${poolId}?embed=1&loadChartSettings=0&trades=0&tabs=0&info=0&chartLeftToolbar=0&chartTheme=dark&theme=dark&chartStyle=1&chartType=usd&interval=15`} />
          ) : <p className="note center">Chart appears once the pool trades on Ethereum.</p>}
        </div>
        <aside className="trade-side" aria-label={`Trade ${collectionMeta.ticker}`}>
          <Swap />
        </aside>
      </div>
      <HowItWorks />
    </div>
  );
}
