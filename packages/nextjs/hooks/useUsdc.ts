import { useReadContract, useWriteContract } from "wagmi";
import { useTransactor } from "~~/hooks/scaffold-eth";
import { CHAIN_ID, USDC_ABI, USDC_ADDRESS } from "~~/utils/microcredit";

/** USDC balance of `account`, from MockUSDC locally or Circle's USDC on a live chain. */
export const useUsdcBalance = (account?: string, refetchInterval?: number) =>
  useReadContract({
    address: USDC_ADDRESS,
    abi: USDC_ABI,
    functionName: "balanceOf",
    args: account ? [account as `0x${string}`] : undefined,
    chainId: CHAIN_ID,
    query: { enabled: Boolean(account && USDC_ADDRESS), refetchInterval },
  });

/**
 * Sends a USDC `approve` (or `mint`, which only MockUSDC allows) from the connected wallet and
 * waits for it to be mined, with scaffold's transaction notifications.
 */
export const useUsdcWrite = () => {
  const { writeContractAsync } = useWriteContract();
  const transactor = useTransactor();
  return (functionName: "approve" | "mint", args: readonly [`0x${string}`, bigint]) => {
    const token = USDC_ADDRESS;
    if (!token) throw new Error("USDC address is not configured for this chain");
    return transactor(() => writeContractAsync({ address: token, abi: USDC_ABI, functionName, args, chainId: CHAIN_ID }));
  };
};
