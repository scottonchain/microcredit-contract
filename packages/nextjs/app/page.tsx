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
import { useUserRole } from "~~/hooks/useUserRole";

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
  const { userRole, isLoading: roleLoading } = useUserRole();

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
              {/* Welcome message for existing users */}
              {userRole !== "none" && !roleLoading && (
                <div className="bg-gradient-to-r from-green-50 to-blue-50 border border-green-200 rounded-lg p-6 mb-8">
                  <div className="text-center">
                    <h2 className="text-2xl font-bold text-gray-800 mb-2">Welcome back!</h2>
                    <p className="text-gray-600">
                      {userRole === "borrower" && "You have active loans. Redirecting you to your borrower dashboard..."}
                      {userRole === "lender" && "You have active deposits. Redirecting you to your lender dashboard..."}
                      {userRole === "both" && "You have both loans and deposits. Redirecting you to your lender dashboard..."}
                    </p>
                  </div>
                </div>
              )}

              {/* Main Call to Action Cards */}
              <div className="grid grid-cols-1 lg:grid-cols-2 gap-8 mb-12">
                {/* I am a Borrower */}
                <Link href="/borrower" className="block">
                  <div className="bg-gradient-to-br from-green-50 to-green-100 border-2 border-green-200 rounded-2xl p-8 shadow-lg hover:shadow-xl transition-all duration-200 hover:scale-105 cursor-pointer">
                    <div className="text-center">
                      <CreditCardIcon className="h-16 w-16 text-green-600 mx-auto mb-4" />
                      <h2 className="text-3xl font-bold text-green-700 mb-4">I am a Borrower</h2>
                      <p className="text-gray-600 mb-6">
                        Build your credit score through social attestations and access fair micro-loans with transparent terms.
                      </p>
                      
                      {userRole === "borrower" || userRole === "both" ? (
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
                          <div className="w-full bg-green-600 hover:bg-green-700 text-white font-bold py-4 px-6 rounded-lg text-lg transition-colors">
                            Manage Your Loans
                          </div>
                        </div>
                      ) : Number(pageRankScore ?? 0) > 0 ? (
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
                          <div className="w-full bg-green-600 hover:bg-green-700 text-white font-bold py-4 px-6 rounded-lg text-lg transition-colors">
                            Request a Loan
                          </div>
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
                          <div className="w-full bg-green-600 hover:bg-green-700 text-white font-bold py-4 px-6 rounded-lg text-lg transition-colors">
                            Build Credit Score
                          </div>
                        </div>
                      )}
                    </div>
                  </div>
                </Link>

                {/* I am a Lender */}
                <Link href="/lend" className="block">
                  <div className="bg-gradient-to-br from-blue-50 to-blue-100 border-2 border-blue-200 rounded-2xl p-8 shadow-lg hover:shadow-xl transition-all duration-200 hover:scale-105 cursor-pointer">
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
                            {(userRole === "lender" || userRole === "both") && (
                              <div>
                                <div className="font-medium text-gray-600">Your Deposit</div>
                                <div className="text-lg font-bold text-blue-600">
                                  {lenderDeposit ? formatUSDC(BigInt(lenderDeposit)) : "$0.00"}
                                </div>
                              </div>
                            )}
                          </div>
                        </div>
                        <div className="w-full bg-blue-600 hover:bg-blue-700 text-white font-bold py-4 px-6 rounded-lg text-lg transition-colors">
                          {userRole === "lender" || userRole === "both" ? "Manage Deposits" : "Start Lending"}
                        </div>
                      </div>
                    </div>
                  </div>
                </Link>
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

          {/* Social Lending System Overview */}
          <div className="bg-base-100 rounded-lg p-8 shadow-lg mt-8">
            <div className="text-center mb-8">
              <h2 className="text-3xl font-bold text-gray-800 mb-4">Welcome to Social Lending</h2>
              <p className="text-lg text-gray-600 max-w-4xl mx-auto">
                A revolutionary approach to microcredit that replaces traditional credit scores with community trust and social reputation.
              </p>
            </div>

            <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
              {/* For Everyone */}
              <div className="text-center">
                <div className="bg-gradient-to-br from-purple-50 to-purple-100 rounded-xl p-6 mb-4">
                  <UserGroupIcon className="h-12 w-12 text-purple-600 mx-auto mb-3" />
                  <h3 className="text-xl font-semibold text-purple-800 mb-2">Community-Driven</h3>
                  <p className="text-gray-700 text-sm">
                    Instead of banks deciding who gets loans, your community vouches for your trustworthiness. 
                    Friends, family, and community members attest to your reliability, building your credit score through social connections.
                  </p>
                </div>
              </div>

              {/* For Borrowers */}
              <div className="text-center">
                <div className="bg-gradient-to-br from-green-50 to-green-100 rounded-xl p-6 mb-4">
                  <CreditCardIcon className="h-12 w-12 text-green-600 mx-auto mb-3" />
                  <h3 className="text-xl font-semibold text-green-800 mb-2">For Borrowers</h3>
                  <p className="text-gray-700 text-sm">
                    No bank account or credit history required. Get attested by people who know you, 
                    then access fair microloans with transparent terms. Every successful repayment improves your score and helps your attesters.
                  </p>
                </div>
              </div>

              {/* For Lenders */}
              <div className="text-center">
                <div className="bg-gradient-to-br from-blue-50 to-blue-100 rounded-xl p-6 mb-4">
                  <BanknotesIcon className="h-12 w-12 text-blue-600 mx-auto mb-3" />
                  <h3 className="text-xl font-semibold text-blue-800 mb-2">For Lenders</h3>
                  <p className="text-gray-700 text-sm">
                    Support financial inclusion while earning returns. Deposit funds that are automatically 
                    distributed to qualified borrowers. Earn interest and help build stronger communities through social lending.
                  </p>
                </div>
              </div>
            </div>

            <div className="mt-8 p-6 bg-gray-50 rounded-xl">
              <h3 className="text-xl font-semibold text-gray-800 mb-4 text-center">How Social Credit Works</h3>
              <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                <div>
                  <h4 className="font-semibold text-gray-700 mb-2">Building Trust</h4>
                  <p className="text-gray-600 text-sm">
                    Community members attest to your creditworthiness based on personal relationships and reputation. 
                    These attestations form a trust network that determines your loan eligibility and terms.
                  </p>
                </div>
                <div>
                  <h4 className="font-semibold text-gray-700 mb-2">Shared Responsibility</h4>
                  <p className="text-gray-600 text-sm">
                    When you repay a loan, both you and your attesters benefit from improved credit scores. 
                    If you default, both scores are affected, encouraging careful attestations and responsible borrowing.
                  </p>
                </div>
              </div>
            </div>

            <div className="mt-6 text-center">
              <p className="text-gray-600 text-sm">
                <strong>Our Mission:</strong> To provide financial access to underserved communities through 
                the power of social connections and blockchain technology, creating a more inclusive and transparent financial system.
              </p>
            </div>
          </div>

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
