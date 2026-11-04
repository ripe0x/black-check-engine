"use client";

import { useWaitForTransactionReceipt } from "wagmi";
import type { Hash } from "viem";

export function TxStatus({ hash, error }: { hash?: Hash; error?: Error | null }) {
  const { isLoading, isSuccess, isError } = useWaitForTransactionReceipt({ hash });
  if (error) return <p className="err">{(error as { shortMessage?: string }).shortMessage ?? error.message}</p>;
  if (!hash) return null;
  // a reverted transaction (or one whose receipt cannot be read) must never look pending
  if (isError) return <p className="err">Failed or not confirmed: check {hash.slice(0, 10)}… on Etherscan before trying again.</p>;
  return <p className="note">{isLoading ? "Waiting for confirmation…" : isSuccess ? "Confirmed." : "Sent."} {hash.slice(0, 10)}…</p>;
}
