import { DocsShell } from "./Shell";
import { collectionMeta } from "../lib/deployment";
import { pageMeta } from "../lib/meta";

export const metadata = pageMeta("Docs", `How ${collectionMeta.game} works: draws, odds, prizes, ${collectionMeta.ticker}, the books and the contracts.`, "/docs/");

export default function DocsHome() {
  return <DocsShell slug="" />;
}
