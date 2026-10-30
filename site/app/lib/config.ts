import type { Address } from "viem";

// The single config surface. Everything comes from NEXT_PUBLIC_* env (see .env.example); the engine proxy is the only
// address needed, every other contract (controller, pool, Checks, coin, Shapes) is read from it on chain. No secret is
// ever read or bundled.
// Each var is read as a static `process.env.NEXT_PUBLIC_*` member: the Next bundler only inlines these into the client
// bundle when the key is literal, so a dynamic `process.env[k]` would be undefined in the browser.
const pick = (v: string | undefined, d: string) => (v?.trim() || d);
const ZERO = "0x0000000000000000000000000000000000000000" as const;

export const config = {
  chainId: Number(pick(process.env.NEXT_PUBLIC_CHAIN_ID, "1")),
  rpcUrl: pick(process.env.NEXT_PUBLIC_RPC_URL, "https://mainnet.gateway.tenderly.co"),
  engine: pick(process.env.NEXT_PUBLIC_ENGINE, ZERO) as Address,
  deployBlock: BigInt(pick(process.env.NEXT_PUBLIC_DEPLOY_BLOCK, "0")),
  projectName: pick(process.env.NEXT_PUBLIC_PROJECT_NAME, "Survival Checks (placeholder)"),
  coinSymbol: pick(process.env.NEXT_PUBLIC_COIN_SYMBOL, "COIN"),
  explorer: "https://etherscan.io",
};

// A real engine address means the site has a deployment to read; otherwise every page shows the not-deployed notice.
export const deployed = config.engine.toLowerCase() !== ZERO;

// Checks Originals, mainnet. Used only for its own image/approval ABIs; the engine's `checks()` is the source of truth.
export const CHECKS_MAINNET = "0x036721e5A769Cc48B3189EFbb9ccE4471E8A48B1" as Address;

export const TIER_NAMES = ["80", "40", "20", "10", "5", "4", "Single", "Black"] as const;
export const tierName = (i: number) => TIER_NAMES[i] ?? `tier ${i}`;
