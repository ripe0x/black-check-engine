"use client";

import type { Address } from "viem";
import { useReadContract } from "wagmi";
import { config, deployed } from "../lib/config";
import { engineAbi } from "../lib/abi.generated";
import { useSystem } from "../lib/chain";
import { NotDeployed } from "../components/NotDeployed";

export default function TrustPage() {
  if (!deployed) return <NotDeployed />;
  return <Trust />;
}

// A stacked entry: label, a breaking address (or em dash), and a note. No wide table, so long hashes wrap instead of
// forcing a horizontal scroll on mobile.
function Entry({ label, value, hint }: { label: string; value?: string; hint?: string }) {
  return (
    <div className="entry">
      <div className="entry-label">{label}</div>
      {value ? (
        <a href={`${config.explorer}/address/${value}`} target="_blank" rel="noreferrer"><code>{value}</code></a>
      ) : (
        <div className="note">off-chain / not a single address</div>
      )}
      {hint ? <div className="note">{hint}</div> : null}
    </div>
  );
}

function Trust() {
  const { controller, pool, checks, coin, shapes } = useSystem();
  const e = { address: config.engine, abi: engineAbi } as const;
  const { data: timelock } = useReadContract({ ...e, functionName: "timelock" });
  const { data: operator } = useReadContract({ ...e, functionName: "operator" });
  const { data: guardian } = useReadContract({ ...e, functionName: "guardian" });
  const { data: halted } = useReadContract({ ...e, functionName: "halted", query: { refetchInterval: 10_000 } });

  return (
    <>
      <h1>Trust: who controls what</h1>
      <p><span className={halted ? "pill" : "pill live"}>{halted === undefined ? "reading…" : halted ? "Purchases HALTED" : "Purchases open"}</span></p>

      <div className="card">
        <h2>Contracts</h2>
        <Entry label="Engine (UUPS proxy)" value={config.engine} hint="custody of Checks, Shapes, ETH; upgradeable only by the timelock" />
        <Entry label="FWA controller" value={controller} hint="permanent, immutable owner of one FWA pool; engine-only" />
        <Entry label="FWA pool" value={pool} hint="holds listed NFTs and player draw entitlements" />
        <Entry label="Checks Originals" value={checks} hint="canonical Checks contract (external, trusted)" />
        <Entry label="Coin" value={coin} hint="fixed-supply ERC20; placeholder name" />
        <Entry label="Shapes" value={shapes} hint="ETH-backed prizes (external)" />
      </div>

      <div className="card">
        <h2>Roles</h2>
        <Entry label="Timelock" value={timelock as Address | undefined} hint="upgrades the engine, approves a new controller, sets params/roles — only after a council proposal and a 7-day delay" />
        <Entry label="Council" hint="the timelock's sole proposer (a Safe multisig, 3 of 5 tentative). Independence is an off-chain fact the contracts cannot verify." />
        <Entry label="Guardian" value={guardian as Address | undefined} hint="cancels scheduled operations; halts and resumes new draws. Cannot upgrade or move assets." />
        <Entry label="Operator (owner)" value={operator as Address | undefined} hint="halt new draws only. Cannot resume a guardian halt, upgrade, move assets or set prices." />
        <Entry label="Anyone (keepers)" hint="list, reprice, compose, collect, migrate, settle. Cannot choose recipients, prices or credit survival." />
      </div>

      <div className="card warn">
        <h2>Residual trust, stated plainly</h2>
        <ol>
          <li>A council majority, after 7 public days and without a guardian cancel, can upgrade the engine to anything,
            including a drain. A timelock and multisig distribute and delay that power; they do not remove it.</li>
          <li>Approving a new controller hands it every NFT the engine lists there. The council&apos;s review of that
            controller&apos;s code is the migration&apos;s security boundary.</li>
          <li>Council independence is an off-chain fact (who holds the keys). The contracts cannot verify it.</li>
          <li>FWA&apos;s code and its factory owner are trusted for listed inventory and player funds.</li>
          <li>Canonical Checks is trusted for composition and artwork.</li>
        </ol>
        <p className="note">Source: docs/THREAT_MODEL.md. This build is unaudited and the protocol is not deployed.</p>
      </div>
    </>
  );
}
