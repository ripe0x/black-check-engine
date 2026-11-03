// Fork check for app/lib/swap.ts: runs the site's own swap builders against a local anvil fork with a deployment
// (deployments/anvil.json, e.g. from script/rehearse-anvil.sh with KEEP_ANVIL=1). Local only: it impersonates a trader.
//
//   RPC_URL=http://127.0.0.1:8546 node --experimental-strip-types scripts/swap-fork-check.ts
import { readFileSync } from "node:fs";
import { createPublicClient, createWalletClient, http, maxUint256, parseAbi, parseEther, type Address } from "viem";
import { foundry } from "viem/chains";
import { PERMIT2, UNIVERSAL_ROUTER, V4_QUOTER, minOut, permit2Abi, quoteArgs, quoterAbi, swapTx, type PoolKey } from "../app/lib/swap.ts";

const rpc = process.env.RPC_URL ?? "http://127.0.0.1:8546";
const dep = JSON.parse(readFileSync(new URL("../../deployments/anvil.json", import.meta.url), "utf8"));
const chain = { ...foundry, id: Number(process.env.CHAIN_ID ?? 1) };
const pub = createPublicClient({ chain, transport: http(rpc) });
const trader: Address = "0x00000000000000000000000000000000000ba11a";
const wallet = createWalletClient({ chain, transport: http(rpc), account: trader });
const erc20 = parseAbi(["function balanceOf(address) view returns (uint256)", "function approve(address,uint256) returns (bool)"]);
const fees = parseAbi(["function tradingFees() view returns (uint256)"]);
const keyAbi = parseAbi(["function poolKey() view returns ((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks))"]);
const feeAbi = parseAbi(["function currentFeeBps(bool) view returns (uint256)"]);
const assert = (ok: boolean, msg: string) => { if (!ok) { console.error("FAIL:", msg); process.exit(1); } console.log("ok:", msg); };

await pub.request({ method: "anvil_impersonateAccount" as never, params: [trader] as never });
await pub.request({ method: "anvil_setBalance" as never, params: [trader, "0x56BC75E2D63100000"] as never });
const key = (await pub.readContract({ address: dep.liquidity, abi: keyAbi, functionName: "poolKey" })) as PoolKey;
const quote = async (zeroForOne: boolean, amount: bigint) =>
  (await pub.simulateContract({ address: V4_QUOTER, abi: quoterAbi, functionName: "quoteExactInputSingle", args: quoteArgs(key, zeroForOne, amount) })).result[0];
const send = async (tx: { to: Address; data: `0x${string}`; value: bigint }) =>
  pub.waitForTransactionReceipt({ hash: await wallet.sendTransaction({ ...tx, gas: 1_000_000n }) });
// a fork's clock can run well ahead of its last block (the rehearsal moves time forward), so the deadline is generous
await pub.request({ method: "evm_mine" as never, params: [] as never });
const deadline = (await pub.getBlock()).timestamp + 86_400n;

// buy 1 ETH of the coin
const ethIn = parseEther("1"), buyFee = await pub.readContract({ address: dep.hook, abi: feeAbi, functionName: "currentFeeBps", args: [true] });
const q = await quote(true, ethIn), fees0 = await pub.readContract({ address: dep.vault, abi: fees, functionName: "tradingFees" });
const coin0 = await pub.readContract({ address: key.currency1, abi: erc20, functionName: "balanceOf", args: [trader] });
const r1 = await send(swapTx(key, true, ethIn, minOut(q, 100n), deadline));
const coin1 = await pub.readContract({ address: key.currency1, abi: erc20, functionName: "balanceOf", args: [trader] });
const fees1 = await pub.readContract({ address: dep.vault, abi: fees, functionName: "tradingFees" });
assert(r1.status === "success", "buy executes");
assert(coin1 - coin0 === q, `buy receives exactly the quote (${q})`);
assert(fees1 - fees0 === (ethIn * buyFee) / 10_000n, `vault takes the ${buyFee} bps buy fee`);

// a minimum above the quote reverts the whole swap
const tight = await wallet.sendTransaction({ ...swapTx(key, true, ethIn, q + q / 20n, deadline), gas: 1_000_000n }).then(
  (h) => pub.waitForTransactionReceipt({ hash: h }).then((r) => r.status), () => "reverted");
assert(tight === "reverted", "buy with a minimum above the quote reverts");

// sell half back: approve Permit2 once, allow the router through Permit2, swap
const sellIn = coin1 / 2n;
await send({ to: key.currency1, data: (await import("viem")).encodeFunctionData({ abi: erc20, functionName: "approve", args: [PERMIT2, maxUint256] }), value: 0n });
await pub.waitForTransactionReceipt({ hash: await wallet.writeContract({ address: PERMIT2, abi: permit2Abi, functionName: "approve", args: [key.currency1, UNIVERSAL_ROUTER, sellIn, Number(deadline)] }) });
const qs = await quote(false, sellIn), eth0 = await pub.getBalance({ address: trader });
const r2 = await send(swapTx(key, false, sellIn, minOut(qs, 100n), deadline));
const eth1 = await pub.getBalance({ address: trader });
assert(r2.status === "success", "sell executes");
assert(eth1 - eth0 + r2.gasUsed * r2.effectiveGasPrice === qs, `sell receives exactly the quote (${qs})`);
console.log("swap fork check passed");
