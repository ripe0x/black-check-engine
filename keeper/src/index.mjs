// Collection Games keeper. Every job is simulated first; a job that would revert (NoWork, TooSoon, NotReady,
// PriceMoved, NotQualifying, ...) is skipped. The game pays this keeper's useful calls like anyone else's.
//
// Environment (no secrets in files): RPC_URL, KEEPER_PRIVATE_KEY (or KEEPER_ADDRESS on a local anvil with an
// impersonated account), DEPLOYMENT (path to deployments/<env>.json), CHAIN_ID (1), MODE (primary|backup, default
// backup), MAX_GAS_PRICE_GWEI (3: the game reimburses gas up to its maxGasPrice), BACKUP_AFTER_SECONDS (21600),
// BACKUP_BASEFEE_GATE_GWEI (1), GAS_PRICE_LIMIT_GWEI (10: never act above it, and never pay more per gas), POLL_SECONDS (60), UNPAID (0; 1 also sends sync once the keeper allowance is spent), LOG_LOOKBACK_BLOCKS (50000),
// LOG_CHUNK_BLOCKS (5000: many RPCs refuse wider log ranges), PRIORITY_FEE_GWEI (0.02: reimbursed with the gas, up to
// the cap), SWEEP (1: meter the vault's ETH into its live bid when a sweep can forward; the vault rewards it).
import { readFileSync } from "node:fs";
import { createPublicClient, createWalletClient, http, parseGwei } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";
import { gameAbi, vaultAbi, burnerAbi, migrationAbi, sunsetAbi, poolOwnerAbi, fwaPoolAbi } from "./abi.mjs";
import { shouldAct, jobs } from "./policy.mjs";

// the decoded custom error when there is one (NothingToSend, SweepTooEarly, NoWork, ...), else the first message line
const reason = (e) => e.walk?.((x) => x.data?.errorName)?.data?.errorName ?? (e.shortMessage ?? e.message).split("\n")[0];

const env = (k, d) => process.env[k] ?? d;
const rpc = env("RPC_URL", env("MAINNET_RPC_URL"));
const key = env("KEEPER_PRIVATE_KEY");
const localAccount = env("KEEPER_ADDRESS");
if (!rpc || (!key && !localAccount)) {
  console.error("RPC_URL and KEEPER_PRIVATE_KEY (or KEEPER_ADDRESS on a local node) are required");
  process.exit(1);
}
const dep = JSON.parse(readFileSync(env("DEPLOYMENT", new URL("../../deployments/mainnet.json", import.meta.url)), "utf8"));
const mode = env("MODE", "backup");
const maxGasPrice = parseGwei(env("MAX_GAS_PRICE_GWEI", "3"));
const sweepOn = env("SWEEP", "1") === "1";
const backupAfter = BigInt(env("BACKUP_AFTER_SECONDS", "21600"));
const gate = parseGwei(env("BACKUP_BASEFEE_GATE_GWEI", "1"));
const limit = parseGwei(env("GAS_PRICE_LIMIT_GWEI", "10"));
const pollMs = Number(env("POLL_SECONDS", "60")) * 1000;
const unpaid = env("UNPAID", "0") === "1";
const lookback = BigInt(env("LOG_LOOKBACK_BLOCKS", "50000"));
const priorityFee = parseGwei(env("PRIORITY_FEE_GWEI", "0.02"));
const chunk = BigInt(env("LOG_CHUNK_BLOCKS", "5000"));

const account = key ? privateKeyToAccount(key) : localAccount;
const chain = { ...mainnet, id: Number(env("CHAIN_ID", String(mainnet.id))) };
const pub = createPublicClient({ chain, transport: http(rpc) });
const wallet = createWalletClient({ account, chain, transport: http(rpc) });
const read = (address, abi, functionName, args = []) => pub.readContract({ address, abi, functionName, args });
const ZERO = "0x0000000000000000000000000000000000000000";

async function state() {
  const [activated, retiring, retired, ready, pool] = await Promise.all([
    read(dep.game, gameAbi, "activated"),
    read(dep.game, gameAbi, "retiring"),
    read(dep.game, gameAbi, "retired"),
    read(dep.game, gameAbi, "ready"),
    read(dep.game, gameAbi, "pool"),
  ]);
  // the burner's cadence (D64): the slice and the earliest time it may run follow play and milestone releases
  const [slice, , runAt] = await read(dep.burner, burnerAbi, "nextSlice");
  const block = await pub.getBlock();
  const burnerReady = slice > 0n && block.timestamp >= runAt;
  // the live bid: below its threshold a sweep fills it at once; above, once per cooldown (the simulation decides)
  const [bid, threshold, nextSweep] = await Promise.all([
    read(dep.vault, vaultAbi, "liveBid"), read(dep.vault, vaultAbi, "activationThreshold"),
    read(dep.vault, vaultAbi, "nextSweepBlock"),
  ]);
  const sweepReady = sweepOn && !retiring && !retired && (bid < threshold || block.number >= nextSweep);
  const reserve = await read(dep.burner, burnerAbi, "reserve");
  // the sunset: ETH waiting to be flushed to the burner, or an auction clock not yet started
  let sunsetDue = false;
  if (retired && dep.sunset) {
    const [succ, startedAt, bal] = await Promise.all([
      read(dep.migration, migrationAbi, "successor"), read(dep.sunset, sunsetAbi, "startedAt"),
      pub.getBalance({ address: dep.sunset }),
    ]);
    sunsetDue = bal > 0n || (succ.toLowerCase() === dep.sunset.toLowerCase() && startedAt === 0n);
  }
  // wins whose milestone release has not happened (normally the game releases while booking): Ape exits recorded by
  // the pool owner, and big prizes the game booked (D64 tiers; the burner checks FWA and its threshold again)
  const unreleasedWins = [];
  try {
    let from = block.number > lookback ? block.number - lookback : 0n;
    if (dep.block && BigInt(dep.block) > from) from = BigInt(dep.block);
    for (let lo = from; lo <= block.number; lo += chunk) {
      const hi = lo + chunk - 1n < block.number ? lo + chunk - 1n : block.number;
      const logs = await pub.getContractEvents({
        address: dep.poolOwner, abi: poolOwnerAbi, eventName: "CollectionWon", fromBlock: lo, toBlock: hi,
      });
      for (const l of logs) {
        const id = l.args.listingId;
        if (await read(dep.burner, burnerAbi, "qualifies", [id])) unreleasedWins.push(id);
      }
      const captured = await pub.getContractEvents({
        address: dep.game, abi: gameAbi, eventName: "Captured", fromBlock: lo, toBlock: hi,
      });
      for (const l of captured) {
        // a cheap prefilter: only prizes that cost 0.1 ETH or more can be big prizes
        if (l.args.collection || l.args.cost < 100_000_000_000_000_000n) continue;
        const id = l.args.listingId;
        if (await read(dep.burner, burnerAbi, "qualifies", [id])) unreleasedWins.push(id);
      }
    }
  } catch (e) {
    // a log scan failure only delays the fallback milestone release; every other job still runs
    console.error("win scan failed:", e.shortMessage ?? e.message);
  }
  return { activated, retiring, retired, ready, poolExists: pool !== ZERO, pool, burnerReady, runAt, unreleasedWins,
    sweepReady, reserve, sunsetDue, block };
}

function callOf(name, s, args) {
  switch (name) {
    case "sync": return { address: dep.game, abi: gameAbi, functionName: "sync", args: [] };
    case "retireStep": return { address: dep.game, abi: gameAbi, functionName: "retireStep", args: [] };
    case "activate": return { address: dep.game, abi: gameAbi, functionName: "activate", args: [] };
    case "processAcquisitions": return { address: s.pool, abi: fwaPoolAbi, functionName: "processAcquisitions", args: [10n] };
    case "buyback": return { address: dep.burner, abi: burnerAbi, functionName: "process", args: [0n] };
    case "release": return { address: dep.burner, abi: burnerAbi, functionName: "release", args };
    case "releaseRetired": return { address: dep.burner, abi: burnerAbi, functionName: "releaseRetired", args: [] };
    case "sweep": return { address: dep.vault, abi: vaultAbi, functionName: "sweep", args: [] };
    case "migrateApes": return { address: dep.migration, abi: migrationAbi, functionName: "migrateApes", args: [10n] };
    case "migrateCapital": return { address: dep.migration, abi: migrationAbi, functionName: "migrateCapital", args: [] };
    case "flushSunset": return { address: dep.sunset, abi: sunsetAbi, functionName: "flush", args: [] };
  }
  throw new Error(`unknown job ${name}`);
}

// When this keeper first saw each job's work waiting (its simulation succeeding): the age a backup keeper waits on.
const firstSeen = new Map();

function ageOf(name, s) {
  if (name === "sync" || name === "retireStep") {
    if (!firstSeen.has(name)) firstSeen.set(name, s.block.timestamp);
    return s.block.timestamp - firstSeen.get(name);
  }
  if (name === "buyback") return s.block.timestamp > s.runAt ? s.block.timestamp - s.runAt : 0n;
  return backupAfter + 1n; // activation, releases, sweeps, retirement hand-over: act at once
}

export async function tick() {
  const s = await state();
  const basefee = s.block.baseFeePerGas ?? 0n;
  for (const job of jobs(s)) {
    let request;
    const call = callOf(job.name, s, job.args);
    try {
      ({ request } = await pub.simulateContract({ account, ...call }));
    } catch (e) {
      firstSeen.delete(job.name); // nothing to do: the work is not waiting
      console.log(`${job.name}: skipped (${reason(e)})`);
      continue;
    }
    // a paid sync with the allowance spent pays nothing (it still succeeds): leave it to players' draws. Retirement is
    // sent anyway: it must finish, and only once.
    if (job.name === "sync" && !unpaid && (await read(dep.game, gameAbi, "keeperAvailable")) === 0n) {
      firstSeen.delete(job.name);
      console.log("sync: skipped (keeper allowance spent)");
      continue;
    }
    // light work right after a player's draw did the upkeep is done but not paid (D82): leave it to the next draw
    if (job.name === "sync" && !unpaid) {
      const [last, kp, light] = await Promise.all([
        read(dep.game, gameAbi, "lastUpkeepAt"),
        read(dep.game, gameAbi, "keeperParams"),
        read(dep.game, gameAbi, "PLAYER_UPKEEP_GAS"),
      ]);
      if (s.block.timestamp < last + kp.payDelay && (await pub.estimateContractGas({ account, ...call })) < light) {
        console.log(`sync: skipped (unpaid until ${last + kp.payDelay}: left to players)`);
        continue;
      }
    }
    const age = ageOf(job.name, s);
    if (!shouldAct({ mode, ageSeconds: age, basefeeWei: basefee, maxBasefeeWei: maxGasPrice, backupAfterSeconds: backupAfter, gateWei: gate, limitWei: limit })) {
      console.log(`${job.name}: waiting (age ${age}s, basefee ${basefee})`);
      continue;
    }
    try {
      // Estimates can fall short when a call's work depends on remaining gas (FWA's bounded self-calls, payments):
      // send with a 30% buffer.
      const gas = await pub.estimateContractGas({ account, ...call });
      const want = basefee * 2n + priorityFee;
      const maxFeePerGas = want < limit ? want : limit;
      const hash = await wallet.writeContract({ ...request, gas: (gas * 13n) / 10n, maxFeePerGas, maxPriorityFeePerGas: priorityFee });
      const receipt = await pub.waitForTransactionReceipt({ hash });
      firstSeen.delete(job.name);
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
