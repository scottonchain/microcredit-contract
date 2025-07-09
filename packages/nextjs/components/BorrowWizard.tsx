import { useState } from "react";
import Link from "next/link";
import { CreditCardIcon, CalculatorIcon } from "@heroicons/react/24/outline";
import { useScaffoldReadContract } from "~~/hooks/scaffold-eth";
import { formatUSDC } from "~~/utils/format";
import QRCodeDisplay from "./QRCodeDisplay";

interface BorrowWizardProps {
  connectedAddress?: `0x${string}`;
}

const BorrowWizard: React.FC<BorrowWizardProps> = ({ connectedAddress }) => {
  // Fetch credit score (proxy for attestations)
  const { data: creditScore } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getPageRankScore",
    args: [connectedAddress],
  });

  const scoreNumeric = creditScore ? Number(creditScore) : 0;
  const hasAttestations = scoreNumeric > 0;

  // Interest rate bounds (for explanatory copy only)
  const { data: rMin } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "rMin",
  });
  const { data: rMax } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "rMax",
  });

  const rMinPct = rMin ? (Number(rMin) / 10000).toFixed(2) : "-";
  const rMaxPct = rMax ? (Number(rMax) / 10000).toFixed(2) : "-";

  // Loan simulation state (shown once user has attestations)
  const [amount, setAmount] = useState("");
  const [repaymentDays, setRepaymentDays] = useState(365); // default 1yr

  const { data: previewTerms } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "previewLoanTerms",
    args: [
      connectedAddress,
      connectedAddress && amount ? BigInt(Math.floor(parseFloat(amount) * 1e6)) : undefined,
      connectedAddress && amount ? BigInt(repaymentDays * 24 * 60 * 60) : undefined,
    ],
  });

  const attestationUrl = connectedAddress
    ? `${window.location.origin}/attest?borrower=${connectedAddress}&weight=80`
    : "";

  const copyLink = () => {
    if (!attestationUrl) return;
    navigator.clipboard.writeText(attestationUrl);
    alert("Attestation link copied!");
  };

  const { writeContractAsync } = useScaffoldReadContract as any;
  // wait need import useScaffoldWriteContract

  return (
    <div className="bg-base-100 rounded-lg p-6 shadow-lg">
      <h3 className="text-lg font-semibold mb-4 flex items-center">
        <CreditCardIcon className="h-5 w-5 mr-2" />
        Request a Loan
      </h3>

      {!hasAttestations ? (
        <div className="text-sm text-gray-700 space-y-4">
          <p>
            You currently have <span className="font-semibold">no attestations</span>. To become eligible for a loan (rates
            typically range between {rMinPct}% and {rMaxPct}% APR) share your attestation link with trusted peers.
          </p>
          <div className="flex flex-col items-center space-y-3">
            <QRCodeDisplay value={attestationUrl} size={128} />
            <button onClick={copyLink} className="btn btn-secondary btn-sm">
              Copy Attestation Link
            </button>
          </div>
        </div>
      ) : (
        <div className="space-y-6">
          {/* Amount */}
          <div>
            <label className="block text-sm font-medium mb-1">Amount (USDC)</label>
            <input
              type="number"
              value={amount}
              onChange={e => setAmount(e.target.value)}
              placeholder="e.g. 1000"
              className="w-full p-2 border border-gray-300 rounded-lg"
              min="1"
            />
          </div>

          {/* Repayment period */}
          <div>
            <label className="block text-sm font-medium mb-1">Repayment Period</label>
            <select
              value={repaymentDays}
              onChange={e => setRepaymentDays(Number(e.target.value))}
              className="w-full p-2 border border-gray-300 rounded-lg"
            >
              <option value={30}>1 Month</option>
              <option value={90}>3 Months</option>
              <option value={180}>6 Months</option>
              <option value={365}>1 Year</option>
              <option value={730}>2 Years</option>
            </select>
          </div>

          {/* Preview */}
          {amount && previewTerms && (
            <div className="bg-base-200 p-4 rounded-lg text-sm">
              <h4 className="font-medium mb-2 flex items-center">
                <CalculatorIcon className="h-4 w-4 mr-1" /> Loan Preview
              </h4>
              <div className="grid grid-cols-2 gap-2">
                <div>
                  <span className="text-gray-600">Interest Rate:</span>
                  <div className="font-semibold">{(Number(previewTerms[0]) / 10000).toFixed(2)}% APR</div>
                </div>
                <div>
                  <span className="text-gray-600">Monthly Payment:</span>
                  <div className="font-semibold">
                    {formatUSDC(previewTerms[1])} USDC
                  </div>
                </div>
              </div>
            </div>
          )}

          {/* Proceed */}
          <Link
            href={`/borrower${amount ? `?amount=${amount}&period=${repaymentDays}` : ""}`}
            className="btn btn-primary w-full"
          >
            Go to Borrow Page
          </Link>
        </div>
      )}
    </div>
  );
};

export default BorrowWizard; 