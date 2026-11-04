import { encodeAbiParameters, encodeFunctionData, encodePacked, parseAbi, zeroAddress, type Address, type Hex } from "viem";

// Trading the coin through Uniswap's own contracts on mainnet: the v4 Universal Router for the swap, the V4 Quoter for
// the price, Permit2 for a sell's token allowance. Both point at the same PoolManager the protocol's pool lives in. The
// hook charges every swap that is not the burner's the same fee, in ETH (buys: out of the ETH paid; sells: out of the
// ETH received), so the router is an ordinary public router. The hook refuses exact-output sells, so only exact-input
// swaps are built here.
export const UNIVERSAL_ROUTER: Address = "0x66a9893cc07d91d95644aedd05d03f95e1dba8af";
export const V4_QUOTER: Address = "0x52f0e24d1c21c8a0cb1e5a5dd6198556bd9e1203";
export const PERMIT2: Address = "0x000000000022D473030F116dDEE9F6B43aC78BA3";

export type PoolKey = { currency0: Address; currency1: Address; fee: number; tickSpacing: number; hooks: Address };

/** The coin's pool, built from the bundled deployment record, never read over RPC: a lying RPC could name another
 *  token's pool and have a buyer pay for a counterfeit (audit final B-F5). Mirrors `ProtocolLiquidity.poolKey`: native
 *  ETH, the coin, no LP fee (the hook charges the fee), tick spacing 200, the hook. */
export const coinPoolKey = (token: Address, hook: Address): PoolKey =>
  ({ currency0: zeroAddress, currency1: token, fee: 0, tickSpacing: 200, hooks: hook });

const POOL_KEY = { type: "tuple", components: [
  { name: "currency0", type: "address" }, { name: "currency1", type: "address" }, { name: "fee", type: "uint24" },
  { name: "tickSpacing", type: "int24" }, { name: "hooks", type: "address" },
] } as const;

export const quoterAbi = [{
  type: "function", name: "quoteExactInputSingle", stateMutability: "nonpayable",
  inputs: [{ name: "params", type: "tuple", components: [
    { name: "poolKey", ...POOL_KEY }, { name: "zeroForOne", type: "bool" }, { name: "exactAmount", type: "uint128" }, { name: "hookData", type: "bytes" },
  ] }],
  outputs: [{ name: "amountOut", type: "uint256" }, { name: "gasEstimate", type: "uint256" }],
}] as const;

export const routerAbi = parseAbi(["function execute(bytes commands, bytes[] inputs, uint256 deadline) payable"]);
export const permit2Abi = parseAbi([
  "function allowance(address owner, address token, address spender) view returns (uint160 amount, uint48 expiration, uint48 nonce)",
  "function approve(address token, address spender, uint160 amount, uint48 expiration)",
]);

// Universal Router command and v4 router actions (Uniswap's Commands.sol, v4-periphery's Actions.sol)
const V4_SWAP = 0x10, SWAP_EXACT_IN_SINGLE = 0x06, SETTLE_ALL = 0x0c, TAKE_ALL = 0x0f;

/** Quoter arguments for selling `amountIn` of the input side (zeroForOne: ETH in, the coin out). */
export const quoteArgs = (key: PoolKey, zeroForOne: boolean, amountIn: bigint) =>
  [{ poolKey: key, zeroForOne, exactAmount: amountIn, hookData: "0x" as Hex }] as const;

/** The least output accepted: the quote less `slippageBps`. */
export const minOut = (quoted: bigint, slippageBps: bigint) => (quoted * (10_000n - slippageBps)) / 10_000n;

/**
 * One exact-input swap through the Universal Router: swap, pay the input (SETTLE_ALL, at most `amountIn`), take the
 * output (TAKE_ALL, at least `amountOutMin`, else the whole transaction reverts). A buy sends its ETH as value.
 */
export function swapTx(key: PoolKey, zeroForOne: boolean, amountIn: bigint, amountOutMin: bigint, deadline: bigint) {
  const [cin, cout] = zeroForOne ? [key.currency0, key.currency1] : [key.currency1, key.currency0];
  const actions = encodePacked(["uint8", "uint8", "uint8"], [SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL]);
  const swap = encodeAbiParameters(
    [{ type: "tuple", components: [
      { name: "poolKey", ...POOL_KEY }, { name: "zeroForOne", type: "bool" }, { name: "amountIn", type: "uint128" },
      { name: "amountOutMinimum", type: "uint128" }, { name: "hookData", type: "bytes" },
    ] }],
    [{ poolKey: key, zeroForOne, amountIn, amountOutMinimum: amountOutMin, hookData: "0x" }],
  );
  const settle = encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [cin, amountIn]);
  const take = encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [cout, amountOutMin]);
  const input = encodeAbiParameters([{ type: "bytes" }, { type: "bytes[]" }], [actions, [swap, settle, take]]);
  return {
    to: UNIVERSAL_ROUTER,
    data: encodeFunctionData({ abi: routerAbi, functionName: "execute", args: [encodePacked(["uint8"], [V4_SWAP]), [input], deadline] }),
    value: zeroForOne ? amountIn : 0n,
  };
}
