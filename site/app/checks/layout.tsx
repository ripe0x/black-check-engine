import { collectionMeta } from "../lib/deployment";
import { pageMeta } from "../lib/meta";

export const metadata = pageMeta(
  "Checks in the draw",
  `Every Check in ${collectionMeta.game}: its tier, odds price, survived draws, composition and buyout.`,
  "/checks/",
);

export default function ChecksLayout({ children }: { children: React.ReactNode }) {
  return children;
}
