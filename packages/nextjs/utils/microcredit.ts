import deployedContracts from "~~/contracts/deployedContracts";
import scaffoldConfig from "~~/scaffold.config";

/** Chain the app targets (local Anvil by default; see scaffold.config.ts). */
export const CHAIN_ID = scaffoldConfig.targetNetworks[0].id;

/**
 * Whether the gasless relayer routes (app/api/meta/*) exist in this build. A static export has no server, so
 * it is built with NEXT_PUBLIC_RELAYER_DISABLED=true and every page falls back to wallet-direct calls: the
 * user pays gas and signs each transaction. Only the withdrawal queue has no wallet-direct form.
 */
export const RELAYER_ENABLED = process.env.NEXT_PUBLIC_RELAYER_DISABLED !== "true";

/** The live Base Sepolia pool this app is built against when CHAIN_ID is 84532 (docs/TESTNET.md). */
export const LIVE_DEPLOYMENT = {
  chainId: 84532,
  chainName: "Base Sepolia",
  deployedCommit: "19b166e",
  explorer: "https://sepolia.basescan.org",
} as const;
export const IS_LIVE_TESTNET = (CHAIN_ID as number) === LIVE_DEPLOYMENT.chainId;
/** The commit this front end was built from, stamped at build time (scripts/build-static.sh). */
export const BUILD_COMMIT = process.env.NEXT_PUBLIC_BUILD_COMMIT ?? "";
/** Path prefix when the static export is served under a sub-path (GitHub Pages project site); "" otherwise. */
export const BASE_PATH = process.env.NEXT_PUBLIC_BASE_PATH ?? "";

const deployment = deployedContracts[CHAIN_ID];

export const MICROCREDIT_ADDRESS = deployment.DecentralizedMicrocredit.address as `0x${string}`;
export const MICROCREDIT_ABI = deployment.DecentralizedMicrocredit.abi;
/** MicrocreditLens: read-only views derived from the pool's state (kept out of the pool for size). */
export const LENS_ADDRESS = deployment.MicrocreditLens.address as `0x${string}`;
export const LENS_ABI = deployment.MicrocreditLens.abi;

/** Circle's USDC where the pool may run on it; checked on-chain (name "USDC", permit version "2"). */
const CIRCLE_USDC: Partial<Record<number, `0x${string}`>> = {
  84532: "0x036CbD53842c5426634e7929541eC2318f3dCF7e", // Base Sepolia
};
const mockUsdc = (deployment as { MockUSDC?: { address: string } }).MockUSDC;
/** True when the pool runs on the free-mint MockUSDC (local and demo deployments). */
export const IS_MOCK_USDC = mockUsdc !== undefined;
/**
 * The pool's token: the MockUSDC our scripts deployed, else NEXT_PUBLIC_USDC_ADDRESS, else Circle's
 * USDC for the chain. It must equal the pool's `usdc()`.
 */
export const USDC_ADDRESS = (mockUsdc?.address ?? process.env.NEXT_PUBLIC_USDC_ADDRESS ?? CIRCLE_USDC[CHAIN_ID]) as
  | `0x${string}`
  | undefined;
export { USDC_ABI } from "./usdcAbi";
/** OracleScoreProvider ABI. Read its live address from DecentralizedMicrocredit.scoreProvider(). */
export const SCORE_PROVIDER_ABI = deployment.OracleScoreProvider.abi;

/** Raw JSON-RPC endpoint for local-only tooling that calls anvil_* methods directly. */
export const ANVIL_RPC_URL = "http://127.0.0.1:8545";
