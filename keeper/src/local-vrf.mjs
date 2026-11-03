// Local randomness service: on a local anvil fork, nobody runs Chainlink VRF, so FWA's draws would wait for a random
// word forever. This delivers one for every pending request, the way the coordinator would: it impersonates the
// coordinator (anvil only) and calls FWA's VRF service with a fresh random word. Anvil's chain id only (31337); it
// refuses to run anywhere else.
//
// Environment: RPC_URL (http://127.0.0.1:8545), DEPLOYMENT (../../deployments/anvil.json), POLL_MS (1500).
import { readFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { createPublicClient, createWalletClient, http, parseAbi, toHex } from "viem";
import { foundry } from "viem/chains";

const ANVIL_CHAIN_ID = 31337;
// FWA's Chainlink VRF consumer on mainnet; its coordinator is the only caller it accepts
const VRF_SERVICE = "0xA4adFC35dB18326eFB3b5D9bf66A8103Ec2D5EE2";
const PENDING = 1; // FWA AcquisitionStatus.Pending: waiting for an on-time VRF word

const env = (k, d) => process.env[k] ?? d;
const rpc = env("RPC_URL", "http://127.0.0.1:8545");
const dep = JSON.parse(readFileSync(env("DEPLOYMENT", new URL("../../deployments/anvil.json", import.meta.url)), "utf8"));
const pollMs = Number(env("POLL_MS", "1500"));

const chain = { ...foundry, id: ANVIL_CHAIN_ID };
const pub = createPublicClient({ chain, transport: http(rpc) });
const id = await pub.getChainId();
if (id !== ANVIL_CHAIN_ID) {
  console.error(`local-vrf: chain id ${id}, not anvil's ${ANVIL_CHAIN_ID}; refusing to run`);
  process.exit(1);
}

const vrfAbi = parseAbi([
  "function s_vrfCoordinator() view returns (address)",
  "function approvedCallbackGasLimit() view returns (uint32)",
  "function requestStatus(uint256) view returns (uint8)",
  "function rawFulfillRandomWords(uint256 requestId, uint256[] randomWords)",
  "function deliverRandomness(uint256 requestId) returns (bool)",
]);
// the service's RequestStatus: no word yet; a word stored (or an empty word array) but not handed to the pool
const OUTSTANDING = 1, STORED = 2, EMPTY_STORED = 3;
const poolAbi = parseAbi([
  "function lastIssuedSequence() view returns (uint64)",
  "function nextSequenceToProcess() view returns (uint64)",
  "function requestIdAtSequence(uint64) view returns (uint256)",
  "function acquisitions(uint256) view returns (address purchaser, uint256 requestBlock, uint256 priceEscrowed, uint256 listingId, uint8 status)",
]);
const gameAbi = parseAbi(["function pool() view returns (address)"]);

const coordinator = await pub.readContract({ address: VRF_SERVICE, abi: vrfAbi, functionName: "s_vrfCoordinator" });
// The service hands the word to the pool only if the call leaves its whole callback gas limit plus 1/63 (EIP-150) and
// an 80,000 reserve; with less it stores the word and defers (RandomnessDeliveryDeferred). Estimation takes that cheap
// path, so gas is sized from the limit, with room for the service's own work.
const limit = BigInt(await pub.readContract({ address: VRF_SERVICE, abi: vrfAbi, functionName: "approvedCallbackGasLimit" }));
const GAS = limit + limit / 63n + 80_000n + 300_000n;
await pub.request({ method: "anvil_impersonateAccount", params: [coordinator] });
await pub.request({ method: "anvil_setBalance", params: [coordinator, toHex(10n ** 20n)] });
const wallet = createWalletClient({ account: coordinator, chain, transport: http(rpc) });
const pool = await pub.readContract({ address: dep.game, abi: gameAbi, functionName: "pool" });
console.log(`local-vrf: chain ${id}, pool ${pool}, delivering words as ${coordinator}`);

const done = new Set();
async function tick() {
  const [next, last] = await Promise.all([
    pub.readContract({ address: pool, abi: poolAbi, functionName: "nextSequenceToProcess" }),
    pub.readContract({ address: pool, abi: poolAbi, functionName: "lastIssuedSequence" }),
  ]);
  for (let seq = next; seq <= last; seq++) {
    const req = await pub.readContract({ address: pool, abi: poolAbi, functionName: "requestIdAtSequence", args: [seq] });
    if (req === 0n || done.has(req)) continue;
    const [, , , , status] = await pub.readContract({ address: pool, abi: poolAbi, functionName: "acquisitions", args: [req] });
    if (status !== PENDING) continue;
    const at = await pub.readContract({ address: VRF_SERVICE, abi: vrfAbi, functionName: "requestStatus", args: [req] });
    const call = at === OUTSTANDING
      ? { functionName: "rawFulfillRandomWords", args: [req, [BigInt(toHex(randomBytes(32)))]] } // as the coordinator, a fresh word
      : at === STORED || at === EMPTY_STORED ? { functionName: "deliverRandomness", args: [req] } // a word stored earlier, deferred
        : null;
    if (!call) continue;
    const hash = await wallet.writeContract({ address: VRF_SERVICE, abi: vrfAbi, ...call, gas: GAS });
    const r = await pub.waitForTransactionReceipt({ hash });
    const after = (await pub.readContract({ address: pool, abi: poolAbi, functionName: "acquisitions", args: [req] }))[4];
    if (after !== PENDING) done.add(req);
    console.log(`local-vrf: sequence ${seq}: ${call.functionName} ${r.status}, draw status ${status} -> ${after} (${hash})`);
  }
}

for (;;) {
  await tick().catch((e) => console.error(`local-vrf: ${(e.shortMessage ?? e.message).split("\n")[0]}`));
  await new Promise((r) => setTimeout(r, pollMs));
}
