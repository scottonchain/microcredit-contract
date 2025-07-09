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
  const lenderCount = poolInfo ? Number(poolInfo[2]) : 0;

  // Interest bounds (rough yield)
  const { data: rMin } = useScaffoldReadContract({ contractName: "DecentralizedMicrocredit", functionName: "rMin" });
  const { data: rMax } = useScaffoldReadContract({ contractName: "DecentralizedMicrocredit", functionName: "rMax" });
  const rMinPct = rMin ? (Number(rMin) / 10000).toFixed(2) : "-";
  const rMaxPct = rMax ? (Number(rMax) / 10000).toFixed(2) : "-";

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
          Current APRs range between <span className="font-semibold">{rMinPct}% – {rMaxPct}%</span>.
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