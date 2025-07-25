"use client";

import { useState, useEffect, useMemo } from "react";
import { createPublicClient, http } from "viem";
import { localhost } from "viem/chains";
import deployedContracts from "~~/contracts/deployedContracts";
import type { NextPage } from "next";
import { useAccount } from "wagmi";
import { CreditCardIcon, CalculatorIcon, InformationCircleIcon, DocumentDuplicateIcon } from "@heroicons/react/24/outline";
import Link from "next/link";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { formatUSDC, getCreditScoreColor } from "~~/utils/format";
import QRCodeDisplay from "~~/components/QRCodeDisplay";
import { useDisplayName } from "~~/components/scaffold-eth/DisplayNameContext";

const BorrowPage: NextPage = () => {
  const { address: connectedAddress } = useAccount();
  const [amount, setAmount] = useState("");
  const [repaymentPeriod, setRepaymentPeriod] = useState(365); // Default 1 year
  const [isLoading, setIsLoading] = useState(false);

  // Fetch on-chain credit score (0 – 1e6)
  const { data: creditScore } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getCreditScore",
    args: [connectedAddress],
  });

  // Fetch pool info for total participants
  const { data: poolInfo } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getPoolInfo",
  });

  // Fetch borrower APR (loan rate) so borrowers know expected rate
  const { data: loanRateBp } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getLoanRate",
  });
  // Convert basis-points to percentage with two decimals (e.g. 1000 ⇒ "10.00")
  const borrowerAprPercent = loanRateBp !== undefined ? (Number(loanRateBp) / 100).toFixed(2) : undefined;
  // Removed lenderCount usage

  // Fetch maxLoanAmount to compute eligible amount
  const { data: maxLoanAmount } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "maxLoanAmount",
  });

  // Compute max eligible amount (BigInt, 6-decimals)
  const maxEligibleAmount = useMemo(() => {
    if (!creditScore || !maxLoanAmount) return 0n;
    return (BigInt(maxLoanAmount) * creditScore) / BigInt(1e6);
  }, [creditScore, maxLoanAmount]);

  const { displayName } = useDisplayName();

  // Pre-populate amount once eligible amount known and input empty (hasCredit defined below)
  // This useEffect must come after hasCredit declaration to avoid linter error

  // Helper to convert token amount (string) to micro-USDC BigInt
  const parseLoanAmount = (val: string): bigint | null => {
    if (!val || val.trim() === "") return null;
    const num = parseFloat(val);
    if (isNaN(num) || num <= 0) return null;
    return BigInt(Math.round(num * 1e6));
  };

  // Write contract functions
  const { writeContractAsync } = useScaffoldWriteContract({
    contractName: "DecentralizedMicrocredit",
  });

  // --- viem public client (local Anvil) -----------------------------------
  const CHAIN_ID = 31337;
  const RPC_URL = "http://localhost:8545";

  const publicClient = useMemo(
    () =>
      createPublicClient({
        chain: { ...localhost, id: CHAIN_ID },
        transport: http(RPC_URL),
      }),
    []
  );

  // Deployed Microcredit contract address / ABI
  const microcreditData = deployedContracts[CHAIN_ID]?.DecentralizedMicrocredit as any;
  const CONTRACT_ADDRESS = microcreditData?.address as `0x${string}` | undefined;

  // Preview loan terms when amount or repayment period changes
  const { data: previewTermsData } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "previewLoanTerms",
    args: [
      connectedAddress as `0x${string}` | undefined,
      connectedAddress && amount ? parseLoanAmount(amount) ?? undefined : undefined,
      connectedAddress && amount ? BigInt(repaymentPeriod * 24 * 60 * 60) : undefined,
    ],
  });

  // ───────────── Borrower current loan ─────────────
  const { data: borrowerLoanIds, refetch: refetchBorrowerLoanIds } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getBorrowerLoanIds" as any,
    args: connectedAddress ? ([connectedAddress as `0x${string}`] as any) : undefined,
  });

  // There is at most one active loan per borrower; take first
  const latestLoanId = borrowerLoanIds && borrowerLoanIds.length > 0 ? borrowerLoanIds[0] : undefined;

  const { data: latestLoan, refetch: refetchLatestLoan } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getLoan" as any,
    args: latestLoanId !== undefined ? ([latestLoanId as bigint] as any) : undefined,
    query: {
      enabled: latestLoanId !== undefined,
    },
  });

  const activePrincipal: bigint | undefined = latestLoan && (latestLoan as any)[4] ? (latestLoan as any)[0] : undefined;
  const activeOutstanding: bigint | undefined = latestLoan && (latestLoan as any)[4] ? (latestLoan as any)[1] : undefined;

  const handleRequestLoan = async () => {
    if (!amount || !connectedAddress) return;
    
    setIsLoading(true);
    try {
      const principal = parseLoanAmount(amount);
      if (!principal) return;
      // 1) Request the loan (returns loanId in the tx logs)
      const hash = await writeContractAsync({
        functionName: "requestLoan",
        args: [principal],
      });

      /**
       * 2) Once the request tx is mined, look up the borrower’s latest loan
       *    and immediately call `disburseLoan` so funds are transferred in a
       *    single UX flow (demo convenience – in production a keeper / oracle
       *    might handle disbursement).
       */
      try {
        // Wait ~3 seconds for the tx to be mined
        await new Promise(r => setTimeout(r, 3000));

        if (!publicClient || !CONTRACT_ADDRESS) throw new Error("Missing client or contract");

        // Fetch borrower loan IDs and pick the most recent
        const loanIds = (await publicClient.readContract({
          address: CONTRACT_ADDRESS,
          abi: microcreditData.abi,
          functionName: "getBorrowerLoanIds",
          args: [connectedAddress as `0x${string}`],
        })) as bigint[];

        const newLoanId = loanIds.length > 0 ? loanIds[loanIds.length - 1] : undefined;

        if (newLoanId !== undefined) {
          await writeContractAsync({
            functionName: "disburseLoan",
            args: [newLoanId],
          });

          // Refresh frontend state
          await refetchBorrowerLoanIds();
          await refetchLatestLoan();
        }
      } catch (e) {
        console.error("Auto-disburse failed", e);
      }
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

  useEffect(() => {
    if (hasCredit && maxEligibleAmount > 0n && amount === "") {
      const floorTwoDecimals = Math.floor(Number(maxEligibleAmount) / 1e4) / 100; // safe floor
      setAmount(floorTwoDecimals.toFixed(2));
    }
  }, [hasCredit, maxEligibleAmount, amount]);

  // Whenever loanId changes, refetch its details once
  useEffect(() => {
    if (latestLoanId !== undefined) {
      refetchLatestLoan();
    }
  }, [latestLoanId]);

  // Ensure user-entered amount does not exceed maximum
  const isAmountTooHigh = () => {
    const parsed = parseLoanAmount(amount);
    return parsed !== null && parsed > maxEligibleAmount;
  };

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

          {/* Borrower Widgets (CTA + Profile) */}
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-8 mb-8">

            {/* Attestation Call-to-Action */}
            {!hasCredit && (
              <div className="bg-base-100 rounded-lg p-6 shadow-lg flex flex-col items-center">
                <div className="flex items-center justify-center mb-4 gap-2">
                  <h2 className="text-xl font-semibold text-center">Your Personal Attestation Link</h2>
                  <button
                    onClick={() => setShowInfo(true)}
                    className="text-info hover:text-info/80"
                    aria-label="What does this mean?"
                  >
                    <InformationCircleIcon className="h-5 w-5" />
                  </button>
                </div>
                <div
                  onClick={() => {
                    navigator.clipboard.writeText(attestationUrl);
                    alert("Attestation link copied! Share it with your community.");
                  }}
                  className="cursor-pointer flex flex-col items-center"
                >
                  <QRCodeDisplay value={attestationUrl} size={120} />
                  <span className="text-xs text-gray-500">Click to copy</span>
                </div>
                <div className="text-xs flex items-center justify-center gap-1 text-blue-600 mt-3 max-w-full">
                  <a
                    href={attestationUrl}
                    target="_blank"
                    className="underline truncate max-w-[220px]"
                    title={attestationUrl}
                  >
                    {attestationUrl}
                  </a>
                  <DocumentDuplicateIcon
                    className="h-4 w-4 cursor-pointer flex-shrink-0"
                    onClick={() => { navigator.clipboard.writeText(attestationUrl); alert("Attestation link copied! Share it with your community."); }}
                  />
                </div>
              </div>
            )}

            {/* Your Account Profile */}
            {connectedAddress && (
              <div className="bg-base-100 rounded-lg p-6 shadow-lg">
                <h2 className="text-xl font-semibold mb-4">Your Account Profile{displayName && ` – ${displayName}`}</h2>

                {creditScore && Number(creditScore) > 0 ? (
                  <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
                    {/* Credit Score */}
                    <div className="text-center">
                      <div className="text-4xl font-bold text-green-500">
                        {(Number(creditScore) / 10000).toFixed(2)}%
                      </div>
                      <div className="text-sm text-gray-600">Credit Score</div>
                    </div>

                    {/* Eligible Amount */}
                    <div className="text-center">
                      <div className="text-2xl font-bold text-blue-500">
                        {maxLoanAmount !== undefined ? formatUSDC(BigInt(maxLoanAmount) * BigInt(creditScore!) / BigInt(1e6)) : "-"}
                      </div>
                      <div className="text-sm text-gray-600">Eligible to Borrow</div>
                    </div>

                    {/* Loan Principal */}
                    <div className="text-center">
                      <div className="text-2xl font-bold text-purple-500">
                        {activePrincipal !== undefined ? formatUSDC(activePrincipal) : "-"}
                      </div>
                      <div className="text-sm text-gray-600">Loan Principal</div>
                    </div>

                    {/* Outstanding / Payoff */}
                    <div className="text-center">
                      <div className="text-2xl font-bold text-orange-500">
                        {activeOutstanding !== undefined ? formatUSDC(activeOutstanding) : "-"}
                      </div>
                      <div className="text-sm text-gray-600">Payoff Amount</div>
                    </div>

                    {/* Borrower APR */}
                    <div className="text-center">
                      <div className="text-2xl font-bold text-purple-500">
                        {borrowerAprPercent !== undefined ? `${borrowerAprPercent}%` : "-"}
                      </div>
                      <div className="text-sm text-gray-600">Borrower APR</div>
                    </div>
                  </div>
                ) : (
                  <div className="text-yellow-600 text-sm text-center md:flex md:items-start md:justify-center md:h-full md:-mt-2">
                    You&apos;ll unlock borrowing once you gain at least one attestation and your credit score is above zero.
                  </div>
                )}
                </div>
            )}

          </div>

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

              {/* Request Button */}
              <button
                onClick={handleRequestLoan}
                disabled={!amount || !connectedAddress || isLoading || !hasCredit || isAmountTooHigh()}
                className="w-full bg-green-500 hover:bg-green-600 disabled:bg-gray-400 text-white font-bold py-3 px-4 rounded-lg transition-colors mb-4"
              >
                {isLoading ? "Requesting Loan..." : "Request Loan"}
              </button>

              {isAmountTooHigh() && (
                <p className="text-red-600 text-sm">Amount exceeds your maximum eligible loan. Lower the amount.</p>
              )}

              {/* Loan Terms Preview & Repayment Schedule */}
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
                        ${(Number(previewTermsData[1]) / 1e6).toFixed(2)} USDC
                      </div>
                    </div>
                    <div>
                      <span className="text-sm text-gray-600">Total Interest:</span>
                      <div className="text-lg font-bold text-orange-500">
                        {(() => {
                          const interest = Number(amount) * Number(previewTermsData[0]) / 10000;
                          return interest.toFixed(2);
                        })()} USDC
                      </div>
                    </div>
                    <div>
                      <span className="text-sm text-gray-600">Total Repayment:</span>
                      <div className="text-lg font-bold text-purple-500">
                        {(() => {
                          const total = Number(amount) * (1 + Number(previewTermsData[0]) / 10000);
                          return total.toFixed(2);
                        })()} USDC
                      </div>
                    </div>
                  </div>

                  {/* Repayment Schedule */}
                  {repaymentPeriod && (
                    <div className="mt-6 overflow-x-auto text-xs">
                      <h4 className="font-medium mb-2">Repayment Schedule</h4>
                      <table className="table w-full">
                        <thead>
                          <tr>
                            <th>#</th>
                            <th>Due (days)</th>
                            <th>Payment (USDC)</th>
                          </tr>
                        </thead>
                        <tbody>
                          {Array.from({ length: Math.ceil(repaymentPeriod / 30) }).map((_, idx) => (
                            <tr key={idx}>
                              <td>{idx + 1}</td>
                              <td>{(idx + 1) * 30}</td>
                              <td>{(Number(previewTermsData[1]) / 1e6).toFixed(2)}</td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  )}
                </div>
              )}
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