import type { NextConfig } from "next";

// A static export: every page is a client page reading the chain directly, and the deployment record is bundled at
// build time, so the site needs no server and holds no secret. It is built locally only; nothing is published.
const nextConfig: NextConfig = {
  output: "export",
  trailingSlash: true,
  images: { unoptimized: true },
  reactStrictMode: true,
  serverExternalPackages: ["@coinbase/cdp-sdk", "@base-org/account"],
};

export default nextConfig;
