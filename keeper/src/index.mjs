// Permissionless keeper for a Black Check Engine deployment. Every action is one the engine already lets anyone take;
// each is simulated with eth_call first and skipped if the simulation reverts, so the keeper never pushes a doomed or
// no-op transaction. Jobs are independent and idempotent (src/policy.mjs for the order and the decision logic).
//
// Config (env; no secrets ever written to a file):
//   RPC_URL           default https://mainnet.gateway.tenderly.co
//   ENGINE            engine proxy address (required)
//   HOOK              VenueHook address (optional; enables forward())
//   BURNER            Burner address (optional; enables burn())
//   DRY_RUN           default true: log the transactions it would send, send nothing (no key needed)
//   KEEPER_PRIVATE_KEY  only read when DRY_RUN=false; never logged, written, or committed
//   KEEPER_ADDRESS    a local-node unlocked/impersonated account, instead of a key (anvil rehearsal only)
//   FROM_BLOCK        first block to scan engine events from (default 0; set to the deploy block on mainnet)
//   CHUNK_BLOCKS      log scan window (default 5000; many RPCs refuse wider ranges)
//   FWA_BATCH         ids per FWA-bound call (default 20 = FWA MAX_INVENTORY_BATCH)
//   MAX_GAS_PRICE_GWEI  skip sending while basefee is above this (default 0 = no cap)
//   POLL_SECONDS      default 60; --once runs a single tick
//   CHAIN_ID          default 1
import {createPublicClient, createWalletClient, http, parseGwei} from "viem";
import {privateKeyToAccount} from "viem/accounts";
import {mainnet} from "viem/chains";
import {engineAbi, checksAbi, controllerAbi, poolAbi, hookAbi, burnerAbi} from "./abi.mjs";
import {jobs, repriceTarget, composePairs, blackBatch} from "./policy.mjs";

const env = (k, d) => process.env[k] ?? d;
const ZERO = "0x0000000000000000000000000000000000000000";
const dryRun = env("DRY_RUN", "true") !== "false";
const rpc = env("RPC_URL", "https://mainnet.gateway.tenderly.co");
const engine = env("ENGINE");
const hook = (env("HOOK") || "").toLowerCase() || null;
const burner = (env("BURNER") || "").toLowerCase() || null;
const fromBlock = BigInt(env("FROM_BLOCK", "0"));
const chunk = BigInt(env("CHUNK_BLOCKS", "5000"));
const fwaBatch = Number(env("FWA_BATCH", "20"));
const maxGasPrice = parseGwei(env("MAX_GAS_PRICE_GWEI", "0"));
const pollMs = Number(env("POLL_SECONDS", "60")) * 1000;
const chain = {...mainnet, id: Number(env("CHAIN_ID", "1"))};

if (!engine) {
  console.error("ENGINE is required");
  process.exit(1);
}
// The signing account only exists for real sends. In dry run we need no key at all.
let account;
if (!dryRun) {
  const key = env("KEEPER_PRIVATE_KEY");
  const addr = env("KEEPER_ADDRESS");
  if (key) account = privateKeyToAccount(key);
  else if (addr) account = addr; // unlocked local-node account; no private key on disk
  else {
    console.error("send mode needs KEEPER_PRIVATE_KEY (or KEEPER_ADDRESS on a local node)");
    process.exit(1);
  }
}

const pub = createPublicClient({chain, transport: http(rpc)});
const wallet = account ? createWalletClient({account, chain, transport: http(rpc)}) : null;
// a simulation account that always exists (reads don't spend); real sends use `account`.
const from = account ?? "0x000000000000000000000000000000000000dEaD";
const read = (address, abi, functionName, args = []) => pub.readContract({address, abi, functionName, args});
const reason = (e) => e.walk?.((x) => x.data?.errorName)?.data?.errorName ?? (e.shortMessage ?? e.message).split("\n")[0];
const tryRead = async (p) => { try { return await p; } catch { return null; } };

// ------------------------------------------------------------------ discovery

// Collect every token id the engine has ever touched, split into checks and shapes. The engine's own events are the
// enumerator; the current role of each id is decided from live on-chain state below, so any event ordering is safe.
// ponytail: full rescan from FROM_BLOCK each tick (stateless). Add a JSON cache of the last block if mainnet history
// makes the scan costly.
async function universe(head) {
  const checkIds = new Set();
  const shapeIds = new Set();
  const checksAddr = (await read(engine, engineAbi, "checks")).toLowerCase();
  for (let lo = fromBlock; lo <= head; lo += chunk) {
    const hi = lo + chunk - 1n < head ? lo + chunk - 1n : head;
    const logs = await pub.getContractEvents({address: engine, abi: engineAbi, fromBlock: lo, toBlock: hi});
    for (const l of logs) {
      const a = l.args;
      switch (l.eventName) {
        case "Listed":
        case "Unlisted":
          (a.collection.toLowerCase() === checksAddr ? checkIds : shapeIds).add(a.tokenId);
          break;
        case "Composed":
          checkIds.add(a.survivor); checkIds.add(a.burned); break;
        case "BlackCheck":
          checkIds.add(a.survivor); for (const b of a.burned) checkIds.add(b); break;
        case "Bought":
        case "Acquired":
          checkIds.add(a.tokenId); break;
        case "Restocked":
          shapeIds.add(a.wonShapeId); shapeIds.add(a.newShapeId); break;
      }
    }
  }
  return {checkIds: [...checkIds], shapeIds: [...shapeIds]};
}

// ------------------------------------------------------------------ classification

async function state() {
  const head = await pub.getBlock();
  const controller = await read(engine, engineAbi, "controller");
  const [engineBurner, {checkIds, shapeIds}, p] = await Promise.all([
    read(engine, engineAbi, "burner"),
    universe(head.number),
    read(engine, engineAbi, "params"),
  ]);
  // params() is a public struct getter: viem returns its members as an array
  // [shapeMarkupBps, decayBpsPerDraw, floorBps, repriceStepBps, graceDraws, buyoutMarkupBps, bidBps, bidWeeklyCap].
  const params = {decayBpsPerDraw: BigInt(p[1]), floorBps: BigInt(p[2]),
    repriceStepBps: BigInt(p[3]), graceDraws: BigInt(p[4])};
  const checksAddr = await read(engine, engineAbi, "checks");
  const pool = await tryRead(read(controller, controllerAbi, "pool"));
  const unsettled = pool ? await tryRead(read(controller, controllerAbi, "unsettled")) : null;
  const queueEmpty = unsettled === 0n;

  const listChecksIds = [];
  const reprice = [];
  const ready = []; // eligible checks past grace: compose/formBlack candidates
  const tierNotionalCache = new Map();
  const tierN = async (t) => {
    if (!tierNotionalCache.has(t)) tierNotionalCache.set(t, await read(engine, engineAbi, "tierNotional", [BigInt(t)]));
    return tierNotionalCache.get(t);
  };
  for (const id of checkIds) {
    const [listing, owner, check] = await Promise.all([
      read(engine, engineAbi, "checkListing", [id]),
      tryRead(read(checksAddr, checksAbi, "ownerOf", [id])),
      tryRead(read(checksAddr, checksAbi, "getCheck", [id])),
    ]);
    if (!check) continue;
    const tier = check.stored.divisorIndex;
    const [lController, lListingId, lPrice] = listing; // checkListing: [controller, listingId, price]
    const listedHere = lController.toLowerCase() === controller.toLowerCase()
      && (await tryRead(read(controller, controllerAbi, "isListed", [lListingId])));
    if (listedHere) {
      // reprice: only with an empty queue, and only when the price actually moves by the step (or to a boundary)
      if (queueEmpty) {
        const survived = await read(engine, engineAbi, "survivedDraws", [id]);
        const target = repriceTarget({tierNotional: await tierN(tier), survived, oldPrice: lPrice, ...params});
        if (target !== null) reprice.push(id);
      }
      // compose/formBlack: free only when eligible and grace draws past the threshold
      if (await read(engine, engineAbi, "eligible", [id])) {
        const survived = await read(engine, engineAbi, "survivedDraws", [id]);
        const threshold = BigInt(await read(engine, engineAbi, "drawsToCompose", [BigInt(Math.min(tier, 6))]));
        if (survived >= threshold + params.graceDraws) ready.push({id, tier, survived});
      }
    } else if (owner && owner.toLowerCase() === engine.toLowerCase() && lController === ZERO && check.isRevealed) {
      listChecksIds.push(id); // in custody, revealed, unlisted; listChecks will set the price / refuse an unlisted tier
    }
  }

  const listShapesIds = [];
  const restock = [];
  const shapesAddr = await read(engine, engineAbi, "shapes");
  for (const id of shapeIds) {
    const [listing, owner] = await Promise.all([
      read(engine, engineAbi, "shapeListing", [id]),
      tryRead(read(shapesAddr, checksAbi, "ownerOf", [id])),
    ]);
    const [sController, sListingId, sPrice] = listing; // shapeListing: [controller, listingId, price]
    const live = sController !== ZERO
      && (await tryRead(read(controller, controllerAbi, "isListed", [sListingId])));
    if (!live && sPrice !== 0n) restock.push(id); // won by a player: replace at the same backing
    else if (!live && owner && owner.toLowerCase() === engine.toLowerCase() && sController === ZERO) {
      listShapesIds.push(id);
    }
  }

  // collect: only when the controller actually holds proceeds (collect() is a no-op otherwise, not a revert)
  let collectController = null;
  if (pool) {
    const [proceeds, bal] = await Promise.all([
      tryRead(read(pool, poolAbi, "ownerProceeds")),
      tryRead(pub.getBalance({address: controller})),
    ]);
    if ((proceeds && proceeds > 0n) || (bal && bal > 0n)) collectController = controller;
  }

  // processAcquisitions: only with a non-empty queue whose head is ready (has a VRF word) or past its deadline
  let processAcq = null;
  if (pool && unsettled && unsettled > 0n) {
    const seq = await tryRead(read(pool, poolAbi, "nextSequenceToProcess"));
    const reqId = seq != null ? await tryRead(read(pool, poolAbi, "requestIdAtSequence", [seq])) : null;
    const meta = reqId ? await tryRead(read(pool, poolAbi, "acquisitionMeta", [reqId])) : null;
    // acquisitionMeta: [sequence, wordDeadlineBlock, rewardEpoch, maxPos, maxNeg, randomWord]
    if (meta && (meta[5] !== 0n || head.number >= BigInt(meta[1]))) {
      processAcq = {pool, count: BigInt(fwaBatch)};
    }
  }

  return {
    basefee: head.baseFeePerGas ?? 0n,
    pool, listChecks: listChecksIds, listShapes: listShapesIds, reprice, restock,
    composePairs: composePairs(ready), blackBatch: blackBatch(ready),
    collectController, hook, burner, releaseSurplus: engineBurner !== ZERO, processAcq,
  };
}

// ------------------------------------------------------------------ calls

function callOf(job, s) {
  switch (job.name) {
    case "processAcquisitions": return {address: s.pool, abi: poolAbi, functionName: "processAcquisitions", args: [s.processAcq.count]};
    case "listChecks": return {address: engine, abi: engineAbi, functionName: "listChecks", args: [job.ids.slice(0, fwaBatch)]};
    case "listShapes": return {address: engine, abi: engineAbi, functionName: "listShapes", args: [job.ids.slice(0, fwaBatch)]};
    case "restockShapes": return {address: engine, abi: engineAbi, functionName: "restockShapes", args: [job.ids.slice(0, fwaBatch)]};
    case "reprice": return {address: engine, abi: engineAbi, functionName: "reprice", args: [job.ids.slice(0, fwaBatch)]};
    case "compose": return {address: engine, abi: engineAbi, functionName: "compose", args: [job.pair[0], job.pair[1], false]};
    case "formBlack": return {address: engine, abi: engineAbi, functionName: "formBlack", args: [job.ids]};
    case "collect": return {address: engine, abi: engineAbi, functionName: "collect", args: [job.address]};
    case "forward": return {address: hook, abi: hookAbi, functionName: "forward", args: []};
    case "releaseSurplus": return {address: engine, abi: engineAbi, functionName: "releaseSurplus", args: []};
    case "burn": return {address: burner, abi: burnerAbi, functionName: "burn", args: []};
  }
  throw new Error(`unknown job ${job.name}`);
}

// ------------------------------------------------------------------ loop

export async function tick() {
  const s = await state();
  if (maxGasPrice > 0n && s.basefee > maxGasPrice) {
    console.log(`basefee ${s.basefee} > cap ${maxGasPrice}: holding this tick`);
    return;
  }
  for (const job of jobs(s)) {
    const call = callOf(job, s);
    let request;
    try {
      ({request} = await pub.simulateContract({account: from, ...call}));
    } catch (e) {
      console.log(`${job.name}: skipped (${reason(e)})`);
      continue;
    }
    const label = call.args.length ? `${job.name}(${call.args.join(",")})` : job.name;
    if (dryRun) {
      console.log(`${job.name}: would send ${label}`);
      continue;
    }
    try {
      const gas = await pub.estimateContractGas({account: from, ...call});
      const hash = await wallet.writeContract({...request, gas: (gas * 13n) / 10n}); // 30% buffer: gas-dependent self-calls
      const receipt = await pub.waitForTransactionReceipt({hash});
      console.log(`${job.name}: ${receipt.status} ${hash} gas ${receipt.gasUsed}`);
    } catch (e) {
      console.log(`${job.name}: skipped (${reason(e)})`);
    }
  }
}

const once = process.argv.includes("--once");
do {
  try {
    await tick();
  } catch (e) {
    console.error("tick failed:", e.shortMessage ?? e.message, process.env.DEBUG ? e : "");
  }
  if (!once) await new Promise((r) => setTimeout(r, pollMs));
} while (!once);
