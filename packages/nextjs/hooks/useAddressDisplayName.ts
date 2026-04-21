"use client";

import { useScaffoldReadContract } from "~~/hooks/scaffold-eth";

/**
 * Reads the on-chain display name for any address.
 * Returns the name string if set, or undefined if the address has no name.
 */
export function useAddressDisplayName(address: string | undefined): string | undefined {
  const { data } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "displayNames",
    args: [address as `0x${string}`],
    query: { enabled: Boolean(address) },
  });
  return data || undefined;
}
