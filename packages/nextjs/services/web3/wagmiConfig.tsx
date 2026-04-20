import { wagmiConnectors } from "./wagmiConnectors";
import { Chain, createClient, fallback, http } from "viem";
import { hardhat } from "viem/chains";
import { createConfig } from "wagmi";
import scaffoldConfig, { DEFAULT_ALCHEMY_API_KEY, ScaffoldConfig } from "~~/scaffold.config";
import { getAlchemyHttpUrl } from "~~/utils/scaffold-eth";

const { targetNetworks } = scaffoldConfig;

// Only use the configured target networks — mainnet is not needed since ETH price
// fetching and ENS resolution have been removed from this project.
export const enabledChains = targetNetworks as unknown as readonly [Chain, ...Chain[]];

export const wagmiConfig = createConfig({
  chains: enabledChains,
  connectors: wagmiConnectors,
  ssr: true,
  client({ chain }) {
    const isLocal = chain.id === (hardhat as Chain).id;

    // For the local Anvil chain use a short timeout and no retries so that
    // "node not running" errors fail fast instead of spamming the console
    // with repeated NetworkError / TimeoutError messages.
    const localHttpOpts = isLocal ? { timeout: 2_000, retryCount: 0 } : {};

    let rpcFallbacks = [http(undefined, localHttpOpts)];

    const rpcOverrideUrl = (scaffoldConfig.rpcOverrides as ScaffoldConfig["rpcOverrides"])?.[chain.id];
    if (rpcOverrideUrl) {
      rpcFallbacks = [http(rpcOverrideUrl, localHttpOpts), http(undefined, localHttpOpts)];
    } else {
      const alchemyHttpUrl = getAlchemyHttpUrl(chain.id);
      if (alchemyHttpUrl) {
        const isUsingDefaultKey = scaffoldConfig.alchemyApiKey === DEFAULT_ALCHEMY_API_KEY;
        rpcFallbacks = isUsingDefaultKey
          ? [http(undefined, localHttpOpts), http(alchemyHttpUrl)]
          : [http(alchemyHttpUrl), http(undefined, localHttpOpts)];
      }
    }

    return createClient({
      chain,
      transport: fallback(rpcFallbacks),
      ...(!isLocal ? { pollingInterval: scaffoldConfig.pollingInterval } : {}),
    });
  },
});
