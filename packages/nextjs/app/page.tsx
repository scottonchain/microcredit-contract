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

  // Gate on own (granted) credit, not the score: a defaulted account can keep a score with no
  // credit, and an account can earn credit without a score.
  const { data: grantedCredit } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "grantedCredit",
    args: [connectedAddress],
  });

  const creditScorePercent = creditScore ? (Number(creditScore) / 10000).toFixed(2) : "0.00";
  const hasOwnCredit = grantedCredit !== undefined && grantedCredit > 0n;

  const getScoreColor = (score: number) => {
    if (score < 30) return "text-error";
    if (score < 50) return "text-caution";
    if (score < 70) return "text-caution";
    if (score < 90) return "text-info";
    return "text-success";
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
    contractName: "MicrocreditLens",
    functionName: "getFundingPoolAPY",
  });
  const apyDisplay = poolApyBp !== undefined ? `${(Number(poolApyBp) / 100).toFixed(2)}%` : "—";

  const { userRole, isLoading: roleLoading } = useUserRole();

  const { data: lenderDeposit } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "lenderBalance",
    args: [connectedAddress],
  });

  return (
    <>
      <div className="flex items-center flex-col grow pt-4 sm:pt-10">
        <div className="px-4 sm:px-5 w-full max-w-7xl">
          {/* Hero Section */}
          <div className="text-center mb-4 sm:mb-12">
            <h1 className="text-3xl sm:text-5xl font-bold text-success mb-1 sm:mb-2">LoanLink</h1>
            <p className="text-sm sm:text-base text-muted mb-2 sm:mb-8">
              Trust-Based Lending for Everyone
            </p>
          </div>

          {connectedAddress ? (
            <>
              {/* Credit Score Status Section */}
              <div className="bg-base-100 rounded-lg p-3 sm:p-6 mb-4 sm:mb-8 shadow-lg">
                <div className="text-center mb-3 sm:mb-6">
                  {hasOwnCredit ? (
                    <div className="space-y-4">
                      <div className="bg-success-surface border border-outline rounded-lg p-4">
                        <div className="flex items-center justify-center space-x-2 mb-2">
                          <ChartBarIcon className="h-6 w-6 text-success" />
                          <span className="font-medium text-lg">Your Credit Score:</span>
                          <span className={`text-2xl font-bold ${getScoreColor(Number(creditScorePercent))}`}>
                            {creditScorePercent}%
                          </span>
                        </div>
                        <p className="text-success text-sm">
                          You have a credit line of your own: you can borrow against it or back others.
                        </p>
                      </div>
                    </div>
                  ) : (
                    <div className="space-y-3 sm:space-y-4">
                      <div className="bg-info-surface border border-outline rounded-lg p-3 sm:p-4">
                        <div className="flex items-center justify-center space-x-2 mb-1 sm:mb-2">
                          <ChartBarIcon className="h-5 w-5 sm:h-6 sm:w-6 text-info" />
                          <span className="font-medium text-base sm:text-lg">Let&apos;s Get Started!</span>
                        </div>
                        <p className="text-info text-xs sm:text-sm mb-3 sm:mb-6 text-center">
                          Choose how you&apos;d like to participate:
                        </p>

                        {/* Main Call to Action Cards */}
                        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 sm:gap-8">
                          {/* I am a Borrower */}
                          <div className="h-full">
                            <div className="bg-success-surface border-2 border-outline rounded-2xl p-3 sm:p-8 shadow-lg hover:shadow-xl transition-all duration-200 hover:scale-105 h-full flex flex-col">
                              <div className="text-center flex-1 flex flex-col">
                                <CreditCardIcon className="h-8 w-8 sm:h-16 sm:w-16 text-success mx-auto mb-2 sm:mb-4" />
                                <h2 className="text-base sm:text-3xl font-bold text-success mb-1 sm:mb-4">I&apos;m a Borrower</h2>
                                <p className="text-muted mb-3 sm:mb-6 flex-1 text-xs sm:text-base hidden sm:block">
                                  Borrow against the credit you have, plus credit that friends and community members back you with from their own.
                                </p>
                                <div className="mt-auto">
                                  <Link
                                    href="/borrower"
                                    className="block w-full text-center bg-success hover:brightness-90 text-success-content font-bold py-2 sm:py-4 px-2 sm:px-6 rounded-lg text-xs sm:text-lg transition-colors"
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
                            <div className="bg-info-surface border-2 border-outline rounded-2xl p-3 sm:p-8 shadow-lg hover:shadow-xl transition-all duration-200 hover:scale-105 cursor-pointer h-full flex flex-col">
                              <div className="text-center flex-1 flex flex-col">
                                <BanknotesIcon className="h-8 w-8 sm:h-16 sm:w-16 text-info mx-auto mb-2 sm:mb-4" />
                                <h2 className="text-base sm:text-3xl font-bold text-info mb-1 sm:mb-4">I&apos;m a Lender</h2>
                                <p className="text-muted mb-3 sm:mb-6 flex-1 text-xs sm:text-base hidden sm:block">
                                  Deposit USDC to earn {apyDisplay} APY from the interest borrowers repay.
                                </p>
                                <div className="mt-auto">
                                  <div className="w-full bg-info hover:brightness-90 text-info-content font-bold py-2 sm:py-4 px-2 sm:px-6 rounded-lg text-xs sm:text-lg transition-colors">
                                    <span className="hidden sm:inline">Lend and Earn Interest</span>
                                    <span className="sm:hidden">Earn {apyDisplay} APY</span>
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

              {/* Quick Actions for Users with Credit of Their Own */}
              {hasOwnCredit && (
                <div className="bg-base-100 rounded-lg p-6 mb-8 shadow-lg">
                  <div className="text-center mb-6">
                    <h2 className="text-2xl font-bold text-base-content mb-2">Quick Actions</h2>
                    <p className="text-muted">You&apos;re registered! Here&apos;s what you can do:</p>
                  </div>
                  
                  <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
                    {/* Borrower Actions */}
                    <div className="bg-success-surface border-2 border-outline rounded-2xl p-6">
                      <div className="text-center">
                        <CreditCardIcon className="h-12 w-12 text-success mx-auto mb-3" />
                        <h3 className="text-xl font-bold text-success mb-3">Borrower Actions</h3>
                        
                        {userRole === "borrower" || userRole === "both" ? (
                          <div className="space-y-3">
                            <div className="bg-base-100 rounded-lg p-3">
                              <div className="flex items-center justify-center space-x-2 mb-1">
                                <ChartBarIcon className="h-4 w-4 text-success" />
                                <span className="font-medium text-sm">Credit Score:</span>
                                <span className={`text-sm font-bold ${getScoreColor(Number(creditScorePercent))}`}>
                                  {creditScorePercent}%
                                </span>
                              </div>
                              <div className="text-xs text-muted">
                                {totalRatePct && `Loan rate: ${totalRatePct}% APR`}
                              </div>
                            </div>
                            <Link href="/borrower" className="block w-full bg-success hover:brightness-90 text-success-content font-bold py-3 px-4 rounded-lg text-sm transition-colors">
                              Manage Your Loans
                            </Link>
                          </div>
                        ) : (
                          <div className="space-y-3">
                            <div className="bg-base-100 rounded-lg p-3">
                              <div className="flex items-center justify-center space-x-2 mb-1">
                                <ChartBarIcon className="h-4 w-4 text-success" />
                                <span className="font-medium text-sm">Credit Score:</span>
                                <span className={`text-sm font-bold ${getScoreColor(Number(creditScorePercent))}`}>
                                  {creditScorePercent}%
                                </span>
                              </div>
                              <div className="text-xs text-muted">
                                {totalRatePct && `Loan rate: ${totalRatePct}% APR`}
                              </div>
                            </div>
                            <Link href="/borrower" className="block w-full bg-success hover:brightness-90 text-success-content font-bold py-3 px-4 rounded-lg text-sm transition-colors">
                              Request a Loan
                            </Link>
                          </div>
                        )}
                      </div>
                    </div>

                    {/* Lender Actions */}
                    <div className="bg-info-surface border-2 border-outline rounded-2xl p-6">
                      <div className="text-center">
                        <BanknotesIcon className="h-12 w-12 text-info mx-auto mb-3" />
                        <h3 className="text-xl font-bold text-info mb-3">Lender Actions</h3>
                        
                        <div className="space-y-3">
                          <div className="bg-base-100 rounded-lg p-3">
                            <div className="grid grid-cols-2 gap-3 text-xs">
                              <div>
                                <div className="font-medium text-muted">Pool APY</div>
                                <div className="text-sm font-bold text-info">
                                  {apyDisplay}
                                </div>
                              </div>
                              {(userRole === "lender" || userRole === "both") && (
                                <div>
                                  <div className="font-medium text-muted">Your Deposit</div>
                                  <div className="text-sm font-bold text-info">
                                    {lenderDeposit ? formatUSDC(BigInt(lenderDeposit)) : "$0.00"}
                                  </div>
                                </div>
                              )}
                            </div>
                          </div>
                          <Link href="/lend" className="block w-full bg-info hover:brightness-90 text-info-content font-bold py-3 px-4 rounded-lg text-sm transition-colors">
                            {userRole === "lender" || userRole === "both" ? "Manage Deposits" : "Start Lending"}
                          </Link>
                        </div>
                      </div>
                    </div>
                  </div>
                  
                  {/* Backing Section */}
                  <div className="mt-6 bg-accent-surface border-2 border-outline rounded-2xl p-6">
                    <div className="text-center">
                      <UserGroupIcon className="h-12 w-12 text-accent mx-auto mb-3" />
                      <h3 className="text-xl font-bold text-accent mb-3">Back Someone You Trust</h3>
                      <p className="text-muted text-sm mb-4">
                        Lend part of your own credit to a friend. They can borrow against it, and you stand behind it.
                      </p>
                      <Link href="/attest" className="inline-block bg-accent hover:brightness-90 text-accent-content font-bold py-3 px-6 rounded-lg text-sm transition-colors">
                        Back a Borrower
                      </Link>
                    </div>
                  </div>
                </div>
              )}

              {/* Welcome message for existing users */}
              {userRole !== "none" && !roleLoading && (
                <div className="bg-info-surface border border-outline rounded-lg p-6 mb-8">
                  <div className="text-center">
                    <h2 className="text-2xl font-bold text-base-content mb-2">Welcome back!</h2>
                    <p className="text-muted">
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
              <p className="text-base-content mb-4 max-w-xl mx-auto">
                Connect your wallet to access fair micro-loans backed by your community. You borrow against credit you
                already have, or credit that people who know you back you with from their own.
              </p>
              <p className="text-base-content mb-6 max-w-xl mx-auto">
                After connecting, you can request loans, lend funds to earn interest, or back people you trust.
              </p>
              <p className="text-base-content font-medium">Use the “Connect Wallet” button in the top-right to begin.</p>
            </div>
          )}

        </div>
      </div>
    </>
  );
};

export default Home;
