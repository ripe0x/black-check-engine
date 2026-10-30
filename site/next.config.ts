import type { NextConfig } from "next";

// Static export: every page is a client page that reads the chain directly, so the site needs no server and holds no
// secret. It is built locally only; this is a test build and nothing is published or deployed.
const nextConfig: NextConfig = {
  output: "export",
  trailingSlash: true,
  images: { unoptimized: true },
  reactStrictMode: true,
};

export default nextConfig;
