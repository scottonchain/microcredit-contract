import React from "react";
import Link from "next/link";
import { CreditCardIcon } from "@heroicons/react/24/outline";
import { useScaffoldReadContract } from "~~/hooks/scaffold-eth";
import { useBalance } from "wagmi";
// Removed loan preview utilities

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

  // Balances
  const { data: ethBalance } = useBalance({ address: connectedAddress });

  const { data: usdcAddress } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "usdc",
  });

  const { data: usdcBalance } = useBalance({
    address: connectedAddress,
    token: (usdcAddress as `0x${string}`) || undefined,
    query: { enabled: Boolean(usdcAddress) },
  });

  // Interest rate bounds (for explanatory copy only)
  const { data: effrRate } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "effrRate" as any,
  });
  const { data: riskPremium } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "riskPremium" as any,
  });

  const totalRateBp = effrRate && riskPremium ? Number(effrRate) + Number(riskPremium) : undefined;
  const totalRatePct = totalRateBp !== undefined ? (totalRateBp / 100).toFixed(2) : "-";

  // No loan form here; only summary

  const attestationUrl = connectedAddress ? `${window.location.origin}/attest?borrower=${connectedAddress}&weight=80` : "";

  return (
    <div className="bg-base-100 rounded-lg p-6 shadow-lg">
      <h3 className="text-lg font-semibold mb-4 flex items-center">
        <CreditCardIcon className="h-5 w-5 mr-2" />
        Borrower Overview
      </h3>

      {!hasAttestations ? (
        <div className="text-sm text-gray-700 space-y-3">
          <p>You don&apos;t have any attestations yet. Share your attestation link with trusted peers to build your reputation and unlock loans.</p>
          <Link href="/borrower" className="btn btn-primary w-full">Get Started</Link>
        </div>
      ) : (
        <div className="space-y-4">
          <div className="grid grid-cols-1 md:grid-cols-5 gap-4 text-center">
            <div>
              <div className="text-3xl font-bold">{(Number(creditScore) / 1000).toFixed(2)}%</div>
              <p className="text-xs text-gray-600">Credit Score</p>
            </div>
            <div>
              <div className="text-2xl font-bold">{ethBalance ? Number(ethBalance.formatted).toFixed(3) : "-"}</div>
              <p className="text-xs text-gray-600">ETH Balance</p>
            </div>
            <div>
              <div className="text-2xl font-bold">{usdcBalance ? Number(usdcBalance.formatted).toFixed(2) : "-"}</div>
              <p className="text-xs text-gray-600">USDC Balance</p>
            </div>
            <div>
              <div className="text-2xl font-bold">{0}</div>
              <p className="text-xs text-gray-600">Total Participants</p>
            </div>
            <div>
              <div className="text-2xl font-bold">{0}</div>
              <p className="text-xs text-gray-600">Your Attestations</p>
            </div>
          </div>
          <Link href="/borrower" className="btn btn-primary w-full">Open Borrower Dashboard</Link>
        </div>
      )}
    </div>
  );
};

export default BorrowWizard; 