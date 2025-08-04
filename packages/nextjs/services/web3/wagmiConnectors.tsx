import { connectorsForWallets } from "@rainbow-me/rainbowkit";
import {
  coinbaseWallet,
  metaMaskWallet,
  rabbyWallet,
} from "@rainbow-me/rainbowkit/wallets";
import * as chains from "viem/chains";
import scaffoldConfig from "~~/scaffold.config";



const { onlyLocalBurnerWallet, targetNetworks } = scaffoldConfig;

// Create wallets array with only the three specified wallets
const createWallets = () => {
  return [
    coinbaseWallet,
    rabbyWallet,
    metaMaskWallet,
  ];
};

const wallets = createWallets();

/**
 * wagmi connectors for the wagmi context
 * 
 * Note: WalletConnect requires a valid project ID from https://cloud.walletconnect.com
 * Set NEXT_PUBLIC_WALLET_CONNECT_PROJECT_ID in .env.local for production use
 */
export const wagmiConnectors = connectorsForWallets(
  [
    {
      groupName: "Supported Wallets",
      wallets,
    },
  ],

  {
    appName: "LoanLink",
    projectId: scaffoldConfig.walletConnectProjectId,
  },
);
