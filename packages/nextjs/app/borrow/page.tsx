"use client";

import { useState } from "react";
import type { NextPage } from "next";
import { useAccount } from "wagmi";
import { CreditCardIcon, CalculatorIcon, InformationCircleIcon } from "@heroicons/react/24/outline";
import Link from "next/link";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { formatUSDC, getCreditScoreColor } from "~~/utils/format";
import QRCodeDisplay from "~~/components/QRCodeDisplay";

const BorrowPage: NextPage = () => {
  const { address: connectedAddress } = useAccount();
  const [amount, setAmount] = useState("");
  const [repaymentPeriod, setRepaymentPeriod] = useState(365); // Default 1 year
  const [isLoading, setIsLoading] = useState(false);

  // Fetch PageRank score
  const { data: creditScore } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getPageRankScore",
    args: [connectedAddress],
  });

  // Fetch pool info for total participants
  const { data: poolInfo } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getPoolInfo",
  });
  const lenderCount = poolInfo ? poolInfo[3] : undefined;

  // Write contract functions
  const { writeContractAsync } = useScaffoldWriteContract({
    contractName: "DecentralizedMicrocredit",
  });

  // Preview loan terms when amount or repayment period changes
  const { data: previewTermsData } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "previewLoanTerms",
    args: [connectedAddress as `0x${string}` | undefined, connectedAddress && amount ? BigInt(amount) : undefined, connectedAddress && amount ? BigInt(repaymentPeriod * 24 * 60 * 60) : undefined],
  });

  const handleRequestLoan = async () => {
    if (!amount || !connectedAddress) return;
    
    setIsLoading(true);
    try {
      await writeContractAsync({
        functionName: "requestLoan",
        args: [BigInt(amount)], // Remove the repayment period argument as it's not part of the function signature
      });
      setAmount("");
    } catch (error) {
      console.error("Error requesting loan:", error);
    } finally {
      setIsLoading(false);
    }
  };

  const getPeriodLabel = (days: number) => {
    if (days === 30) return "1 Month";
    if (days === 90) return "3 Months";
    if (days === 180) return "6 Months";
    if (days === 365) return "1 Year";
    if (days === 730) return "2 Years";
    return `${Math.round(days / 365)} Years`;
  };

  const hasCredit = creditScore && Number(creditScore) > 0;
  const [showInfo, setShowInfo] = useState(false);
  const attestationUrl = connectedAddress ? `${window.location.origin}/attest?borrower=${connectedAddress}&weight=80` : "";

  return (
    <>
      <div className="flex items-center flex-col grow pt-10">
        <div className="px-5 w-full max-w-4xl">
          <div className="flex items-center justify-center mb-8">
            <CreditCardIcon className="h-8 w-8 mr-3" />
            <h1 className="text-3xl font-bold">Request Loan</h1>
          </div>

          {/* Attestation Call-to-Action (shown first if no credit yet) */}
          {!hasCredit && (
            <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8 flex flex-col items-center">
              <div className="flex items-center justify-center mb-4 gap-2">
                <h2 className="text-xl font-semibold text-center">Build Your Credit – Get Attestations</h2>
                <button
                  onClick={() => setShowInfo(true)}
                  className="text-info hover:text-info/80"
                  aria-label="What does this mean?"
                >
                  <InformationCircleIcon className="h-5 w-5" />
                </button>
              </div>
              <QRCodeDisplay value={attestationUrl} size={180} />
              <button
                onClick={() => {
                  navigator.clipboard.writeText(attestationUrl);
                  alert("Attestation link copied! Share it with your community.");
                }}
                className="btn btn-primary mt-4"
              >
                Copy Attestation Link
              </button>
              <p
                className="text-xs text-gray-500 mt-2 truncate max-w-full text-center"
                title={attestationUrl}
              >
                {attestationUrl}
              </p>
            </div>
          )}

          {showInfo && (
            <div className="fixed inset-0 flex items-center justify-center bg-black/50 z-50">
              <div className="bg-base-100 rounded-lg p-6 max-w-md w-11/12 shadow-lg">
                <h3 className="text-lg font-semibold mb-3">How LoanLink attestations work</h3>
                <p className="text-sm mb-3">
                  LoanLink builds your credit score from trust attestations your friends and community members give you. Share the link or QR code on this page with people who know you. Each attestation lifts your score.
                </p>
                <p className="text-sm mb-3">
                  Once your score is above zero, the loan request form unlocks and you can apply for your first loan.
                </p>
                <p className="text-sm mb-5">
                  Need a deeper dive?&nbsp;
                  <Link href="/help/borrow" className="link">Read the Borrower guide</Link>.
                </p>
                <button onClick={() => setShowInfo(false)} className="btn btn-primary w-full">Got it</button>
              </div>
            </div>
          )}

          {/* Your Credit Score */}
          {connectedAddress && (
            <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
              <h2 className="text-xl font-semibold mb-4">Your Credit Profile</h2>
              <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
                <div className="text-center">
                  {creditScore && Number(creditScore) > 0 ? (
                    <>
                      <div className="text-4xl font-bold text-green-500">
                        {(Number(creditScore) / 1000).toFixed(2)}%
                      </div>
                      <div className="text-sm text-gray-600">Credit Score</div>
                      <div className="text-lg font-medium mt-1">
                        {Number(creditScore) / 1000 < 30 ? "Poor" :
                          Number(creditScore) / 1000 < 50 ? "Fair" :
                          Number(creditScore) / 1000 < 70 ? "Good" :
                          Number(creditScore) / 1000 < 90 ? "Very Good" : "Excellent"}
                      </div>
                    </>
                  ) : (
                    <div className="text-yellow-600 text-sm">
                      No attestations yet. Share your attestation link above to build your score.
                    </div>
                  )}
                </div>
                <div className="text-center">
                  <div className="text-2xl font-bold text-blue-500">
                    {/* Show actual total participants */}
                    {lenderCount !== undefined ? lenderCount.toString() : "Loading..."}
                  </div>
                  <div className="text-sm text-gray-600">Total Participants</div>
                </div>
                <div className="text-center">
                  <div className="text-2xl font-bold text-green-500">
                    {/* Placeholder for attestations */}
                    0
                  </div>
                  <div className="text-sm text-gray-600">Your Attestations</div>
                </div>
              </div>
            </div>
          )}

          {/* Loan Request Section */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">{hasCredit ? "Request New Loan" : "How to Become Eligible"}</h2>
            {hasCredit ? (
            <div className="space-y-6">
              {/* Loan Amount */}
              <div>
                <label className="block text-sm font-medium mb-2">Loan Amount (USDC)</label>
                <input
                  type="number"
                  value={amount}
                  onChange={(e) => setAmount(e.target.value)}
                  placeholder="Enter amount in USDC"
                  className="w-full p-3 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                  min="1"
                  max="1000000"
                />
              </div>

              {/* Repayment Period */}
              <div>
                <label className="block text-sm font-medium mb-2">Repayment Period</label>
                <select
                  value={repaymentPeriod}
                  onChange={(e) => setRepaymentPeriod(Number(e.target.value))}
                  className="w-full p-3 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                >
                  <option value={30}>1 Month</option>
                  <option value={90}>3 Months</option>
                  <option value={180}>6 Months</option>
                  <option value={365}>1 Year</option>
                  <option value={730}>2 Years</option>
                  <option value={1095}>3 Years</option>
                  <option value={1460}>4 Years</option>
                  <option value={1825}>5 Years</option>
                </select>
              </div>

              {/* Loan Terms Preview */}
              {amount && previewTermsData && (
                <div className="bg-base-200 rounded-lg p-4">
                  <h3 className="font-medium mb-3 flex items-center">
                    <CalculatorIcon className="h-5 w-5 mr-2" />
                    Loan Terms Preview
                  </h3>
                  <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <div>
                      <span className="text-sm text-gray-600">Interest Rate:</span>
                      <div className="text-lg font-bold text-blue-500">
                        {(Number(previewTermsData[0]) / 10000).toFixed(2)}% APR
                      </div>
                    </div>
                    <div>
                      <span className="text-sm text-gray-600">Monthly Payment:</span>
                      <div className="text-lg font-bold text-green-500">
                        ${(Number(previewTermsData[1]) / 1000000).toFixed(2)} USDC
                      </div>
                    </div>
                    <div>
                      <span className="text-sm text-gray-600">Total Interest:</span>
                      <div className="text-lg font-bold text-orange-500">
                        ${(Number(amount) * Number(previewTermsData[0]) / 1000000).toFixed(2)} USDC
                      </div>
                    </div>
                    <div>
                      <span className="text-sm text-gray-600">Total Repayment:</span>
                      <div className="text-lg font-bold text-purple-500">
                        ${(Number(amount) * (1 + Number(previewTermsData[0]) / 1000000)).toFixed(2)} USDC
                      </div>
                    </div>
                  </div>
                </div>
              )}

              {/* Request Button */}
              <button
                onClick={handleRequestLoan}
                disabled={!amount || !connectedAddress || isLoading || !hasCredit}
                className="w-full bg-green-500 hover:bg-green-600 disabled:bg-gray-400 text-white font-bold py-3 px-4 rounded-lg transition-colors"
              >
                {isLoading ? "Requesting Loan..." : "Request Loan"}
              </button>
            </div>
            ) : (
              <div className="text-sm text-gray-700 space-y-3">
                <p>You need at least one attestation to request a loan. Share your attestation link with trusted peers and build your credit score.</p>
              </div>
            )}
          </div>

          {/* How Credit Scores Work */}
          <div className="bg-base-300 rounded-lg p-6">
            <h2 className="text-xl font-semibold mb-4">How Credit Scores Work</h2>
            <div className="space-y-4">
              <div className="flex items-start space-x-3">
                <div className="bg-green-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                  1
                </div>
                <div>
                  <h3 className="font-medium">Get Attested</h3>
                  <p className="text-gray-600">Others in your community attest to your creditworthiness</p>
                </div>
              </div>
              <div className="flex items-start space-x-3">
                <div className="bg-green-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                  2
                </div>
                <div>
                  <h3 className="font-medium">Reputation Engine</h3>
                  <p className="text-gray-600">Scores are produced by an on-chain reputation engine driven by social attestations</p>
                </div>
              </div>
              <div className="flex items-start space-x-3">
                <div className="bg-green-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                  3
                </div>
                <div>
                  <h3 className="font-medium">Better Terms</h3>
                  <p className="text-gray-600">A higher credit score unlocks lower interest rates and more favourable repayment terms.</p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </>
  );
};

export default BorrowPage; 