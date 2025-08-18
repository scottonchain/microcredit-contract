"use client";
import { useAccount } from "wagmi";
import { useScaffoldReadContract } from "~~/hooks/scaffold-eth";
import { isWhitelisted } from "~~/utils/isAdmin";

export function useIsAdmin() {
  const { address } = useAccount();
  const me = address?.toLowerCase();

  const { data: owner, isLoading: ownerLoading } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "owner",
  });

  const { data: oracle, isLoading: oracleLoading } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "oracle",
  });

  const loading = ownerLoading || oracleLoading;

  const isOwner = !!me && !!owner && me === owner.toLowerCase();
  const isOracle = !!me && !!oracle && me === oracle.toLowerCase();
  const admin = isOwner || isOracle || isWhitelisted(me);

  return { admin, loading, address, owner, oracle } as const;
}
