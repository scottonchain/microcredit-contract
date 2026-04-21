'use client';

import React, { createContext, useContext } from "react";
import { useAccount } from "wagmi";
import { useScaffoldReadContract } from "~~/hooks/scaffold-eth";

interface DisplayNameCtx {
  /** On-chain display name for the connected wallet, or empty string if unset. */
  displayName: string;
}

const Ctx = createContext<DisplayNameCtx>({ displayName: "" });

export const DisplayNameProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const { address } = useAccount();

  const { data: nameData } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "displayNames",
    args: [address as `0x${string}`],
    query: { enabled: Boolean(address) },
  });

  return (
    <Ctx.Provider value={{ displayName: nameData || "" }}>
      {children}
    </Ctx.Provider>
  );
};

export const useDisplayName = () => useContext(Ctx);
