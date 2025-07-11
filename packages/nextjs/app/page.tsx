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
import BorrowWizard from "~~/components/BorrowWizard";
import LendWizard from "~~/components/LendWizard";

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

  return (
    <>
      <div className="flex items-center flex-col grow pt-10">
        <div className="px-5 w-full max-w-7xl">
          <h1 className="text-center">
            <span className="block text-2xl mb-2">Welcome to</span>
            <span className="block text-4xl font-bold">LoanLink</span>
          </h1>
          <p className="text-center text-lg mt-4 mb-4">
            A social reputation-based lending platform powered by on-chain social underwriting
          </p>

          {connectedAddress ? (
            <>
              <div className="bg-base-100 rounded-lg p-6 mb-8 shadow-lg flex flex-col">
                <h2 className="text-xl font-semibold mb-4">Your Profile</h2>
                <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                  <div className="flex items-center space-x-2">
                    <UserIcon className="h-5 w-5" />
                    <span className="font-medium">Address:</span>
                    <Address address={connectedAddress} />
                  </div>
                  {Number(pageRankScore ?? 0) > 0 ? (
                    <div className="flex items-center space-x-2">
                      <ChartBarIcon className="h-5 w-5" />
                      <span className="font-medium">Credit Score:</span>
                      <span className={`text-lg font-bold ${getScoreColor(Number(percentScore))}`}>
                        {percentScore}%
                      </span>
                    </div>
                  ) : (
                    <div className="col-span-2 text-sm md:text-base text-gray-700 leading-relaxed">
                      <p className="mb-1">
                        You don&rsquo;t have a credit score yet. Build your reputation by:
                      </p>
                      <ul className="list-disc list-inside space-y-1">
                        <li>Requesting social attestations from friends or community members</li>
                        <li>Completing KYC verification</li>
                        <li>Depositing funds or interacting on-chain</li>
                      </ul>
                      <p className="mt-2">
                        Once you have a score you&rsquo;ll be able to request your first micro-loan.
                      </p>
                    </div>
                  )}
                  <div className="flex items-center space-x-2">
                    <BanknotesIcon className="h-5 w-5" />
                    <span className="font-medium">Status:</span>
                    {Number(pageRankScore ?? 0) > 0 ? (
                      <span className="text-lg font-bold text-green-600">Eligible for loans</span>
                    ) : (
                      <span className="text-lg font-bold text-red-600">Not eligible yet</span>
                    )}
                  </div>
                </div>

                {/* Borrow CTA */}
                {Number(pageRankScore ?? 0) > 0 && (
                  <div className="mt-auto text-center">
                    <Link href="/borrower" className="btn btn-primary btn-lg">
                      Borrow Now &nbsp;
                      {totalRatePct && <span className="text-xs">({totalRatePct}% APR)</span>}
                    </Link>
                  </div>
                )}
              </div>
              {/* NEW: Wizards */}
              <div className="grid grid-cols-1 md:grid-cols-2 gap-6 mb-8">
                <BorrowWizard connectedAddress={connectedAddress as `0x${string}`} />
                <LendWizard connectedAddress={connectedAddress as `0x${string}`} />
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

          {/* Pool Statistics */}
          <div className="bg-base-100 rounded-lg p-6 mb-8 shadow-lg mt-8">
            <h2 className="text-xl font-semibold mb-4">Lending Pool Statistics</h2>
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
              <div className="text-center">
                <div className="text-2xl font-bold text-green-500">
                  ${totalDeposits.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                </div>
                <div className="text-sm text-gray-600">Total Deposits</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold text-blue-500">
                  ${availableFunds.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                </div>
                <div className="text-sm text-gray-600">Available Funds</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold text-red-500">
                  ${reservedFunds.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                </div>
                <div className="text-sm text-gray-600">Reserved Funds</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold text-orange-500">
                  {activeLenders}
                </div>
                <div className="text-sm text-gray-600">Active Lenders</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold text-indigo-500">
                  {utilizationPct.toFixed(2)}%
                </div>
                <div className="text-sm text-gray-600">Pool Utilization</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold text-indigo-500">
                  {capPct.toFixed(0)}%
                </div>
                <div className="text-sm text-gray-600">Utilization Cap</div>
              </div>
            </div>
          </div>
          {utilizationPct > (capPct * 0.9) && (
            <div className="alert alert-warning mt-4">
              Lending pool is above 90% of its utilization cap. Withdrawals may be limited until more funds are deposited or loans are repaid.
            </div>
          )}

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
