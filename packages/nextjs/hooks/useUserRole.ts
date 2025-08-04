import { useAccount } from "wagmi";
import { useScaffoldReadContract } from "./scaffold-eth";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { AUTO_REDIRECT_CONFIG } from "~~/config/autoRedirect";

/**
 * User role types for the microcredit platform
 * - "borrower": User has active loans
 * - "lender": User has deposits in the lending pool
 * - "both": User has both loans and deposits
 * - "none": User is new or has no active participation
 */
export type UserRole = "borrower" | "lender" | "both" | "none";

/**
 * Custom hook to determine user role and provide redirection functionality
 * 
 * This hook checks if the connected address is:
 * - A borrower (has active loans)
 * - A lender (has deposits)
 * - Both borrower and lender
 * - Neither (new user)
 * 
 * It provides utilities for automatic redirection to appropriate pages
 * based on the user's role.
 */
export const useUserRole = () => {
  const { address: connectedAddress } = useAccount();
  const router = useRouter();
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

  const redirectToAppropriatePage = () => {
    if (!connectedAddress || isLoading) return;

    switch (userRole) {
      case "borrower":
        router.push(AUTO_REDIRECT_CONFIG.redirectPages.borrower);
        break;
      case "lender":
        router.push(AUTO_REDIRECT_CONFIG.redirectPages.lender);
        break;
      case "both":
        // Use configured default page for users with both roles
        const defaultPage = AUTO_REDIRECT_CONFIG.redirectPages[AUTO_REDIRECT_CONFIG.defaultPageForBoth];
        router.push(defaultPage);
        break;
      case "none":
        // Stay on current page (likely home page)
        break;
    }
  };

  return {
    userRole,
    isLoading,
    isBorrower: userRole === "borrower" || userRole === "both",
    isLender: userRole === "lender" || userRole === "both",
    redirectToAppropriatePage,
  };
}; 