import { collectionMeta } from "../lib/deployment";
import { pageMeta } from "../lib/meta";

export const metadata = pageMeta(collectionMeta.ticker, `Trade ${collectionMeta.ticker}, ${collectionMeta.game}'s coin: price, chart and swap.`, "/coin/");

export default function CoinLayout({ children }: { children: React.ReactNode }) {
  return children;
}
