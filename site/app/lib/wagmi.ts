import { createConfig, http } from "wagmi";
import { mainnet } from "wagmi/chains";
import { injected } from "wagmi/connectors";
import { config } from "./config";

// One chain, read through the configured RPC. For a local anvil fork run with `--chain-id 1`, point NEXT_PUBLIC_RPC_URL
// at it (e.g. http://127.0.0.1:8547); the fork keeps mainnet's contract addresses. No key is embedded.
const chain = { ...mainnet, id: config.chainId };

export const wagmiConfig = createConfig({
  chains: [chain],
  connectors: [injected()],
  transports: { [chain.id]: http(config.rpcUrl) },
  ssr: true,
});
