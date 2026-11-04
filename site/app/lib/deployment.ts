import record from "./deployment.generated.json";
import type { Address } from "viem";

export type Deployment = {
  chainId: number;
  deployed: boolean;
  block?: number;
  game: Address;
  vault: Address;
  poolOwner: Address;
  packs: Address;
  burner: Address;
  hook: Address;
  liquidity: Address;
  token: Address;
  lens: Address;
  drawRouter: Address;
  migration: Address;
  sunset: Address;
  adapter: Address;
  collection: Address;
  owner: Address;
  admin: Address;
  /** The Checks desk: composition, Black Check formation, buyouts. */
  desk: Address;
  /** The council timelock (D012). */
  council: Address;
};

export const deployment = record as unknown as Deployment;

/** Display metadata for the configured collection (frontend only; nothing on chain depends on it). */
export const collectionMeta = {
  name: process.env.NEXT_PUBLIC_COLLECTION_NAME || "Checks",
  short: process.env.NEXT_PUBLIC_COLLECTION_SHORT || "Check",
  /** "a" or "an" before `short`. */
  article: process.env.NEXT_PUBLIC_COLLECTION_ARTICLE || "a",
  // the coin's name and ticker are unresolved (invariant 9): a neutral placeholder until the owner names it
  coin: (process.env.NEXT_PUBLIC_COIN_SYMBOL || "COIN").replace(/^\$+/, ""),
  /** The coin as it is written everywhere on the site: its symbol with exactly one dollar sign. */
  get ticker() {
    return `$${this.coin}`;
  },
  /** The game's name, shown as the wordmark. */
  game: process.env.NEXT_PUBLIC_GAME_NAME || "Checks Survival",
  explorer: "https://etherscan.io",
};
