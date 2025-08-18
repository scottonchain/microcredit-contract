import { useMemo } from "react";

export function useActiveLoanId(
  borrowerLoanIds: readonly bigint[] | undefined,
  getLoan: (id: bigint) => any | undefined
) {
  return useMemo(() => {
    if (!Array.isArray(borrowerLoanIds) || borrowerLoanIds.length === 0) return undefined;

    // newest → oldest
    const sorted = [...borrowerLoanIds].sort((a, b) => (a > b ? -1 : 1));
    // prefer the first that is active
    for (const id of sorted) {
      const loan = getLoan(id);
      // loan[4] = isActive (bool) by current ABI
      if (loan && (loan as any)[4] === true) return id;
    }
    // fallback to newest id if none marked active (avoids empty UI between state flips)
    return sorted[0];
  }, [borrowerLoanIds, getLoan]);
}
