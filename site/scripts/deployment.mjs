// Copies deployments/<NEXT_PUBLIC_DEPLOYMENT>.json (default "mainnet") into the bundle. Without a record (before the
// mainnet deployment) it writes a placeholder with zero addresses, and the site says it is not deployed yet.
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const name = process.env.NEXT_PUBLIC_DEPLOYMENT || "mainnet";
const src = fileURLToPath(new URL(`../../deployments/${name}.json`, import.meta.url));
const out = fileURLToPath(new URL("../app/lib/deployment.generated.json", import.meta.url));
const zero = "0x0000000000000000000000000000000000000000";
const keys = ["game", "vault", "poolOwner", "burner", "hook", "liquidity", "token", "lens", "drawRouter",
  "migration", "sunset", "adapter", "collection", "owner", "admin", "packs"];
let rec = { chainId: 1, deployed: false };
if (existsSync(src)) {
  rec = { ...JSON.parse(readFileSync(src, "utf8")), deployed: true };
  // a local deployment must be on anvil's own chain id: a fork that kept mainnet's id (1) would have wallets sign on
  // mainnet against addresses that exist only on the fork
  if (name === "anvil" && Number(rec.chainId) !== 31337) {
    throw new Error(`deployments/anvil.json has chainId ${rec.chainId}; run anvil with --chain-id 31337 and redeploy`);
  }
} else {
  for (const k of keys) rec[k] = zero;
}
writeFileSync(out, JSON.stringify(rec, null, 2));
console.log(`deployment: ${existsSync(src) ? src : "placeholder (not deployed)"}`);
