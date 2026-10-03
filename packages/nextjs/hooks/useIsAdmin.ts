"use client";
import { useEffect, useState } from "react";
import { useAccount } from "wagmi";
import { useScaffoldReadContract } from "~~/hooks/scaffold-eth";
import { isWhitelisted } from "~~/utils/isAdmin";

export function useIsAdmin() {
  const { address, status } = useAccount();
  const me = address?.toLowerCase();

  const { data: owner } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "owner",
  });

  const { data: oracle } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "oracle",
  });

  const isOwner = !!me && !!owner && me === owner.toLowerCase();
  const isOracle = !!me && !!oracle && me === oracle.toLowerCase();
  const admin = isOwner || isOracle || isWhitelisted(me);

  // Unknown until the wallet has settled and both reads have returned. Before mount (the server
  // render and the first client render) wagmi reports "disconnected" without having tried to
  // reconnect yet. A read that is still disabled (contract address not resolved yet) reports
  // isLoading false with no data, so missing data, not isLoading, marks it as unresolved.
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);
  const walletSettling = !mounted || status === "connecting" || status === "reconnecting";
  const readsPending = owner === undefined || oracle === undefined;
  const loading = !admin && (walletSettling || (status === "connected" && readsPending));

  return { admin, loading, address, owner, oracle } as const;
}
