import { connectorsForWallets } from "@rainbow-me/rainbowkit";
import {
  coinbaseWallet,
  metaMaskWallet,
  rabbyWallet,
} from "@rainbow-me/rainbowkit/wallets";
import { rainbowkitBurnerWallet } from "burner-connector";
import * as chains from "viem/chains";
import scaffoldConfig from "~~/scaffold.config";

const { onlyLocalBurnerWallet, targetNetworks } = scaffoldConfig;

const isLocalNetwork = targetNetworks.some(
  n => n.id === chains.hardhat.id || n.id === chains.foundry.id,
);

/**
 * wagmi connectors for the wagmi context
 *
 * Includes the burner wallet on local networks so the app auto-connects
 * to chain 31337 without requiring MetaMask to be manually switched.
 *
 * Note: WalletConnect requires a valid project ID from https://cloud.walletconnect.com
 * Set NEXT_PUBLIC_WALLET_CONNECT_PROJECT_ID in .env.local for production use
 */
export const wagmiConnectors = connectorsForWallets(
  [
    {
      groupName: "Supported Wallets",
      wallets: onlyLocalBurnerWallet && isLocalNetwork
        ? [rainbowkitBurnerWallet]
        : [coinbaseWallet, rabbyWallet, metaMaskWallet],
    },
    ...(!onlyLocalBurnerWallet || !isLocalNetwork
      ? []
      : [
          {
            groupName: "Other Wallets",
            wallets: [coinbaseWallet, rabbyWallet, metaMaskWallet],
          },
        ]),
  ],
  {
    appName: "LoanLink",
    projectId: scaffoldConfig.walletConnectProjectId,
  },
);
