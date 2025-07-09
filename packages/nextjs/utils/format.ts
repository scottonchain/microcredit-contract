export const formatUSDC = (amount?: bigint): string => {
  if (!amount) return "$0.00";
  return `$${(Number(amount) / 1e6).toFixed(2)}`;
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