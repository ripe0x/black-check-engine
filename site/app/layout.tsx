import type { Metadata } from "next";
import "./globals.css";
import { Providers } from "./Providers";
import { Nav } from "./components/Nav";
import { TestBanner } from "./components/TestBanner";
import { config } from "./lib/config";

export const metadata: Metadata = {
  title: `${config.projectName} — test build`,
  description: "Play a paid random draw for Checks NFTs, compose survivors, and buy them out. Unaudited test build.",
};

export const viewport = { width: "device-width", initialScale: 1 };

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>
          <TestBanner />
          <Nav />
          <main>{children}</main>
          <footer className="foot">
            {config.projectName} · Wins are random · Odds change with inventory · Listed notionals are game values, not
            resale prices · Buying a Check is not winning it · No independent audit has been done · Terms are a
            placeholder and out of scope for this build.
          </footer>
        </Providers>
      </body>
    </html>
  );
}
