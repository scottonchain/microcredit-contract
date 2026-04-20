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

// In demo wallet mode the fake window.ethereum provider identifies as MetaMask,
// so we must present the MetaMask connector — the burner wallet ignores
// window.ethereum and would connect with a random address instead of Bob/Charlie.
const isDemoWallet = process.env.NEXT_PUBLIC_DEMO_WALLET === "true";

/**
 * wagmi connectors for the wagmi context
 *
 * - Demo wallet mode: MetaMask connector only (picks up the injected fake provider).
 * - Local dev (default): burner wallet auto-connects to chain 31337.
 * - Production: real wallet connectors (MetaMask, Rabby, Coinbase).
 *
 * Note: WalletConnect requires a valid project ID from https://cloud.walletconnect.com
 * Set NEXT_PUBLIC_WALLET_CONNECT_PROJECT_ID in .env.local for production use
 */
export const wagmiConnectors = connectorsForWallets(
  [
    {
      groupName: "Supported Wallets",
      wallets: isDemoWallet
        ? [metaMaskWallet]                                   // demo: use injected fake provider
        : onlyLocalBurnerWallet && isLocalNetwork
          ? [rainbowkitBurnerWallet]                         // local dev: auto-connect burner
          : [coinbaseWallet, rabbyWallet, metaMaskWallet],   // production: real wallets
    },
    ...(!onlyLocalBurnerWallet || !isLocalNetwork || isDemoWallet
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
