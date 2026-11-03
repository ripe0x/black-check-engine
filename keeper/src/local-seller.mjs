// Local Ape seller: on a local anvil fork there are no BAYC holders watching the vault's live bid, so an Ape is never
// sold to it. This plays one: whenever the vault's live bid reaches the floor a holder would accept (the vault's funding
// reference price, read each poll, unless FLOOR_ETH is set), a real BAYC holder on the fork (impersonated, anvil only) approves the
// vault and sells one Ape at the bid with `sellToProtocol`. It keeps going for later Apes. Anvil's chain id only
// (31337); it refuses to run anywhere else.
//
// Environment: RPC_URL (http://127.0.0.1:8545), DEPLOYMENT (../../deployments/anvil.json), FLOOR_ETH (unset),
// FIRST_APE_ID (100: holders are looked up from this token id), POLL_MS (3000).
import { readFileSync } from "node:fs";
import { createPublicClient, createWalletClient, formatEther, http, parseAbi, parseEther, toHex } from "viem";
import { foundry } from "viem/chains";

const ANVIL_CHAIN_ID = 31337;
const env = (k, d) => process.env[k] ?? d;
const rpc = env("RPC_URL", "http://127.0.0.1:8545");
const dep = JSON.parse(readFileSync(env("DEPLOYMENT", new URL("../../deployments/anvil.json", import.meta.url)), "utf8"));
const fixedFloor = process.env.FLOOR_ETH ? parseEther(process.env.FLOOR_ETH) : undefined;
const pollMs = Number(env("POLL_MS", "3000"));
let nextId = BigInt(env("FIRST_APE_ID", "100"));

const chain = { ...foundry, id: ANVIL_CHAIN_ID };
const pub = createPublicClient({ chain, transport: http(rpc) });
const chainId = await pub.getChainId();
if (chainId !== ANVIL_CHAIN_ID) {
  console.error(`local-seller: chain id ${chainId}, not anvil's ${ANVIL_CHAIN_ID}; refusing to run`);
  process.exit(1);
}

const vaultAbi = parseAbi([
  "function liveBid() view returns (uint256)",
  "function sellToProtocol(uint256 tokenId, uint256 price)",
  "function excluded(uint256) view returns (bool)",
  "function referencePrice() view returns (uint256)",
]);
const nftAbi = parseAbi([
  "function ownerOf(uint256) view returns (address)",
  "function isApprovedForAll(address, address) view returns (bool)",
  "function setApprovalForAll(address, bool)",
]);

/** The next Ape held by an ordinary wallet (not a contract, not the protocol), from `nextId` on. */
async function nextHolder() {
  for (let k = 0; k < 500; k++, nextId++) {
    const id = nextId;
    const owner = await pub.readContract({ address: dep.collection, abi: nftAbi, functionName: "ownerOf", args: [id] }).catch(() => undefined);
    if (!owner || owner.toLowerCase() === dep.poolOwner.toLowerCase()) continue;
    if ((await pub.getCode({ address: owner }))?.length > 2) continue; // a contract (a vault, a marketplace)
    if (await pub.readContract({ address: dep.vault, abi: vaultAbi, functionName: "excluded", args: [id] })) continue;
    nextId++;
    return { id, owner };
  }
  throw new Error("no ordinary holder found");
}

console.log(`local-seller: chain ${chainId}, vault ${dep.vault}, sells one Ape whenever the live bid reaches ${fixedFloor === undefined ? "the reference price" : `${formatEther(fixedFloor)} ETH`}`);
for (;;) {
  try {
    const bid = await pub.readContract({ address: dep.vault, abi: vaultAbi, functionName: "liveBid" });
    const floor = fixedFloor ?? (await pub.readContract({ address: dep.vault, abi: vaultAbi, functionName: "referencePrice" }));
    if (bid >= floor) {
      const { id, owner } = await nextHolder();
      await pub.request({ method: "anvil_impersonateAccount", params: [owner] });
      await pub.request({ method: "anvil_setBalance", params: [owner, toHex(10n ** 18n)] }); // gas only
      const holder = createWalletClient({ account: owner, chain, transport: http(rpc) });
      if (!(await pub.readContract({ address: dep.collection, abi: nftAbi, functionName: "isApprovedForAll", args: [owner, dep.vault] }))) {
        await pub.waitForTransactionReceipt({ hash: await holder.writeContract({ address: dep.collection, abi: nftAbi, functionName: "setApprovalForAll", args: [dep.vault, true] }) });
      }
      const hash = await holder.writeContract({ address: dep.vault, abi: vaultAbi, functionName: "sellToProtocol", args: [id, bid] });
      const r = await pub.waitForTransactionReceipt({ hash });
      console.log(`local-seller: holder ${owner} sold Ape #${id} for ${formatEther(bid)} ETH: ${r.status} ${hash}`);
    }
  } catch (e) {
    console.log(`local-seller: ${e.shortMessage ?? e.message}`);
  }
  await new Promise((res) => setTimeout(res, pollMs));
}
