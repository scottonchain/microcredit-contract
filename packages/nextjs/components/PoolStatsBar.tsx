"use client";

import Link from "next/link";
import { useScaffoldReadContract } from "~~/hooks/scaffold-eth";

/**
 * Slim info bar rendered on every page (placed between Header and main content).
 * Shows the total lending pool size and current lender APY so visitors can
 * see the pool health at a glance without navigating to /lend.
 */
export const PoolStatsBar = () => {
  const { data: poolInfo } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getPoolInfo",
  });

  const { data: poolApyBp } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getFundingPoolAPY",
  });

  const totalDeposits = poolInfo ? poolInfo[0] : undefined;
  const availableFunds = poolInfo ? poolInfo[1] : undefined;

  const poolTotal =
    totalDeposits !== undefined
      ? `$${(Number(totalDeposits) / 1e6).toLocaleString("en-US", {
          minimumFractionDigits: 2,
          maximumFractionDigits: 2,
        })} USDC`
      : "—";

  const poolAvailable =
    availableFunds !== undefined
      ? `$${(Number(availableFunds) / 1e6).toLocaleString("en-US", {
          minimumFractionDigits: 2,
          maximumFractionDigits: 2,
        })} USDC`
      : "—";

  const apyDisplay =
    poolApyBp !== undefined ? `${(Number(poolApyBp) / 100).toFixed(2)}%` : "—";

  return (
    <div className="bg-base-200 border-b border-base-300 text-xs px-4 py-1.5 flex items-center justify-center gap-5 flex-wrap">
      <span className="text-base-content/60 font-medium">Lending Pool</span>
      <span className="flex items-center gap-1.5">
        <span className="text-base-content/50">Total:</span>
        <span className="font-semibold text-blue-600 dark:text-blue-400">{poolTotal}</span>
      </span>
      <span className="text-base-content/30">·</span>
      <span className="flex items-center gap-1.5">
        <span className="text-base-content/50">Available:</span>
        <span className="font-semibold text-blue-500 dark:text-blue-300">{poolAvailable}</span>
      </span>
      <span className="text-base-content/30">·</span>
      <span className="flex items-center gap-1.5">
        <span className="text-base-content/50">Lender APY:</span>
        <span className="font-semibold text-green-600 dark:text-green-400">{apyDisplay}</span>
      </span>
      <Link
        href="/lend"
        className="text-blue-500 hover:text-blue-700 underline underline-offset-2 ml-1"
      >
        Deposit →
      </Link>
    </div>
  );
};
