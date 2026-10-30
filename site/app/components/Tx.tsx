"use client";

import { useWaitForTransactionReceipt } from "wagmi";
import type { Hash } from "viem";

export function TxStatus({ hash, error }: { hash?: Hash; error?: Error | null }) {
  const { isLoading, isSuccess } = useWaitForTransactionReceipt({ hash });
  if (error) return <p className="err" role="alert">{(error as { shortMessage?: string }).shortMessage ?? error.message}</p>;
  if (!hash) return null;
  return (
    <p className="note" role="status">
      {isLoading ? "Waiting for confirmation…" : isSuccess ? "Confirmed." : "Sent."} {hash.slice(0, 12)}…
    </p>
  );
}
