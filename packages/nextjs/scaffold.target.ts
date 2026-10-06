import * as chains from "viem/chains";

/**
 * The one chain this build targets. It is a literal so that the contract types follow it: every ABI,
 * address and chain id in the app comes from contracts/deployedContracts.ts for exactly this chain.
 *
 * The checked-in value is the local Anvil chain (31337) for development, the demo and CI. The static
 * export for the live Base Sepolia pool (scripts/build-static.sh) swaps this file for the Base Sepolia
 * chain (84532) for the duration of the build and restores it afterwards.
 */
export const TARGET_CHAIN = chains.foundry;
