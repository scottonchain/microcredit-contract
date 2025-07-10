import { BanknotesIcon } from "@heroicons/react/24/outline";
import Link from "next/link";
import { useScaffoldReadContract } from "~~/hooks/scaffold-eth";
import { formatUSDC } from "~~/utils/format";

interface LendWizardProps {
  connectedAddress?: `0x${string}`;
}

const LendWizard: React.FC<LendWizardProps> = ({ connectedAddress }) => {
  // Pool info (for yield estimation)
  const { data: poolInfo } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getPoolInfo",
  });
  const totalDeposits = poolInfo ? Number(poolInfo[0]) : 0;
  const lenderCount = poolInfo ? Number(poolInfo[3]) : 0;

  // Interest bounds (rough yield)
  const { data: effrRate } = useScaffoldReadContract({ contractName: "DecentralizedMicrocredit", functionName: "effrRate" as any });
  const { data: riskPremium } = useScaffoldReadContract({ contractName: "DecentralizedMicrocredit", functionName: "riskPremium" as any });
  const totalRateBp = effrRate && riskPremium ? Number(effrRate) + Number(riskPremium) : undefined;
  const totalRatePct = totalRateBp !== undefined ? (totalRateBp / 100).toFixed(2) : "-";
  const effrPct = effrRate !== undefined ? (Number(effrRate) / 100).toFixed(2) : "-";

  // NOTE: Contract does not expose per-lender balances yet. We only show pool stats and APR range.

  return (
    <div className="bg-base-100 rounded-lg p-6 shadow-lg">
      <h3 className="text-lg font-semibold mb-4 flex items-center">
        <BanknotesIcon className="h-5 w-5 mr-2" />
        Earn Interest
      </h3>

      <div className="space-y-4 text-sm text-gray-700">
        <p>
          Earn passive yield by depositing USDC into the shared pool. Funds are matched to borrowers automatically.
          {/* Base Rate display */}
          <br />
          Base Rate (EFFR): <span className="font-semibold">{effrPct}%</span>
          <span
            className="tooltip tooltip-bottom ml-1"
            data-tip="This rate is currently set manually for testing but will be sourced from Pyth Network in production."
          >
            ℹ️
          </span>
          <br />
          Platform APR (Base + Premium): <span className="font-semibold">{totalRatePct}%</span>
        </p>
        <p>
          Pool size: <span className="font-semibold">{formatUSDC(BigInt(totalDeposits))}</span> • Active lenders: {lenderCount}
        </p>
        <Link href={connectedAddress ? `/lender?address=${connectedAddress}` : "/lender"} className="btn btn-primary w-full">
          {connectedAddress ? "Open Your Lender Dashboard" : "Open Lender Dashboard"}
        </Link>
      </div>
    </div>
  );
};

export default LendWizard; 