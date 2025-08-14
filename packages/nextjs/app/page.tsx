"use client";

import Link from "next/link";
import type { NextPage } from "next";
import { useAccount } from "wagmi";
import { useState } from "react";
import { toast } from "react-hot-toast";
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
  const [isCopying, setIsCopying] = useState(false);

  const copyAttestationLink = async () => {
    if (!connectedAddress) return;
    
    setIsCopying(true);
    try {
      const attestationUrl = `${window.location.origin}/attest?borrower=${connectedAddress}`;
      await navigator.clipboard.writeText(attestationUrl);
      toast.success("Attestation link copied to clipboard!", {
        duration: 2000,
        position: "top-center",
      });
    } catch (error) {
      console.error("Failed to copy link:", error);
      toast.error("Failed to copy link to clipboard", {
        duration: 2000,
        position: "top-center",
      });
    } finally {
      setIsCopying(false);
    }
  };

  // Fetch PageRank score and credit score
  const { data: pageRankScore } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getPageRankScore",
    args: [connectedAddress],
  });

  const { data: creditScore } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getCreditScore",
    args: [connectedAddress],
  });

  const percentScore = (Number(pageRankScore ?? 0) / 1000).toFixed(2);
  const creditScorePercent = creditScore ? (Number(creditScore) / 10000).toFixed(2) : "0.00";
  const hasCreditScore = creditScore && Number(creditScore) > 0;

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

  // Fetch funding pool APY
  const { data: poolApyBp } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getFundingPoolAPY",
  });
  const poolApyPercent = poolApyBp !== undefined ? (Number(poolApyBp) / 100).toFixed(2) : "0.00";
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
              {/* Credit Score Status Section */}
              <div className="bg-base-100 rounded-lg p-6 mb-8 shadow-lg">
                <div className="text-center mb-6">
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
                    <div className="space-y-4">
                      <div className="bg-blue-50 border border-blue-200 rounded-lg p-4">
                        <div className="flex items-center justify-center space-x-2 mb-2">
                          <ChartBarIcon className="h-6 w-6 text-blue-600" />
                          <span className="font-medium text-lg">Let&apos;s Get Started!</span>
                        </div>
                        <p className="text-blue-700 text-sm mb-6 text-center">
                          Register your wallet to get started. Choose how you&apos;d like to participate:
                        </p>
                        
                        {/* Main Call to Action Cards */}
                        <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
                          {/* I am a Borrower */}
                          <Link href="/borrower" className="block h-full">
                            <div className="bg-gradient-to-br from-green-50 to-green-100 border-2 border-green-200 rounded-2xl p-8 shadow-lg hover:shadow-xl transition-all duration-200 hover:scale-105 cursor-pointer h-full flex flex-col">
                                                              <div className="text-center flex-1 flex flex-col">
                                  <CreditCardIcon className="h-16 w-16 text-green-600 mx-auto mb-4" />
                                  <h2 className="text-3xl font-bold text-green-700 mb-4">I am a Borrower</h2>
                                  <p className="text-gray-600 mb-6 flex-1">
                                    Get your address verified by asking for attestations from friends and community members. Once verified, you&apos;ll be eligible for loans according to your credit score.
                                  </p>
                                  <div className="space-y-4 mt-auto">
 
                                    <button
                                      onClick={(e) => {
                                        e.preventDefault();
                                        copyAttestationLink();
                                      }}
                                      disabled={isCopying}
                                      className="w-full bg-green-600 hover:bg-green-700 text-white font-bold py-4 px-6 rounded-lg text-lg transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                                    >
                                      {isCopying ? "Copying..." : "Copy Attestation Link"}
                                    </button>
                                  
                                </div>
                              </div>
                            </div>
                          </Link>

                          {/* I am a Lender */}
                          <Link href="/lend" className="block h-full">
                            <div className="bg-gradient-to-br from-blue-50 to-blue-100 border-2 border-blue-200 rounded-2xl p-8 shadow-lg hover:shadow-xl transition-all duration-200 hover:scale-105 cursor-pointer h-full flex flex-col">
                                                              <div className="text-center flex-1 flex flex-col">
                                  <BanknotesIcon className="h-16 w-16 text-blue-600 mx-auto mb-4" />
                                  <h2 className="text-3xl font-bold text-blue-700 mb-4">I am a Lender</h2>
                                  <p className="text-gray-600 mb-6 flex-1">
                                    Deposit USDC to earn {poolApyPercent}% APY. In addition to the APY, this increases your credit score and allows you to make attestations or even borrow.
                                  </p>
                                  <div className="space-y-4 mt-auto">
                                  <div className="w-full bg-blue-600 hover:bg-blue-700 text-white font-bold py-4 px-6 rounded-lg text-lg transition-colors">
                                    Lend and Earn Interest
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
