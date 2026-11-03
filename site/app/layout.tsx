import type { Metadata, Viewport } from "next";
import "./globals.css";
import { Providers } from "./Providers";
import { CoinContract, Nav } from "./components/Nav";
import { collectionMeta } from "./lib/deployment";
import { pageMeta } from "./lib/meta";
import { Promo } from "./components/Promo";

// The promo build (NEXT_PUBLIC_PROMO=1): every page is the dome alone, with no name, text, wallet or chain reads
const PROMO = process.env.NEXT_PUBLIC_PROMO === "1";

// The icons come from the app/ file conventions (favicon.ico, icon.svg, apple-icon.png); the share card from pageMeta.
// The promo keeps the name and share image but no description, as its page has no text.
export const metadata: Metadata = {
  metadataBase: new URL(process.env.NEXT_PUBLIC_SITE_URL || "https://apeball.fun"),
  title: PROMO ? collectionMeta.game : { default: collectionMeta.game, template: `%s · ${collectionMeta.game}` },
  applicationName: collectionMeta.game,
  ...pageMeta(undefined, PROMO ? undefined : `Draw from a verifiably random pool of ${collectionMeta.short}s and ETH-backed Shapes on Ethereum.`, "/"),
};

export const viewport: Viewport = { themeColor: "#050608", colorScheme: "dark" };

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <head>
        {PROMO ? null : <>
          <link rel="preconnect" href="https://fonts.googleapis.com" />
          <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="" />
          <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Anton&family=Manrope:wght@500;600;700;800&family=Unbounded:wght@500;700;800&display=swap" />
        </>}
      </head>
      <body>
        {PROMO ? <Promo /> : <Providers>
          <Nav />
          <main>{children}</main>
          <footer className="foot">
            by <a href="https://x.com/ripe0x" target="_blank" rel="noreferrer">ripe</a> · <a href="/docs/">Docs</a> · Built on{" "}
            <a href="https://fwa.fun" target="_blank" rel="noreferrer">FWA custom pools</a><CoinContract />
          </footer>
        </Providers>}
      </body>
    </html>
  );
}
