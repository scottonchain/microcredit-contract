import deployedContracts from "~~/contracts/deployedContracts";
import scaffoldConfig from "~~/scaffold.config";

/** Chain the app targets (local Anvil by default; see scaffold.config.ts). */
export const CHAIN_ID = scaffoldConfig.targetNetworks[0].id;

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
