"use client";

import Link from "next/link";
import type { NextPage } from "next";
import { useAccount } from "wagmi";
import {
  UserGroupIcon,
  ChartBarIcon,
  CreditCardIcon,
  BanknotesIcon,
  UserIcon,
  CogIcon,
} from "@heroicons/react/24/outline";
import HowItWorks from "~~/components/HowItWorks";
import { Address } from "~~/components/scaffold-eth";
import { useScaffoldReadContract } from "~~/hooks/scaffold-eth";
import { formatUSDC } from "~~/utils/format";
import BorrowWizard from "~~/components/BorrowWizard";
import LendWizard from "~~/components/LendWizard";
import { useDisplayName } from "~~/components/scaffold-eth/DisplayNameContext";

const Home: NextPage = () => {
  const { address: connectedAddress } = useAccount();

  // Fetch PageRank score
  const { data: pageRankScore } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getPageRankScore",
    args: [connectedAddress],
  });

  const percentScore = (Number(pageRankScore ?? 0) / 1000).toFixed(2);

  // Pool stats
  const { data: poolInfo } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getPoolInfo",
  });

  const totalDeposits = poolInfo ? Number(poolInfo[0]) / 1e6 : 0;
  const availableFunds = poolInfo ? Number(poolInfo[1]) / 1e6 : 0;
  const reservedFunds = poolInfo ? Number(poolInfo[2]) / 1e6 : 0;
  const activeLenders = poolInfo ? Number(poolInfo[3]) : 0;

  const getScoreColor = (score: number) => {
    if (score < 30) return "text-red-500";
    if (score < 50) return "text-orange-500";
    if (score < 70) return "text-yellow-500";
    if (score < 90) return "text-blue-500";
    return "text-green-500";
  };

  // Interest rate bounds
  const { data: effrRate } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "effrRate" as any,
  });
  const { data: riskPremium } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "riskPremium" as any,
  });

  const totalRateBp = effrRate && riskPremium ? Number(effrRate) + Number(riskPremium) : undefined;
  const totalRatePct = totalRateBp !== undefined ? (totalRateBp / 100).toFixed(2) : undefined;
  const { displayName } = useDisplayName();

  const { data: lentOut } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "totalLentOut" as any,
  });
  const { data: utilCapBp } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "lendingUtilizationCap" as any,
  });

  const utilizationPct = totalDeposits > 0 ? (((Number(lentOut ?? 0) + reservedFunds) / 1e6) / totalDeposits) * 100 : 0;
  const capPct = utilCapBp ? Number(utilCapBp) / 100 : 0;

  // Fetch lender deposit for connected address
  const { data: lenderDeposit } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "lenderDeposits",
    args: [connectedAddress],
  });
  const isLender = lenderDeposit !== undefined && BigInt(lenderDeposit) > 0n;

  return (
    <>
      <div className="flex items-center flex-col grow pt-10">
        <div className="px-5 w-full max-w-7xl">
          {/* Hero Section */}
          <div className="text-center mb-12">
            <h1 className="text-5xl font-bold text-green-600 mb-4">LoanLink</h1>
            <p className="text-xl text-gray-600 mb-8 max-w-2xl mx-auto">
              A social reputation-based lending platform powered by on-chain social underwriting
            </p>
          </div>

          {connectedAddress ? (
            <>
              {/* Main Call to Action Cards */}
              <div className="grid grid-cols-1 lg:grid-cols-2 gap-8 mb-12">
                {/* I am a Borrower */}
                <div className="bg-gradient-to-br from-green-50 to-green-100 border-2 border-green-200 rounded-2xl p-8 shadow-lg hover:shadow-xl transition-shadow">
                  <div className="text-center">
                    <CreditCardIcon className="h-16 w-16 text-green-600 mx-auto mb-4" />
                    <h2 className="text-3xl font-bold text-green-700 mb-4">I am a Borrower</h2>
                    <p className="text-gray-600 mb-6">
                      Build your credit score through social attestations and access fair micro-loans with transparent terms.
                    </p>
                    
                    {Number(pageRankScore ?? 0) > 0 ? (
                      <div className="space-y-4">
                        <div className="bg-white rounded-lg p-4">
                          <div className="flex items-center justify-center space-x-2 mb-2">
                            <ChartBarIcon className="h-5 w-5 text-green-600" />
                            <span className="font-medium">Your Credit Score:</span>
                            <span className={`text-lg font-bold ${getScoreColor(Number(percentScore))}`}>
                              {percentScore}%
                            </span>
                          </div>
                          <div className="text-sm text-gray-600">
                            {totalRatePct && `Current loan rate: ${totalRatePct}% APR`}
                          </div>
                        </div>
                        <Link 
                          href="/borrower" 
                          className="block w-full bg-green-600 hover:bg-green-700 text-white font-bold py-4 px-6 rounded-lg text-lg transition-colors"
                        >
                          Request a Loan
                        </Link>
                      </div>
                    ) : (
                      <div className="space-y-4">
                        <div className="bg-white rounded-lg p-4">
                          <p className="text-sm text-gray-600 mb-2">
                            {isLender ? (
                              "Lenders cannot borrow from the same account for security reasons. Use a separate address to borrow."
                            ) : (
                              "Get attested by friends and community members to unlock your first loan."
                            )}
                          </p>
                        </div>
                        <Link 
                          href="/borrower" 
                          className="block w-full bg-green-600 hover:bg-green-700 text-white font-bold py-4 px-6 rounded-lg text-lg transition-colors"
                        >
                          Build Credit Score
                        </Link>
                      </div>
                    )}
                  </div>
                </div>

                {/* I am a Lender */}
                <div className="bg-gradient-to-br from-blue-50 to-blue-100 border-2 border-blue-200 rounded-2xl p-8 shadow-lg hover:shadow-xl transition-shadow">
                  <div className="text-center">
                    <BanknotesIcon className="h-16 w-16 text-blue-600 mx-auto mb-4" />
                    <h2 className="text-3xl font-bold text-blue-700 mb-4">I am a Lender</h2>
                    <p className="text-gray-600 mb-6">
                      Earn interest on your USDC deposits by funding loans backed by social reputation.
                    </p>
                    
                    <div className="space-y-4">
                      <div className="bg-white rounded-lg p-4">
                        <div className="grid grid-cols-2 gap-4 text-sm">
                          <div>
                            <div className="font-medium text-gray-600">Pool APY</div>
                            <div className="text-lg font-bold text-blue-600">
                              {totalRatePct ? `${(Number(totalRatePct) * 0.8).toFixed(2)}%` : "~8.00%"}
                            </div>
                          </div>
                          {/* USDC amount hidden for production
                          <div>
                            <div className="font-medium text-gray-600">Your Deposit</div>
                            <div className="text-lg font-bold text-blue-600">
                              {lenderDeposit ? formatUSDC(BigInt(lenderDeposit)) : "$0.00"}
                            </div>
                          </div>
                          */}
                        </div>
                      </div>
                      <Link 
                        href="/lend" 
                        className="block w-full bg-blue-600 hover:bg-blue-700 text-white font-bold py-4 px-6 rounded-lg text-lg transition-colors"
                      >
                        {isLender ? "Manage Deposits" : "Start Lending"}
                      </Link>
                    </div>
                  </div>
                </div>
              </div>


            </>
          ) : (
            // Anonymous visitor card
            <div className="bg-base-100 rounded-lg p-6 mb-8 shadow-lg text-center">
              <h2 className="text-xl font-semibold mb-4">Get Started with LoanLink</h2>
              <p className="text-gray-700 mb-4 max-w-xl mx-auto">
                Connect your wallet to build a community-backed credit score and access fair micro-loans. Your reputation is
                calculated entirely on-chain from social attestations.
              </p>
              <p className="text-gray-700 mb-6 max-w-xl mx-auto">
                After connecting, you can request loans, lend funds to earn interest, or attest to friends’ creditworthiness.
              </p>
              <p className="text-gray-700 font-medium">Use the “Connect Wallet” button in the top-right to begin.</p>
            </div>
          )}

          {/* How it works section */}
          <HowItWorks
            title="How It Works"
            steps={[
              {
                icon: <UserGroupIcon className="h-8 w-8 text-blue-600" />,
                title: "Build Reputation",
                description: "Get attested by others in your community to build your credit score",
                badgeColor: "bg-blue-500",
              },
              {
                icon: <CreditCardIcon className="h-8 w-8 text-green-600" />,
                title: "Request Loan",
                description: "Submit loan requests based on your social credit score",
                badgeColor: "bg-green-500",
              },
              {
                icon: <BanknotesIcon className="h-8 w-8 text-purple-600" />,
                title: "Earn Interest",
                description: "Lend funds to borrowers and earn interest on your deposits",
                badgeColor: "bg-purple-500",
              },
            ]}
            className="mt-8"
          />

          {/* Call to Action */}
          <div className="mt-16 text-center">
            <h2 className="text-2xl font-bold mb-4">Ready to Get Started?</h2>
            <p className="text-gray-600 mb-6">
              Connect your wallet and start building your credit reputation today.
            </p>
          </div>
        </div>
      </div>
    </>
  );
};

export default Home;
