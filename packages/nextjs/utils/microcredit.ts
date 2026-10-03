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
export const USDC_ADDRESS = deployment.MockUSDC?.address as `0x${string}` | undefined;
export const USDC_ABI = deployment.MockUSDC?.abi;
/** OracleScoreProvider ABI. Read its live address from DecentralizedMicrocredit.scoreProvider(). */
export const SCORE_PROVIDER_ABI = deployment.OracleScoreProvider.abi;

/** Raw JSON-RPC endpoint for local-only tooling that calls anvil_* methods directly. */
export const ANVIL_RPC_URL = "http://127.0.0.1:8545";
