"use client";

import { useReadContract } from "wagmi";
import { deployment } from "./deployment";
import { lensAbi } from "./abi.generated";

const on = { enabled: deployment.deployed, refetchInterval: 15_000 };

export const useFunding = () =>
  useReadContract({ address: deployment.lens, abi: lensAbi, functionName: "funding", args: [deployment.game], query: on });
export const useBooks = () =>
  useReadContract({ address: deployment.lens, abi: lensAbi, functionName: "books", args: [deployment.game], query: on });
export const useBuybacks = () =>
  useReadContract({ address: deployment.lens, abi: lensAbi, functionName: "buybacks", args: [deployment.game], query: on });
export const useQuote = () =>
  useReadContract({ address: deployment.lens, abi: lensAbi, functionName: "quote", args: [deployment.game], query: on });
export const usePrizes = () =>
  useReadContract({ address: deployment.lens, abi: lensAbi, functionName: "prizes", args: [deployment.game], query: on });
