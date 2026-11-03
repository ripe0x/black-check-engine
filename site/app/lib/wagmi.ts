import { createConfig, fallback, http } from "wagmi";
import type { Chain } from "viem";
import { connectorsForWallets } from "@rainbow-me/rainbowkit";
import { coinbaseWallet, injectedWallet, metaMaskWallet, rainbowWallet, walletConnectWallet } from "@rainbow-me/rainbowkit/wallets";
import { mainnet, sepolia, foundry } from "wagmi/chains";

// `NEXT_PUBLIC_RPC_URL` is an optional primary ahead of public endpoints. No key is embedded in the bundle.
const primary = process.env.NEXT_PUBLIC_RPC_URL?.trim();
const rpcs = (urls: string[]) => fallback([...(primary ? [primary] : []), ...urls].map((u) => http(u)));

/** A local node: anvil on its default port, with anvil's chain id. */
export const anvil = { ...foundry, id: 31337, name: "Anvil" } as const;

/** The deployment's chain, and nothing else: no read or transaction can go to another network. */
export const chainOf = (chainId: number) => (chainId === anvil.id ? anvil : chainId === sepolia.id ? sepolia : mainnet);

// RainbowKit's wallet list. Mobile and QR wallets go through WalletConnect, which needs a (public) project id from
// WalletConnect Cloud; without one only the browser's injected wallet is offered.
const projectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID?.trim();
const connectors = connectorsForWallets(
  [{ groupName: "Wallets", wallets: projectId ? [rainbowWallet, metaMaskWallet, coinbaseWallet, walletConnectWallet, injectedWallet] : [injectedWallet] }],
  { appName: "ApeBall", projectId: projectId || "unset" },
);

export function buildConfig(chainId: number) {
  const chain: Chain = chainOf(chainId);
  return createConfig({
    chains: [chain],
    connectors,
    transports: {
      [chain.id]: chain.id === anvil.id ? http("http://127.0.0.1:8545")
        : chain.id === sepolia.id ? rpcs(["https://ethereum-sepolia-rpc.publicnode.com"])
          : rpcs(["https://ethereum-rpc.publicnode.com", "https://eth.drpc.org"]),
    },
    ssr: true,
  });
}
