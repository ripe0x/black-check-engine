// Local trading simulator: funds a local fork's vault the only way mainnet funds it, with trading fees. Traders buy
// and sell the coin through Uniswap's Universal Router (buys with ETH; sells through Permit2), exactly the calls the
// site builds (site/app/lib/swap.ts), so the hook's fee, the coin's transfer restriction and the opening curve all
// apply. Minute by minute through the opening curve, volume rising toward its end (traders wait for lower fees, as
// sim/launch.py expects); after it, steady trading hour by hour at the ordinary fee. Anvil only: it moves the fork's
// clock and funds its traders with anvil_setBalance, and refuses to run where anvil_nodeInfo does not answer.
//
// Environment: RPC_URL (http://127.0.0.1:8545), DEPLOYMENT (../../deployments/anvil.json),
//   UNTIL: "first-ape" (the vault holds the first Ape's threshold), "board" (it can fund the board, reserve and
//   opening keeper pay), "vault:<wei>" (the vault holds at least that), or "minutes:N" (N more simulated minutes);
//   default "minutes:64".
//   OPENING_ETH (50: ETH traded over the opening curve), STEADY_ETH_PER_HOUR (2), TRADERS (12), MAX_HOURS (2000),
//   PACE_MS (0: real milliseconds to wait between simulated steps, to watch a launch play out on the site).
import { readFileSync } from "node:fs";
import { createPublicClient, createWalletClient, encodeAbiParameters, encodeFunctionData, encodePacked, formatEther, http,
  keccak256, maxUint256, parseAbi, parseEther, toHex } from "viem";
import { foundry } from "viem/chains";

const env = (k, d) => process.env[k] ?? d;
const rpc = env("RPC_URL", "http://127.0.0.1:8545");
const dep = JSON.parse(readFileSync(env("DEPLOYMENT", new URL("../../deployments/anvil.json", import.meta.url)), "utf8"));
const UNTIL = env("UNTIL", "minutes:64");
const OPENING_ETH = Number(env("OPENING_ETH", "50"));
const STEADY = Number(env("STEADY_ETH_PER_HOUR", "2"));
const N = Number(env("TRADERS", "12"));
const MAX_HOURS = Number(env("MAX_HOURS", "2000"));
const PACE_MS = Number(env("PACE_MS", "0"));

const UNIVERSAL_ROUTER = "0x66a9893cc07d91d95644aedd05d03f95e1dba8af";
const PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3";
const CURVE_MINUTES = 64;

const pub = createPublicClient({ transport: http(rpc) });
try {
  await pub.request({ method: "anvil_nodeInfo" });
} catch {
  console.error("local-trading: not an anvil node; refusing to run");
  process.exit(1);
}
const chain = { ...foundry, id: await pub.getChainId() };
const wallet = createWalletClient({ chain, transport: http(rpc) });

const tokenAbi = parseAbi(["function balanceOf(address) view returns (uint256)", "function approve(address,uint256) returns (bool)"]);
const permit2Abi = parseAbi(["function approve(address token, address spender, uint160 amount, uint48 expiration)"]);
const routerAbi = parseAbi(["function execute(bytes commands, bytes[] inputs, uint256 deadline) payable"]);
const hookAbi = parseAbi(["function launchedAt() view returns (uint256)", "function currentFeeBps(bool isBuy) view returns (uint256)"]);
const vaultAbi = parseAbi(["function tradingFees() view returns (uint256)", "function generalBalance() view returns (uint256)",
  "function activationThreshold() view returns (uint256)"]);
const gameAbi = parseAbi(["function capitalNeed() view returns (uint256)", "function keeperAvailable() view returns (uint256)"]);
const ownerAbi = parseAbi(["function heldCount() view returns (uint256)"]);

const key = { currency0: "0x0000000000000000000000000000000000000000", currency1: dep.token, fee: 0, tickSpacing: 200, hooks: dep.hook };
const POOL_KEY = { type: "tuple", components: [{ name: "currency0", type: "address" }, { name: "currency1", type: "address" },
  { name: "fee", type: "uint24" }, { name: "tickSpacing", type: "int24" }, { name: "hooks", type: "address" }] };

/** The site's swap: Universal Router V4_SWAP of SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL (no output floor here). */
function swapData(buy, amountIn, deadline) {
  const [cin, cout] = buy ? [key.currency0, key.currency1] : [key.currency1, key.currency0];
  const swap = encodeAbiParameters([{ type: "tuple", components: [{ name: "poolKey", ...POOL_KEY }, { name: "zeroForOne", type: "bool" },
    { name: "amountIn", type: "uint128" }, { name: "amountOutMinimum", type: "uint128" }, { name: "hookData", type: "bytes" }] }],
  [{ poolKey: key, zeroForOne: buy, amountIn, amountOutMinimum: 0n, hookData: "0x" }]);
  const settle = encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [cin, amountIn]);
  const take = encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [cout, 0n]);
  const input = encodeAbiParameters([{ type: "bytes" }, { type: "bytes[]" }], [encodePacked(["uint8", "uint8", "uint8"], [6, 12, 15]), [swap, settle, take]]);
  return encodeFunctionData({ abi: routerAbi, functionName: "execute", args: [encodePacked(["uint8"], [0x10]), [input], deadline] });
}

// a seeded generator, so a run is reproducible
let seed = 0x5eed;
const rand = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 2 ** 32);

const traders = Array.from({ length: N }, (_, i) => `0x${keccak256(toHex(`apeball-trader-${i}`)).slice(26)}`);
const approved = new Set();
for (const t of traders) await pub.request({ method: "anvil_setBalance", params: [t, toHex(parseEther("10000"))] });

// 30% above the estimate: during the opening curve the fee falls every second, so a buy mined after its estimate puts
// more ETH through the pool than estimated and can need more gas (the site sends the same headroom)
const send = async (from, to, data, value = 0n) => {
  const gas = (await pub.estimateGas({ account: from, to, data, value })) * 13n / 10n;
  const hash = await wallet.sendTransaction({ account: from, to, data, value, gas });
  const r = await pub.waitForTransactionReceipt({ hash });
  if (r.status !== "success") throw new Error(`reverted: ${hash}`);
};
const now = async () => (await pub.getBlock()).timestamp;

async function trade(volumeEth) {
  // two to six trades sharing the volume; three in four buy, the rest sell part of what a holder bought
  const n = 2 + Math.floor(rand() * 5);
  let bought = 0, sold = 0;
  for (let k = 0; k < n; k++) {
    const t = traders[Math.floor(rand() * traders.length)];
    const coins = await pub.readContract({ address: dep.token, abi: tokenAbi, functionName: "balanceOf", args: [t] });
    const deadline = (await now()) + 900n;
    if (rand() < 0.75 || coins === 0n) {
      const eth = parseEther(((volumeEth / n) * (0.5 + rand())).toFixed(6));
      if (eth === 0n) continue;
      await send(t, UNIVERSAL_ROUTER, swapData(true, eth, deadline), eth);
      bought += Number(formatEther(eth));
    } else {
      if (!approved.has(t)) {
        await send(t, dep.token, encodeFunctionData({ abi: tokenAbi, functionName: "approve", args: [PERMIT2, maxUint256] }));
        await send(t, PERMIT2, encodeFunctionData({ abi: permit2Abi, functionName: "approve", args: [dep.token, UNIVERSAL_ROUTER, 2n ** 160n - 1n, 2n ** 48n - 1n] }));
        approved.add(t);
      }
      const amount = (coins * BigInt(Math.floor((0.3 + rand() * 0.4) * 1000))) / 1000n;
      await send(t, UNIVERSAL_ROUTER, swapData(false, amount, deadline));
      sold++;
    }
  }
  return { bought, sold };
}

async function done() {
  if (UNTIL === "first-ape") {
    const [bal, thr] = await Promise.all([pub.getBalance({ address: dep.vault }),
      pub.readContract({ address: dep.vault, abi: vaultAbi, functionName: "activationThreshold" })]);
    return bal >= thr;
  }
  if (UNTIL === "board") {
    const [held, need, allow, general] = await Promise.all([
      pub.readContract({ address: dep.poolOwner, abi: ownerAbi, functionName: "heldCount" }),
      pub.readContract({ address: dep.game, abi: gameAbi, functionName: "capitalNeed" }),
      pub.readContract({ address: dep.game, abi: gameAbi, functionName: "keeperAvailable" }),
      pub.readContract({ address: dep.vault, abi: vaultAbi, functionName: "generalBalance" })]);
    return held > 0n && general >= need + allow;
  }
  if (UNTIL.startsWith("vault:")) return (await pub.getBalance({ address: dep.vault })) >= BigInt(UNTIL.slice(6));
  return false;
}

const launchedAt = await pub.readContract({ address: dep.hook, abi: hookAbi, functionName: "launchedAt" });
if (launchedAt === 0n) {
  console.error("local-trading: the market is not open yet");
  process.exit(1);
}
const minutes = UNTIL.startsWith("minutes:") ? Number(UNTIL.slice(8)) : Infinity;
// the opening curve's volume, rising linearly toward its end: weight 0.3 at minute 0 to 1.7 at minute 63
const weight = (m) => 0.3 + (1.4 * m) / (CURVE_MINUTES - 1);
const total = Array.from({ length: CURVE_MINUTES }, (_, m) => weight(m)).reduce((a, b) => a + b, 0);
const fees0 = await pub.readContract({ address: dep.vault, abi: vaultAbi, functionName: "tradingFees" });
let simulated = 0, hours = 0;
while (simulated < minutes && hours <= MAX_HOURS && !(await done())) {
  const minute = Number(((await now()) - launchedAt) / 60n);
  const curve = minute < CURVE_MINUTES;
  const fee = await pub.readContract({ address: dep.hook, abi: hookAbi, functionName: "currentFeeBps", args: [true] });
  const { bought, sold } = await trade(curve ? (OPENING_ETH * weight(minute)) / total : STEADY);
  const step = curve ? 60 : 3600;
  await pub.request({ method: "evm_increaseTime", params: [toHex(step)] });
  await pub.request({ method: "evm_mine", params: [] });
  simulated += step / 60;
  if (PACE_MS) await new Promise((r) => setTimeout(r, PACE_MS));
  if (!curve) hours++;
  const fees = await pub.readContract({ address: dep.vault, abi: vaultAbi, functionName: "tradingFees" });
  console.log(`local-trading: ${curve ? `minute ${minute}` : `hour ${hours}`} fee ${Number(fee) / 100}% bought ${bought.toFixed(3)} ETH, ${sold} sells; vault fees ${formatEther(fees)} ETH`);
}
const fees = await pub.readContract({ address: dep.vault, abi: vaultAbi, functionName: "tradingFees" });
console.log(`local-trading: done (${UNTIL}${(await done()) ? ", reached" : ""}); trading fees this run ${formatEther(fees - fees0)} ETH, total ${formatEther(fees)} ETH`);
