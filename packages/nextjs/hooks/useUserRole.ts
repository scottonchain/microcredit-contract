import { useEffect, useState } from "react";
import { useAccount } from "wagmi";
import { useScaffoldReadContract } from "~~/hooks/scaffold-eth";

/**
 * User role types for the microcredit platform
 * - "borrower": User has active loans
 * - "lender": User has deposits in the lending pool
 * - "both": User has both loans and deposits
 * - "none": User is new or has no active participation
 */
export type UserRole = "borrower" | "lender" | "both" | "none";

/** Classifies the connected address as borrower, lender, both or neither from on-chain state. */
export const useUserRole = () => {
  const { address: connectedAddress } = useAccount();
  const [userRole, setUserRole] = useState<UserRole>("none");
  const [isLoading, setIsLoading] = useState(true);

  // Check if user is a lender (has deposits)
  const { data: lenderDeposit } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "lenderDeposits",
    args: [connectedAddress],
  });

  // Check if user has any loans (is a borrower)
  const { data: borrowerLoanIds } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getBorrowerLoanIds",
    args: [connectedAddress],
  });

  useEffect(() => {
    if (!connectedAddress) {
      setUserRole("none");
      setIsLoading(false);
      return;
    }

    const isLender = lenderDeposit !== undefined && BigInt(lenderDeposit) > 0n;
    const isBorrower = borrowerLoanIds !== undefined && borrowerLoanIds.length > 0;

    if (isBorrower && isLender) {
      setUserRole("both");
    } else if (isBorrower) {
      setUserRole("borrower");
    } else if (isLender) {
      setUserRole("lender");
    } else {
      setUserRole("none");
    }

    setIsLoading(false);
  }, [connectedAddress, lenderDeposit, borrowerLoanIds]);

  return {
    userRole,
    isLoading,
    isBorrower: userRole === "borrower" || userRole === "both",
    isLender: userRole === "lender" || userRole === "both",
  };
}; 