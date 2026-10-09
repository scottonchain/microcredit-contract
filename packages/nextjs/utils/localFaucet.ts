import { USDC_ABI } from "./usdcAbi.ts";
import { type Address, createTestClient, http, publicActions, walletActions } from "viem";
import { foundry } from "viem/chains";

export const LOCAL_ETH_AMOUNT = 10n ** 18n;
export const LOCAL_USDC_AMOUNT = 10_000n * 1_000_000n;

export function createLocalFaucetClient(rpcUrl: string) {
  return createTestClient({ chain: foundry, mode: "anvil", transport: http(rpcUrl) })
    .extend(publicActions)
    .extend(walletActions);
}

type FaucetClient = ReturnType<typeof createLocalFaucetClient>;

async function requireLocalChain(client: FaucetClient, configuredChainId: number) {
  if (configuredChainId !== foundry.id || (await client.getChainId()) !== foundry.id) {
    throw new Error("The faucet requires both the app and RPC to use local Anvil (31337).");
  }
}

export async function fundLocalEth(client: FaucetClient, configuredChainId: number, address: Address) {
  await requireLocalChain(client, configuredChainId);
  const balance = await client.getBalance({ address });
  await client.setBalance({ address, value: balance + LOCAL_ETH_AMOUNT });
}

export async function mintLocalUsdc(client: FaucetClient, configuredChainId: number, address: Address, token: Address) {
  await requireLocalChain(client, configuredChainId);
  const [account] = await client.getAddresses();
  if (!account) throw new Error("Anvil has no unlocked account to mint the local token.");
  const hash = await client.writeContract({
    account,
    address: token,
    abi: USDC_ABI,
    functionName: "mint",
    args: [address, LOCAL_USDC_AMOUNT],
  });
  const receipt = await client.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error("The local USDC mint reverted.");
}
