"use client";

import Link from "next/link";
import type { NextPage } from "next";
import { useAccount } from "wagmi";
import {
  UserGroupIcon,
  ChartBarIcon,
  CreditCardIcon,
  BanknotesIcon,
} from "@heroicons/react/24/outline";
import { useScaffoldReadContract } from "~~/hooks/scaffold-eth";
import { formatUSDC } from "~~/utils/format";
import { useUserRole } from "~~/hooks/useUserRole";

const Home: NextPage = () => {
  const { address: connectedAddress } = useAccount();

  const { data: creditScore } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getCreditScore",
    args: [connectedAddress],
  });

  const creditScorePercent = creditScore ? (Number(creditScore) / 10000).toFixed(2) : "0.00";
  const hasCreditScore = creditScore !== undefined && Number(creditScore) > 0;

  const getScoreColor = (score: number) => {
    if (score < 30) return "text-red-500";
    if (score < 50) return "text-orange-500";
    if (score < 70) return "text-yellow-500";
    if (score < 90) return "text-blue-500";
    return "text-green-500";
  };

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

  const { data: poolApyBp } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getFundingPoolAPY",
  });
  const poolApyPercent = poolApyBp !== undefined ? (Number(poolApyBp) / 100).toFixed(2) : "0.00";

  const { userRole, isLoading: roleLoading } = useUserRole();

  const { data: lenderDeposit } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "lenderDeposits",
    args: [connectedAddress],
  });

  return (
    <>
      <div className="flex items-center flex-col grow pt-4 sm:pt-10">
        <div className="px-4 sm:px-5 w-full max-w-7xl">
          {/* Hero Section */}
          <div className="text-center mb-4 sm:mb-12">
            <h1 className="text-3xl sm:text-5xl font-bold text-green-600 mb-1 sm:mb-2">LoanLink</h1>
            <p className="text-sm sm:text-base text-gray-500 mb-2 sm:mb-8">
              Trust-Based Lending for Everyone
            </p>
          </div>

          {connectedAddress ? (
            <>
              {/* Credit Score Status Section */}
              <div className="bg-base-100 rounded-lg p-3 sm:p-6 mb-4 sm:mb-8 shadow-lg">
                <div className="text-center mb-3 sm:mb-6">
                  {hasCreditScore ? (
                    <div className="space-y-4">
                      <div className="bg-green-50 border border-green-200 rounded-lg p-4">
                        <div className="flex items-center justify-center space-x-2 mb-2">
                          <ChartBarIcon className="h-6 w-6 text-green-600" />
                          <span className="font-medium text-lg">Your Credit Score:</span>
                          <span className={`text-2xl font-bold ${getScoreColor(Number(creditScorePercent))}`}>
                            {creditScorePercent}%
                          </span>
                        </div>
                        <p className="text-green-700 text-sm">
                          Great! You&apos;re registered with the system and can borrow or attest to others.
                        </p>
                      </div>
                    </div>
                  ) : (
                    <div className="space-y-3 sm:space-y-4">
                      <div className="bg-blue-50 border border-blue-200 rounded-lg p-3 sm:p-4">
                        <div className="flex items-center justify-center space-x-2 mb-1 sm:mb-2">
                          <ChartBarIcon className="h-5 w-5 sm:h-6 sm:w-6 text-blue-600" />
                          <span className="font-medium text-base sm:text-lg">Let&apos;s Get Started!</span>
                        </div>
                        <p className="text-blue-700 text-xs sm:text-sm mb-3 sm:mb-6 text-center">
                          Choose how you&apos;d like to participate:
                        </p>

                        {/* Main Call to Action Cards */}
                        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 sm:gap-8">
                          {/* I am a Borrower */}
                          <div className="h-full">
                            <div className="bg-gradient-to-br from-green-50 to-green-100 border-2 border-green-200 rounded-2xl p-3 sm:p-8 shadow-lg hover:shadow-xl transition-all duration-200 hover:scale-105 h-full flex flex-col">
                              <div className="text-center flex-1 flex flex-col">
                                <CreditCardIcon className="h-8 w-8 sm:h-16 sm:w-16 text-green-600 mx-auto mb-2 sm:mb-4" />
                                <h2 className="text-base sm:text-3xl font-bold text-green-700 mb-1 sm:mb-4">I&apos;m a Borrower</h2>
                                <p className="text-gray-600 mb-3 sm:mb-6 flex-1 text-xs sm:text-base hidden sm:block">
                                  Get your address verified by asking for attestations from friends and community members. Once verified, you&apos;ll be eligible for loans according to your credit score.
                                </p>
                                <div className="mt-auto">
                                  <Link
                                    href="/borrower"
                                    className="block w-full text-center bg-green-600 hover:bg-green-700 text-white font-bold py-2 sm:py-4 px-2 sm:px-6 rounded-lg text-xs sm:text-lg transition-colors"
                                  >
                                    <span className="hidden sm:inline">Go to Borrower Page</span>
                                    <span className="sm:hidden">Get Started</span>
                                  </Link>
                                </div>
                              </div>
                            </div>
                          </div>

                          {/* I am a Lender */}
                          <Link href="/lend" className="block h-full">
                            <div className="bg-gradient-to-br from-blue-50 to-blue-100 border-2 border-blue-200 rounded-2xl p-3 sm:p-8 shadow-lg hover:shadow-xl transition-all duration-200 hover:scale-105 cursor-pointer h-full flex flex-col">
                              <div className="text-center flex-1 flex flex-col">
                                <BanknotesIcon className="h-8 w-8 sm:h-16 sm:w-16 text-blue-600 mx-auto mb-2 sm:mb-4" />
                                <h2 className="text-base sm:text-3xl font-bold text-blue-700 mb-1 sm:mb-4">I&apos;m a Lender</h2>
                                <p className="text-gray-600 mb-3 sm:mb-6 flex-1 text-xs sm:text-base hidden sm:block">
                                  Deposit USDC to earn {poolApyPercent}% APY. In addition to the APY, this increases your credit score and allows you to make attestations or even borrow.
                                </p>
                                <div className="mt-auto">
                                  <div className="w-full bg-blue-600 hover:bg-blue-700 text-white font-bold py-2 sm:py-4 px-2 sm:px-6 rounded-lg text-xs sm:text-lg transition-colors">
                                    <span className="hidden sm:inline">Lend and Earn Interest</span>
                                    <span className="sm:hidden">Earn {poolApyPercent}% APY</span>
                                  </div>
                                </div>
                              </div>
                            </div>
                          </Link>
                        </div>
                      </div>
                    </div>
                  )}
                </div>
              </div>

              {/* Quick Actions for Users with Credit Scores */}
              {hasCreditScore && (
                <div className="bg-base-100 rounded-lg p-6 mb-8 shadow-lg">
                  <div className="text-center mb-6">
                    <h2 className="text-2xl font-bold text-gray-800 mb-2">Quick Actions</h2>
                    <p className="text-gray-600">You&apos;re registered! Here&apos;s what you can do:</p>
                  </div>
                  
                  <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
                    {/* Borrower Actions */}
                    <div className="bg-gradient-to-br from-green-50 to-green-100 border-2 border-green-200 rounded-2xl p-6">
                      <div className="text-center">
                        <CreditCardIcon className="h-12 w-12 text-green-600 mx-auto mb-3" />
                        <h3 className="text-xl font-bold text-green-700 mb-3">Borrower Actions</h3>
                        
                        {userRole === "borrower" || userRole === "both" ? (
                          <div className="space-y-3">
                            <div className="bg-white rounded-lg p-3">
                              <div className="flex items-center justify-center space-x-2 mb-1">
                                <ChartBarIcon className="h-4 w-4 text-green-600" />
                                <span className="font-medium text-sm">Credit Score:</span>
                                <span className={`text-sm font-bold ${getScoreColor(Number(creditScorePercent))}`}>
                                  {creditScorePercent}%
                                </span>
                              </div>
                              <div className="text-xs text-gray-600">
                                {totalRatePct && `Loan rate: ${totalRatePct}% APR`}
                              </div>
                            </div>
                            <Link href="/borrower" className="block w-full bg-green-600 hover:bg-green-700 text-white font-bold py-3 px-4 rounded-lg text-sm transition-colors">
                              Manage Your Loans
                            </Link>
                          </div>
                        ) : (
                          <div className="space-y-3">
                            <div className="bg-white rounded-lg p-3">
                              <div className="flex items-center justify-center space-x-2 mb-1">
                                <ChartBarIcon className="h-4 w-4 text-green-600" />
                                <span className="font-medium text-sm">Credit Score:</span>
                                <span className={`text-sm font-bold ${getScoreColor(Number(creditScorePercent))}`}>
                                  {creditScorePercent}%
                                </span>
                              </div>
                              <div className="text-xs text-gray-600">
                                {totalRatePct && `Loan rate: ${totalRatePct}% APR`}
                              </div>
                            </div>
                            <Link href="/borrower" className="block w-full bg-green-600 hover:bg-green-700 text-white font-bold py-3 px-4 rounded-lg text-sm transition-colors">
                              Request a Loan
                            </Link>
                          </div>
                        )}
                      </div>
                    </div>

                    {/* Lender Actions */}
                    <div className="bg-gradient-to-br from-blue-50 to-blue-100 border-2 border-blue-200 rounded-2xl p-6">
                      <div className="text-center">
                        <BanknotesIcon className="h-12 w-12 text-blue-600 mx-auto mb-3" />
                        <h3 className="text-xl font-bold text-blue-700 mb-3">Lender Actions</h3>
                        
                        <div className="space-y-3">
                          <div className="bg-white rounded-lg p-3">
                            <div className="grid grid-cols-2 gap-3 text-xs">
                              <div>
                                <div className="font-medium text-gray-600">Pool APY</div>
                                <div className="text-sm font-bold text-blue-600">
                                  {poolApyPercent}%
                                </div>
                              </div>
                              {(userRole === "lender" || userRole === "both") && (
                                <div>
                                  <div className="font-medium text-gray-600">Your Deposit</div>
                                  <div className="text-sm font-bold text-blue-600">
                                    {lenderDeposit ? formatUSDC(BigInt(lenderDeposit)) : "$0.00"}
                                  </div>
                                </div>
                              )}
                            </div>
                          </div>
                          <Link href="/lend" className="block w-full bg-blue-600 hover:bg-blue-700 text-white font-bold py-3 px-4 rounded-lg text-sm transition-colors">
                            {userRole === "lender" || userRole === "both" ? "Manage Deposits" : "Start Lending"}
                          </Link>
                        </div>
                      </div>
                    </div>
                  </div>
                  
                  {/* Attestation Section */}
                  <div className="mt-6 bg-gradient-to-br from-purple-50 to-purple-100 border-2 border-purple-200 rounded-2xl p-6">
                    <div className="text-center">
                      <UserGroupIcon className="h-12 w-12 text-purple-600 mx-auto mb-3" />
                      <h3 className="text-xl font-bold text-purple-700 mb-3">Help Others Build Credit</h3>
                      <p className="text-gray-600 text-sm mb-4">
                        Attest to friends and community members to help them build their credit scores.
                      </p>
                      <Link href="/attest" className="inline-block bg-purple-600 hover:bg-purple-700 text-white font-bold py-3 px-6 rounded-lg text-sm transition-colors">
                        Make Attestations
                      </Link>
                    </div>
                  </div>
                </div>
              )}

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

        </div>
      </div>
    </>
  );
};

export default Home;
