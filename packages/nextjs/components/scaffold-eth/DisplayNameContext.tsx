'use client';

import React, { createContext, useContext } from "react";
import { useAccount } from "wagmi";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";

interface DisplayNameCtx {
  /** On-chain display name for the connected wallet, or empty string if unset. */
  displayName: string;
  /** Write a new display name to the contract (sends a transaction). */
  setDisplayName: (name: string) => Promise<void>;
}

const Ctx = createContext<DisplayNameCtx>({ displayName: "", setDisplayName: async () => {} });

export const DisplayNameProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const { address } = useAccount();

  const { data: nameData } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "displayNames",
    args: [address as `0x${string}`],
    query: { enabled: Boolean(address) },
  });

  const { writeContractAsync } = useScaffoldWriteContract("DecentralizedMicrocredit");

  const setDisplayName = async (name: string) => {
    await writeContractAsync({ functionName: "setDisplayName", args: [name] });
  };

  return (
    <Ctx.Provider value={{ displayName: nameData || "", setDisplayName }}>
      {children}
    </Ctx.Provider>
  );
};

export const useDisplayName = () => useContext(Ctx);
