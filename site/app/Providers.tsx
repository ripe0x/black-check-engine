"use client";

import { useState } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { WagmiProvider } from "wagmi";
import { RainbowKitProvider, darkTheme } from "@rainbow-me/rainbowkit";
import "@rainbow-me/rainbowkit/styles.css";
import { buildConfig } from "./lib/wagmi";
import { deployment } from "./lib/deployment";

const config = buildConfig(deployment.chainId);
// the connect modal in the site's colours and type
const theme = { ...darkTheme({ accentColor: "#1f5bff", accentColorForeground: "#ffffff", borderRadius: "large", overlayBlur: "small" }),
  fonts: { body: "Manrope, ui-sans-serif, system-ui, sans-serif" } };

export function Providers({ children }: { children: React.ReactNode }) {
  const [client] = useState(() => new QueryClient());
  return (
    <WagmiProvider config={config} reconnectOnMount>
      <QueryClientProvider client={client}>
        <RainbowKitProvider theme={theme} modalSize="compact">{children}</RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
