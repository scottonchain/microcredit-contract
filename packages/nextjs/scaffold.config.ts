import * as chains from "viem/chains";
import { TARGET_CHAIN } from "./scaffold.target";

export type ScaffoldConfig = {
  targetNetworks: readonly chains.Chain[];
  pollingInterval: number;
  alchemyApiKey: string;
  rpcOverrides?: Record<number, string>;
  walletConnectProjectId: string;
  onlyLocalBurnerWallet: boolean;
};

export const DEFAULT_ALCHEMY_API_KEY = "oKxs-03sij-U_N0iOlrSsZFr29-IqbuF";

/** True when this build targets the local Anvil chain (see scaffold.target.ts). */
const targetIsLocal = (TARGET_CHAIN.id as number) === chains.foundry.id;

const scaffoldConfig = {
  // The network on which your DApp is live: one chain, fixed per build (scaffold.target.ts)
  targetNetworks: [TARGET_CHAIN],

  // The interval at which your front-end polls the RPC servers for new data
  // it has no effect if you only target the local network (default is 4000)
  pollingInterval: 30000,

  // This is ours Alchemy's default API key.
  // You can get your own at https://dashboard.alchemyapi.io
  // It's recommended to store it in an env variable:
  // .env.local for local testing, and in the Vercel/system env config for live apps.
  alchemyApiKey: process.env.NEXT_PUBLIC_ALCHEMY_API_KEY || DEFAULT_ALCHEMY_API_KEY,

  // If you want to use a different RPC for a specific network, you can add it here.
  // The key is the chain ID, and the value is the HTTP RPC URL
  rpcOverrides: {
    // Base Sepolia: the public endpoint unless NEXT_PUBLIC_RPC_URL_84532 names another at build time.
    [chains.baseSepolia.id]: process.env.NEXT_PUBLIC_RPC_URL_84532 || "https://sepolia.base.org",
  },

  // This is ours WalletConnect's default project ID.
  // You can get your own at https://cloud.walletconnect.com
  // It's recommended to store it in an env variable:
  // .env.local for local testing, and in the Vercel/system env config for live apps.
  walletConnectProjectId: process.env.NEXT_PUBLIC_WALLET_CONNECT_PROJECT_ID || "c4f79cc821944d9680842e34466bfbd9",

  // Only show the Burner Wallet when running on the local chain
  onlyLocalBurnerWallet: targetIsLocal,
} as const satisfies ScaffoldConfig;

export default scaffoldConfig;
