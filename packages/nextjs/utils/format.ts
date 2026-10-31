export const formatUSDC = (amount?: bigint): string => {
  if (!amount) return "$0.00";
  return `$${(Number(amount) / 1e6).toFixed(2)}`;
};

/**
 * Format a USDC allowance value.  When users approve the maximum uint256 the
 * raw number (≈1.1579e71) is meaningless – display “Unlimited” instead.
 */
export const formatUSDCAllowance = (amount?: bigint): string => {
  if (!amount) return "$0.00";

  // 2^256 - 1 (max uint256) -> treat as unlimited approval
  const MAX_UINT256 = BigInt("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");

  if (amount === MAX_UINT256 || amount > MAX_UINT256 / 2n) {
    return "Unlimited";
  }

  return formatUSDC(amount);
};

export const getCreditScoreColor = (score: number): string => {
  if (score < 30) return "text-red-500";
  if (score < 50) return "text-orange-500";
  if (score < 70) return "text-yellow-500";
  if (score < 90) return "text-blue-500";
  return "text-green-500";
};

export const formatPercent = (value: number, decimals: number = 2): string =>
  `${value.toFixed(decimals)}%`; 

/** Exact USDC with up to six decimals and no rounding, for sub-cent balances that `formatUSDC` would show as $0.00. */
export const formatUSDCExact = (amount: bigint): string => {
  const whole = amount / 1_000_000n;
  const frac = (amount % 1_000_000n).toString().padStart(6, "0").replace(/0+$/, "");
  return `$${whole.toString()}.${frac.padEnd(2, "0")}`;
};
