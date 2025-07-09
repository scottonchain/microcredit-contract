"use client";

import { useState } from "react";
import type { NextPage } from "next";
import { useAccount } from "wagmi";
import { ChartBarIcon } from "@heroicons/react/24/outline";
import { Address, AddressInput } from "~~/components/scaffold-eth";
import { useScaffoldReadContract } from "~~/hooks/scaffold-eth";

const ScoresPage: NextPage = () => {
  const { address: connectedAddress } = useAccount();
  const [searchAddress, setSearchAddress] = useState("");
  const [selectedAddress, setSelectedAddress] = useState<string | null>(null);

  // Fetch PageRank score for connected user
  const { data: userPageRankScore } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getPageRankScore",
    args: [connectedAddress],
  });

  // PageRank score for searched address
  const { data: searchedPageRankScore } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getPageRankScore",
    args: [selectedAddress as `0x${string}` | undefined],
  });

  const toPercent = (score: bigint | undefined) => Number(score ?? 0) / 1000; // PR_SCALE=100000 => /1000 -> percent

  const getCreditScoreColor = (score: number) => {
    if (score < 30) return "text-red-500";
    if (score < 50) return "text-orange-500";
    if (score < 70) return "text-yellow-500";
    if (score < 90) return "text-blue-500";
    return "text-green-500";
  };

  const getCreditScoreLabel = (score: number) => {
    if (score < 30) return "Poor";
    if (score < 50) return "Fair";
    if (score < 70) return "Good";
    if (score < 90) return "Very Good";
    return "Excellent";
  };

  const getCreditScoreDescription = (score: number) => {
    if (score < 30) return "Limited credit history or poor repayment record";
    if (score < 50) return "Some credit history but room for improvement";
    if (score < 70) return "Good credit standing with reliable repayment history";
    if (score < 90) return "Very good credit with excellent repayment record";
    return "Exceptional credit with outstanding repayment history";
  };

  const handleSearch = () => {
    if (searchAddress) {
      setSelectedAddress(searchAddress);
    }
  };

  return (
    <>
      <div className="flex items-center flex-col grow pt-10">
        <div className="px-5 w-full max-w-6xl">
          <div className="flex items-center justify-center mb-8">
            <ChartBarIcon className="h-8 w-8 mr-3" />
            <h1 className="text-3xl font-bold">Credit Scores</h1>
          </div>

          {/* Search Section */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Search Credit Scores</h2>
            <div className="flex gap-4">
              <div className="flex-1">
                <AddressInput
                  value={searchAddress}
                  onChange={setSearchAddress}
                  placeholder="Enter address to search"
                />
              </div>
              <button
                onClick={handleSearch}
                disabled={!searchAddress}
                className="bg-blue-500 hover:bg-blue-600 disabled:bg-gray-400 text-white font-bold py-3 px-6 rounded-lg transition-colors"
              >
                Search
              </button>
            </div>
          </div>

          {/* Your Credit Score */}
          {connectedAddress && (
            <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
              <h2 className="text-xl font-semibold mb-4">Your Credit Profile</h2>
              <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
                <div className="text-center">
                  <div className={`text-5xl font-bold ${getCreditScoreColor(toPercent(userPageRankScore))}`}>
                    {toPercent(userPageRankScore).toFixed(2)}%
                  </div>
                  <div className="text-sm text-gray-600">Credit Score</div>
                  <div className="text-lg font-medium mt-1">
                    {getCreditScoreLabel(toPercent(userPageRankScore))}
                  </div>
                </div>
                <div className="text-center">
                  <div className="text-2xl font-bold text-blue-500">
                    {/* Placeholder for total attestations */}
                    0
                  </div>
                  <div className="text-sm text-gray-600">Total Attestations</div>
                </div>
                <div className="text-center">
                  <div className="text-2xl font-bold text-green-500">
                    {/* Placeholder for average confidence */}
                    0.0%
                  </div>
                  <div className="text-sm text-gray-600">Average Confidence</div>
                </div>
              </div>
              
              <div className="mt-6">
                <h3 className="font-medium mb-2">Score Description</h3>
                <p className="text-gray-600">
                  {getCreditScoreDescription(toPercent(userPageRankScore))}
                </p>
              </div>
            </div>
          )}

          {/* Searched Address Credit Score */}
          {selectedAddress && (
            <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
              <h2 className="text-xl font-semibold mb-4">Credit Score for Address</h2>
              <div className="mb-4">
                <Address address={selectedAddress as `0x${string}`} />
              </div>
              
              <div className="grid grid-cols-1 md:grid-cols-3 gap-6 mb-6">
                <div className="text-center">
                  <div className={`text-5xl font-bold ${getCreditScoreColor(toPercent(searchedPageRankScore))}`}>
                    {toPercent(searchedPageRankScore).toFixed(2)}%
                  </div>
                  <div className="text-sm text-gray-600">Credit Score</div>
                  <div className="text-lg font-medium mt-1">
                    {getCreditScoreLabel(toPercent(searchedPageRankScore))}
                  </div>
                </div>
                <div className="text-center">
                  <div className="text-2xl font-bold text-blue-500">
                    {/* Placeholder for total attestations */}
                    0
                  </div>
                  <div className="text-sm text-gray-600">Total Attestations</div>
                </div>
                <div className="text-center">
                  <div className="text-2xl font-bold text-green-500">
                    {/* Placeholder for average confidence */}
                    0.0%
                  </div>
                  <div className="text-sm text-gray-600">Average Confidence</div>
                </div>
              </div>

              {/* Attestations List */}
              <div>
                <h3 className="font-medium mb-3">Attestations</h3>
                <div className="space-y-2">
                  {/* Placeholder for attestations */}
                  <div className="text-center text-gray-500 py-4">No attestations found</div>
                </div>
              </div>
            </div>
          )}

          {/* Credit Score Ranges */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Credit Score Ranges</h2>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
              <div>
                <h3 className="font-medium mb-3">Score Categories</h3>
                <div className="space-y-3">
                  <div className="flex items-center justify-between p-3 bg-green-50 rounded">
                    <div>
                      <div className="font-medium text-green-800">Excellent (90-100%)</div>
                      <div className="text-sm text-green-600">Lowest interest rates, highest loan amounts</div>
                    </div>
                    <div className="text-2xl font-bold text-green-500">90-100%</div>
                  </div>
                  <div className="flex items-center justify-between p-3 bg-blue-50 rounded">
                    <div>
                      <div className="font-medium text-blue-800">Very Good (70-89%)</div>
                      <div className="text-sm text-blue-600">Good interest rates, high loan amounts</div>
                    </div>
                    <div className="text-2xl font-bold text-blue-500">70-89%</div>
                  </div>
                  <div className="flex items-center justify-between p-3 bg-yellow-50 rounded">
                    <div>
                      <div className="font-medium text-yellow-800">Good (50-69%)</div>
                      <div className="text-sm text-yellow-600">Moderate interest rates, standard loan amounts</div>
                    </div>
                    <div className="text-2xl font-bold text-yellow-500">50-69%</div>
                  </div>
                  <div className="flex items-center justify-between p-3 bg-orange-50 rounded">
                    <div>
                      <div className="font-medium text-orange-800">Fair (30-49%)</div>
                      <div className="text-sm text-orange-600">Higher interest rates, limited loan amounts</div>
                    </div>
                    <div className="text-2xl font-bold text-orange-500">30-49%</div>
                  </div>
                  <div className="flex items-center justify-between p-3 bg-red-50 rounded">
                    <div>
                      <div className="font-medium text-red-800">Poor (0-29%)</div>
                      <div className="text-sm text-red-600">Highest interest rates, minimal loan amounts</div>
                    </div>
                    <div className="text-2xl font-bold text-red-500">0-29%</div>
                  </div>
                </div>
              </div>
              
              <div>
                <h3 className="font-medium mb-3">How Scores Are Calculated</h3>
                <div className="space-y-4">
                  <div className="flex items-start space-x-3">
                    <div className="bg-blue-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                      1
                    </div>
                    <div>
                      <h4 className="font-medium">Social Attestations</h4>
                      <p className="text-gray-600">Community members attest to your creditworthiness</p>
                    </div>
                  </div>
                  <div className="flex items-start space-x-3">
                    <div className="bg-blue-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                      2
                    </div>
                    <div>
                      <h4 className="font-medium">PageRank Algorithm</h4>
                      <p className="text-gray-600">Scores are calculated using Google&apos;s PageRank algorithm</p>
                    </div>
                  </div>
                  <div className="flex items-start space-x-3">
                    <div className="bg-blue-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                      3
                    </div>
                    <div>
                      <h4 className="font-medium">Repayment History</h4>
                      <p className="text-gray-600">Successful loan repayments improve your score</p>
                    </div>
                  </div>
                  <div className="flex items-start space-x-3">
                    <div className="bg-blue-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                      4
                    </div>
                    <div>
                      <h4 className="font-medium">Network Effects</h4>
                      <p className="text-gray-600">Being attested by high-scoring users boosts your score</p>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>

          {/* Tips for Improving Credit Score */}
          <div className="bg-base-300 rounded-lg p-6">
            <h2 className="text-xl font-semibold mb-4">Tips for Improving Your Credit Score</h2>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
              <div className="space-y-4">
                <div className="flex items-start space-x-3">
                  <div className="bg-green-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                    1
                  </div>
                  <div>
                    <h3 className="font-medium">Get Attested</h3>
                    <p className="text-gray-600">Ask trusted community members to attest to your creditworthiness</p>
                  </div>
                </div>
                <div className="flex items-start space-x-3">
                  <div className="bg-green-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                    2
                  </div>
                  <div>
                    <h3 className="font-medium">Repay Loans on Time</h3>
                    <p className="text-gray-600">Timely repayments have the biggest positive impact on your score</p>
                  </div>
                </div>
              </div>
              <div className="space-y-4">
                <div className="flex items-start space-x-3">
                  <div className="bg-green-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                    3
                  </div>
                  <div>
                    <h3 className="font-medium">Build Relationships</h3>
                    <p className="text-gray-600">Develop trust relationships with other community members</p>
                  </div>
                </div>
                <div className="flex items-start space-x-3">
                  <div className="bg-green-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                    4
                  </div>
                  <div>
                    <h3 className="font-medium">Attest to Others</h3>
                    <p className="text-gray-600">Providing accurate attestations builds your reputation in the network</p>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </>
  );
};

export default ScoresPage; 