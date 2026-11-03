import { collectionMeta } from "../lib/deployment";

// The docs' table of contents: sections in reading order, each page a slug under /docs/ ("" is /docs/ itself).
export const SECTIONS: { title: string; pages: [slug: string, title: string][] }[] = [
  { title: "Getting started", pages: [["", `What ${collectionMeta.game} is`], ["draws", "How a draw works"], ["odds", "Odds"], ["costs", "Costs and refunds"]] },
  { title: "Prizes", pages: [["apes", `${collectionMeta.short}s`], ["shapes", "Shapes and Packs"], ["board", "How the board grows"]] },
  { title: collectionMeta.ticker, pages: [["fees", "Fees and the opening curve"], ["fee-flow", "Where fees go"], ["buybacks", "Buybacks and burns"]] },
  { title: "Selling to the protocol", pages: [["live-bid", "The live bid"], ["sweeps", "Sweeps"]] },
  { title: "Transparency", pages: [["books", "The books"], ["burns", "Burns"], ["contracts", "Contracts"], ["governance", "Owner powers, migration and sunset"], ["changes", "Change log"]] },
  { title: "Safety", pages: [["risks", "Risks and audit status"]] },
  { title: "Developers", pages: [["keeper", "Running a keeper"], ["local", "Local dev chain"]] },
];

export const PAGES = SECTIONS.flatMap((s) => s.pages.map(([slug, title]) => ({ slug, title, section: s.title })));
