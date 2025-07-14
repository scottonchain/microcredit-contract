'use client';

import { useState } from "react";
import { createWalletClient, http, encodeFunctionData } from "viem";
import { hardhat } from "viem/chains";
import { useAccount } from "wagmi";
import { BanknotesIcon } from "@heroicons/react/24/outline";
import { useScaffoldReadContract, useTransactor } from "~~/hooks/scaffold-eth";

const FAUCET_ADDRESS = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"; // Anvil default deployer
const NUM_USDC = 10000n * 1000000n; // 10,000 USDC (6 decimals)

const localWalletClient = createWalletClient({
  chain: hardhat,
  transport: http(),
});

const usdcAbi = [
  {
    inputs: [
      { internalType: "address", name: "to", type: "address" },
      { internalType: "uint256", name: "amount", type: "uint256" },
    ],
    name: "mint",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
] as const;

export const USDCFaucetButton = () => {
  const { address, chain: connectedChain } = useAccount();

  // Get deployed USDC address from the microcredit contract
  const { data: usdcAddress } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "usdc" as any,
  });

  const faucetTxn = useTransactor(localWalletClient);
  const [loading, setLoading] = useState(false);

  const sendUSDC = async () => {
    if (!address || !usdcAddress) return;
    try {
      setLoading(true);
      await faucetTxn({
        account: FAUCET_ADDRESS,
        // @ts-ignore – address read from contract returns `0x` string at runtime
        to: usdcAddress,
        data: encodeFunctionData({
          abi: usdcAbi,
          functionName: "mint",
          args: [address, NUM_USDC],
        }),
      });
    } catch (err) {
      console.error("USDC faucet error", err);
    } finally {
      setLoading(false);
    }
  };

  if (connectedChain?.id !== hardhat.id) return null;

  return (
    <button className="btn btn-secondary btn-sm px-2 rounded-full ml-1 w-20" onClick={sendUSDC} disabled={loading || !usdcAddress}>
      {!loading ? (
        <>
          <BanknotesIcon className="h-4 w-4 mr-1" />
          <span className="text-[10px] font-semibold">USDC</span>
        </>
      ) : (
        <span className="loading loading-spinner loading-xs"></span>
      )}
    </button>
  );
}; 