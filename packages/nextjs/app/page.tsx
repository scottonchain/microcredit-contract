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
  const activeLenders = poolInfo ? Number(poolInfo[2]) : 0;

  const getScoreColor = (score: number) => {
    if (score < 30) return "text-red-500";
    if (score < 50) return "text-orange-500";
    if (score < 70) return "text-yellow-500";
    if (score < 90) return "text-blue-500";
    return "text-green-500";
  };

  // Interest rate bounds
  const { data: rMin } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "rMin",
  });
  const { data: rMax } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "rMax",
  });

  const rMinPct = rMin ? (Number(rMin) / 10000).toFixed(2) : undefined;
  const rMaxPct = rMax ? (Number(rMax) / 10000).toFixed(2) : undefined;

  return (
    <>
      <div className="flex items-center flex-col grow pt-10">
        <div className="px-5 w-full max-w-7xl">
          <h1 className="text-center">
            <span className="block text-2xl mb-2">Welcome to</span>
            <span className="block text-4xl font-bold">Decentralized Microcredit</span>
          </h1>
          <p className="text-center text-lg mt-4 mb-4">
            A social reputation-based lending platform powered by PageRank
          </p>

          {connectedAddress ? (
            <div className="bg-base-100 rounded-lg p-6 mb-8 shadow-lg">
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
                  <div className="bg-yellow-100 border border-yellow-400 text-yellow-800 text-sm rounded-md p-3 col-span-2 flex flex-col md:flex-row md:items-center md:space-x-3">
                    <span className="font-medium">No attestations yet.</span>
                    <span>Share this link with trusted peers so they can attest to you.</span>
                    <button
                      onClick={() => {
                        if (!connectedAddress) return;
                        const url = `${window.location.origin}/attest?borrower=${connectedAddress}&weight=80`;
                        navigator.clipboard.writeText(url);
                        alert("Attestation link copied!");
                      }}
                      className="btn btn-secondary btn-xs mt-2 md:mt-0"
                    >
                      Copy Attestation Link
                    </button>
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
                <div className="mt-6 text-center">
                  <Link href="/borrow" className="btn btn-primary btn-lg">
                    Borrow Now &nbsp;
                    {rMinPct && rMaxPct && <span className="text-xs">({rMinPct}% – {rMaxPct}% APR)</span>}
                  </Link>
                </div>
              )}
            </div>
          ) : (
            // Anonymous visitor card
            <div className="bg-base-100 rounded-lg p-6 mb-8 shadow-lg text-center">
              <h2 className="text-xl font-semibold mb-4">Get Started with Decentralized Microcredit</h2>
              <p className="text-gray-700 mb-4 max-w-xl mx-auto">
                Connect your wallet to build a community-backed credit score and access fair micro-loans. Your reputation is
                calculated using social attestations and the PageRank algorithm.
              </p>
              <p className="text-gray-700 mb-6 max-w-xl mx-auto">
                After connecting, you can request loans, lend funds to earn interest, or attest to friends’ creditworthiness.
              </p>
              <p className="text-gray-700 font-medium">Use the “Connect Wallet” button in the top-right to begin.</p>
            </div>
          )}

          {/* Pool Statistics */}
          <div className="bg-base-100 rounded-lg p-6 mb-8 shadow-lg">
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
                <div className="text-2xl font-bold text-orange-500">
                  {activeLenders}
                </div>
                <div className="text-sm text-gray-600">Active Lenders</div>
              </div>
            </div>
          </div>

          {/* Action buttons for logged-in users */}
          {connectedAddress && (
            <div className="grid grid-cols-1 md:grid-cols-3 gap-6 mt-6">
              <Link href="/attest" className="btn btn-secondary w-full">Make Attestation</Link>
              <Link href="/borrow" className="btn btn-primary w-full">Request Loan</Link>
              <Link href="/lend" className="btn btn-accent w-full">Lend Funds</Link>
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
                description: "Submit loan requests based on your PageRank-based credit score",
                badgeColor: "bg-green-500",
              },
              {
                icon: <BanknotesIcon className="h-8 w-8 text-purple-600" />,
                title: "Earn Interest",
                description: "Lend funds to borrowers and earn interest on your deposits",
                badgeColor: "bg-purple-500",
              },
            ]}
            className="mt-16"
          />

          {/* Key Features */}
          <div className="mt-16">
            <h2 className="text-2xl font-bold text-center mb-8">Key Features</h2>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
              <div className="bg-base-100 p-6 rounded-lg shadow-lg">
                <h3 className="text-lg font-semibold mb-3 flex items-center">
                  <ChartBarIcon className="h-6 w-6 mr-2 text-blue-500" />
                  PageRank Credit Scoring
                </h3>
                <p className="text-gray-600">
                  Uses Google&apos;s PageRank algorithm to calculate credit scores based on social attestations and network relationships.
                </p>
              </div>
              <div className="bg-base-100 p-6 rounded-lg shadow-lg">
                <h3 className="text-lg font-semibold mb-3 flex items-center">
                  <UserGroupIcon className="h-6 w-6 mr-2 text-green-500" />
                  Social Attestations
                </h3>
                <p className="text-gray-600">
                  Community members can attest to each other&apos;s creditworthiness with confidence levels.
                </p>
              </div>
              <div className="bg-base-100 p-6 rounded-lg shadow-lg">
                <h3 className="text-lg font-semibold mb-3 flex items-center">
                  <BanknotesIcon className="h-6 w-6 mr-2 text-purple-500" />
                  Decentralized Lending
                </h3>
                <p className="text-gray-600">
                  Peer-to-peer lending with automatic fund allocation and interest distribution.
                </p>
              </div>
              <div className="bg-base-100 p-6 rounded-lg shadow-lg">
                <h3 className="text-lg font-semibold mb-3 flex items-center">
                  <CogIcon className="h-6 w-6 mr-2 text-orange-500" />
                  Oracle Management
                </h3>
                <p className="text-gray-600">
                  Admin panel for managing oracles, fee rates, and system parameters.
                </p>
              </div>
            </div>
          </div>

          {/* Call to Action */}
          <div className="mt-16 text-center">
            <h2 className="text-2xl font-bold mb-4">Ready to Get Started?</h2>
            <p className="text-gray-600 mb-6">
              Connect your wallet and start building your credit reputation today.
            </p>
            <div className="flex justify-center space-x-4">
              <Link href="/attest" className="bg-blue-500 hover:bg-blue-600 text-white font-bold py-3 px-6 rounded-lg transition-colors">
                Make Attestation
              </Link>
              <Link href="/borrow" className="bg-green-500 hover:bg-green-600 text-white font-bold py-3 px-6 rounded-lg transition-colors">
                Request Loan
              </Link>
            </div>
          </div>
        </div>
      </div>
    </>
  );
};

export default Home;
