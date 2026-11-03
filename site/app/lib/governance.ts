"use client";

import { useEffect, useState } from "react";
import { usePublicClient, useReadContract } from "wagmi";
import type { Abi, Address } from "viem";
import { deployment } from "./deployment";
import { adminAbi, burnerAbi, gameAbi, hookAbi, migrationAbi, poolOwnerAbi, vaultAbi } from "./abi.generated";

/// One owner (the Admin contract: two-step transfer, renounce) changes parameters directly, with immediate effect;
/// a migration and a change of trading-fee recipient run only 72 hours after they are proposed. The site lists every
/// such change from the contracts' own events, so players see what changed and when.
const adminEvents: Record<string, string> = {
  SettingsSet: "Changed reserve and admission settings",
  Paused: "Paused or resumed new draws",
  PatternSet: "Changed the prize board's pattern (applies to each row the next time it is listed)",
  PricingSet: "Changed the markup and the keeper allowance rate",
  BoardParamsSet: "Changed the replacement batch and the prizes listed per call",
  KeeperParamsSet: "Changed keeper pay (gas price cap, overhead, flat fee, delay after players' upkeep)",
  ParamsSet: "Changed the buyback pace and price limits",
  ListingParamsSet: "Changed how Apes open, decay and fit the board (exposure target)",
  MaxInFlightSet: "Changed the in-flight request limit",
  FeesSet: "Changed the trading fee",
  FeeRecipientSet: "Trading fees now go to a new recipient",
  BidParamsSet: "Changed the live bid (threshold share, sweep sizes, cooldown, ceiling, cap)",
  ThresholdSet: "Corrected the live bid's activation threshold",
  MilestoneBpsSet: "Changed the milestone buyback share",
  ProtectedSet: "Recorded the protocol's own NFT collections (deployment only; never swept)",
  Excluded: "Excluded or re-included a token from acquisition",
  RetireStarted: "The game stopped new draws for good (a migration or the sunset)",
  Proposed: "Proposed a migration (executable 72 hours later)",
  Executed: "Executed a migration",
  FeeRecipientProposed: "Proposed a new trading-fee recipient (executable 72 hours later)",
  FeeRecipientExecuted: "Executed a new trading-fee recipient",
  Sunset: "Ended the game into the sunset: Apes auctioned, every wei to coin buybacks",
  OwnershipTransferStarted: "Started an ownership transfer",
  OwnershipTransferred: "Transferred (or renounced) ownership",
};

export type AdminChange = { contract: string; event: string; label: string; args: string; block: bigint; tx: string };

const sources: [string, Address, Abi][] = [
  ["Game", deployment.game, gameAbi as Abi],
  ["Pool owner", deployment.poolOwner, poolOwnerAbi as Abi],
  ["Vault", deployment.vault, vaultAbi as Abi],
  ["Burner", deployment.burner, burnerAbi as Abi],
  ["Hook", deployment.hook, hookAbi as Abi],
  ["Migration", deployment.migration, migrationAbi as Abi],
  ["Admin", deployment.admin, adminAbi as Abi],
];

/// Every administrative change since deployment, newest first, decoded from the contracts' own events.
export function useAdminChanges(): AdminChange[] {
  const client = usePublicClient();
  const [changes, setChanges] = useState<AdminChange[]>([]);
  useEffect(() => {
    if (!client || !deployment.deployed) return;
    let live = true;
    (async () => {
      const out: AdminChange[] = [];
      for (const [name, address, abi] of sources) {
        const logs = await client.getContractEvents({ address, abi, fromBlock: BigInt(deployment.block ?? 0) });
        for (const l of logs as unknown as { eventName: string; args: unknown; blockNumber: bigint; transactionHash: string }[]) {
          const label = adminEvents[l.eventName];
          if (!label) continue;
          out.push({
            contract: name, event: l.eventName, label, block: l.blockNumber, tx: l.transactionHash,
            args: JSON.stringify(l.args ?? {}, (_, v) => (typeof v === "bigint" ? v.toString() : v)),
          });
        }
      }
      out.sort((a, b) => (a.block < b.block ? 1 : -1));
      if (live) setChanges(out);
    })().catch(() => {});
    return () => {
      live = false;
    };
  }, [client]);
  return changes;
}

export type MigrationState = {
  pending: Address; // proposed successor (zero: none)
  executableAt: number; // 0: nothing pending
  pendingFee: Address; // proposed trading-fee recipient (zero: none)
  feeExecutableAt: number; // 0: nothing pending
  successor: Address; // where V1's NFTs and capital go once started
  started: boolean;
  owner: Address;
};

const ZERO = "0x0000000000000000000000000000000000000000";

/// The MigrationAuthority's state: a pending proposal and when it can execute; whether V1 has stopped.
export function useMigration(): MigrationState | undefined {
  const q = { query: { refetchInterval: 30_000, enabled: deployment.deployed } };
  const a = { address: deployment.migration, abi: migrationAbi } as const;
  const { data: pending } = useReadContract({ ...a, functionName: "pending", ...q });
  const { data: executableAt } = useReadContract({ ...a, functionName: "executableAt", ...q });
  const { data: successor } = useReadContract({ ...a, functionName: "successor", ...q });
  const { data: pendingFee } = useReadContract({ ...a, functionName: "pendingFeeRecipient", ...q });
  const { data: feeExecutableAt } = useReadContract({ ...a, functionName: "feeExecutableAt", ...q });
  const { data: started } = useReadContract({ ...a, functionName: "started", ...q });
  const { data: owner } = useReadContract({ address: deployment.admin, abi: adminAbi, functionName: "owner", ...q });
  if (
    pending === undefined || executableAt === undefined || successor === undefined || started === undefined
    || owner === undefined || pendingFee === undefined || feeExecutableAt === undefined
  ) return undefined;
  return {
    pending: pending as Address, executableAt: Number(executableAt), successor: successor as Address,
    pendingFee: pendingFee as Address, feeExecutableAt: Number(feeExecutableAt),
    started: started as boolean, owner: owner as Address,
  };
}

export function hasPendingMigration(m?: MigrationState): boolean {
  return !!m && m.pending !== ZERO;
}

export function hasPendingFeeRecipient(m?: MigrationState): boolean {
  return !!m && m.pendingFee !== ZERO;
}
