"use client";

import { useState } from "react";
import type { NextPage } from "next";
import { useAccount } from "wagmi";
import { CogIcon, ShieldCheckIcon } from "@heroicons/react/24/outline";
import { Address, AddressInput } from "~~/components/scaffold-eth";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";

const AdminPage: NextPage = () => {
  const { address: connectedAddress } = useAccount();
  const [userAddress, setUserAddress] = useState("");
  const [newScore, setNewScore] = useState("");
  const [isLoading, setIsLoading] = useState(false);

  // Read contract data - only use functions that exist
  const { data: oracle } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "oracle",
  });

  const { data: owner } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "owner",
  });

  // Write contract functions - only use functions that exist
  const { writeContractAsync: writeYourContractAsync } = useScaffoldWriteContract({
    contractName: "DecentralizedMicrocredit",
  });

  const handleUpdateScore = async () => {
    if (!userAddress || !newScore) return;
    
    setIsLoading(true);
    try {
      const scoreValue = Math.round(parseFloat(newScore) * 10000); // Convert to basis points
      await writeYourContractAsync({
        functionName: "updateCreditScore",
        args: [userAddress as `0x${string}`, BigInt(scoreValue)],
      });
      setUserAddress("");
      setNewScore("");
    } catch (error) {
      console.error("Error updating credit score:", error);
    } finally {
      setIsLoading(false);
    }
  };

  // Check permissions
  const isOwner = connectedAddress && owner && connectedAddress.toLowerCase() === owner.toLowerCase();
  const isOracle = oracle && connectedAddress && connectedAddress.toLowerCase() === oracle.toLowerCase();
  const hasAccess = isOwner || isOracle;

  // Credit score lookup
  const [lookupAddress, setLookupAddress] = useState<string>("");
  const { data: lookupScore } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getPageRankScore",
    args: [lookupAddress as `0x${string}` | undefined],
  });

  // Show access denied if user doesn't have permissions
  if (!hasAccess) {
    return (
      <div className="flex items-center justify-center min-h-screen">
        <div className="text-center">
          <ShieldCheckIcon className="h-16 w-16 mx-auto text-red-500 mb-4" />
          <h1 className="text-2xl font-bold text-red-500 mb-2">Access Denied</h1>
          <p className="text-gray-600 mb-4">
            You need to be the contract owner or oracle to access this page.
          </p>
          <div className="space-y-2 text-sm text-gray-500">
            <p>Current Oracle: {oracle ? <Address address={oracle as `0x${string}`} /> : "Loading..."}</p>
            <p>Contract Owner: {owner ? <Address address={owner as `0x${string}`} /> : "Loading..."}</p>
            <p>Your Address: {connectedAddress ? <Address address={connectedAddress} /> : "Not connected"}</p>
          </div>
        </div>
      </div>
    );
  }

  return (
    <>
      <div className="flex items-center flex-col grow pt-10">
        <div className="px-5 w-full max-w-6xl">
          <div className="flex items-center justify-center mb-8">
            <CogIcon className="h-8 w-8 mr-3" />
            <h1 className="text-3xl font-bold">Admin Panel</h1>
          </div>

          {/* Credit Score Lookup */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Credit Score Lookup</h2>
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mb-4">
              <div>
                <label className="block text-sm font-medium mb-2">Address</label>
                <AddressInput value={lookupAddress} onChange={setLookupAddress} placeholder="0x..." />
              </div>
              <div className="flex items-end text-lg font-bold">
                {lookupScore ? `${(Number(lookupScore) / 1000).toFixed(2)}%` : "-"}
              </div>
            </div>
          </div>

          {/* Oracle Management */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Oracle Management</h2>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
              <div>
                <h3 className="font-medium mb-2">Current Oracle</h3>
                {oracle ? (
                  <Address address={oracle as `0x${string}`} />
                ) : (
                  <div className="text-gray-500">Loading...</div>
                )}
              </div>
              <div>
                <h3 className="font-medium mb-2">Contract Owner</h3>
                {owner ? (
                  <Address address={owner as `0x${string}`} />
                ) : (
                  <div className="text-gray-500">Loading...</div>
                )}
              </div>
            </div>
          </div>

          {/* Credit Score Management */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Credit Score Management</h2>
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
              <div>
                <label className="block text-sm font-medium mb-2">User Address</label>
                <AddressInput
                  value={userAddress}
                  onChange={setUserAddress}
                  placeholder="Enter user address"
                />
              </div>
              <div>
                <label className="block text-sm font-medium mb-2">New Credit Score</label>
                <input
                  type="number"
                  value={newScore}
                  onChange={(e) => setNewScore(e.target.value)}
                  placeholder="Enter score (0-100)"
                  className="w-full p-2 border border-gray-300 rounded focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                  min="0"
                  max="100"
                  step="0.1"
                />
              </div>
              <div className="flex items-end">
                <button
                  onClick={handleUpdateScore}
                  disabled={!userAddress || !newScore || isLoading}
                  className="w-full bg-purple-500 hover:bg-purple-600 disabled:bg-gray-400 text-white font-bold py-2 px-4 rounded transition-colors"
                >
                  {isLoading ? "Updating..." : "Update Score"}
                </button>
              </div>
            </div>
          </div>

          {/* System Actions */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">System Actions</h2>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
              <div>
                <h3 className="font-medium mb-2">System Health</h3>
                <div className="space-y-2 text-sm">
                  <div className="flex items-center space-x-2">
                    <div className="w-2 h-2 bg-green-500 rounded-full"></div>
                    <span>Contract: Active</span>
                  </div>
                  <div className="flex items-center space-x-2">
                    <div className="w-2 h-2 bg-green-500 rounded-full"></div>
                    <span>Oracle: {oracle ? "Set" : "Not Set"}</span>
                  </div>
                  <div className="flex items-center space-x-2">
                    <div className="w-2 h-2 bg-green-500 rounded-full"></div>
                    <span>PageRank: Available</span>
                  </div>
                </div>
              </div>
              <div>
                <h3 className="font-medium mb-2">Admin Status</h3>
                <div className="space-y-2 text-sm">
                  <div className="flex items-center space-x-2">
                    <div className="w-2 h-2 bg-green-500 rounded-full"></div>
                    <span>Access: {hasAccess ? "Granted" : "Denied"}</span>
                  </div>
                  <div className="flex items-center space-x-2">
                    <div className="w-2 h-2 bg-green-500 rounded-full"></div>
                    <span>Role: {isOwner ? "Owner" : isOracle ? "Oracle" : "None"}</span>
                  </div>
                </div>
              </div>
            </div>
          </div>

          {/* Instructions */}
          <div className="bg-base-300 rounded-lg p-6">
            <h2 className="text-xl font-semibold mb-4">Admin Functions</h2>
            <div className="space-y-4">
              <div>
                <h3 className="font-medium">Credit Score Management</h3>
                <p className="text-sm text-gray-600">
                  Update credit scores for users. Scores should be between 0-100 (percentage).
                </p>
              </div>
              <div>
                <h3 className="font-medium">Oracle Setup</h3>
                <p className="text-sm text-gray-600">
                  Use the <a href="/oracle-setup" className="text-blue-500 underline">Oracle Setup page</a> to manage oracle permissions.
                </p>
              </div>
              <div>
                <h3 className="font-medium">Debug Interface</h3>
                <p className="text-sm text-gray-600">
                  Use the <a href="/debug" className="text-blue-500 underline">Debug page</a> to test contract functions and view contract state.
                </p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </>
  );
};

export default AdminPage; 