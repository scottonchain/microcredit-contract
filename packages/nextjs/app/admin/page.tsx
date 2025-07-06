"use client";

import { useState } from "react";
import type { NextPage } from "next";
import { useAccount } from "wagmi";
import { CogIcon, ShieldCheckIcon, ChartBarIcon } from "@heroicons/react/24/outline";
import { Address, AddressInput } from "~~/components/scaffold-eth";

const AdminPage: NextPage = () => {
  const { address: connectedAddress } = useAccount();
  const [newOracle, setNewOracle] = useState("");
  const [newFeeRate, setNewFeeRate] = useState("");
  const [userAddress, setUserAddress] = useState("");
  const [newScore, setNewScore] = useState("");
  const [isLoading, setIsLoading] = useState(false);

  const handleSetOracle = async () => {
    if (!newOracle) return;
    
    setIsLoading(true);
    try {
      // TODO: Implement contract interaction
      console.log("Setting oracle:", newOracle);
      setNewOracle("");
    } catch (error) {
      console.error("Error setting oracle:", error);
    } finally {
      setIsLoading(false);
    }
  };

  const handleSetFeeRate = async () => {
    if (!newFeeRate) return;
    
    setIsLoading(true);
    try {
      // TODO: Implement contract interaction
      console.log("Setting fee rate:", newFeeRate);
      setNewFeeRate("");
    } catch (error) {
      console.error("Error setting fee rate:", error);
    } finally {
      setIsLoading(false);
    }
  };

  const handleUpdateScore = async () => {
    if (!userAddress || !newScore) return;
    
    setIsLoading(true);
    try {
      // TODO: Implement contract interaction
      console.log("Updating score:", { userAddress, newScore });
      setUserAddress("");
      setNewScore("");
    } catch (error) {
      console.error("Error updating score:", error);
    } finally {
      setIsLoading(false);
    }
  };

  const handleComputePageRank = async () => {
    setIsLoading(true);
    try {
      // TODO: Implement contract interaction
      console.log("Computing PageRank scores");
    } catch (error) {
      console.error("Error computing PageRank:", error);
    } finally {
      setIsLoading(false);
    }
  };

  // Mock data
  const isAdmin = connectedAddress === "0x1234567890123456789012345678901234567890"; // Mock admin address
  const currentOracle = "0x1234567890123456789012345678901234567890";
  const currentFeeRate = "2.0%";
  const totalParticipants = 150;
  const totalLoans = 45;
  const totalVolume = "$125,000";

  if (!isAdmin) {
    return (
      <div className="flex items-center flex-col grow pt-10">
        <div className="px-5 w-full max-w-4xl">
          <div className="bg-red-100 border border-red-300 rounded-lg p-6 text-center">
            <ShieldCheckIcon className="h-12 w-12 text-red-500 mx-auto mb-4" />
            <h2 className="text-xl font-semibold text-red-800 mb-2">Access Denied</h2>
            <p className="text-red-600">
              You don&apos;t have permission to access the admin panel. Only contract owners and authorized oracles can access this page.
            </p>
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

          {/* System Overview */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">System Overview</h2>
            <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
              <div className="text-center">
                <div className="text-2xl font-bold text-blue-500">
                  {totalParticipants}
                </div>
                <div className="text-sm text-gray-600">Total Participants</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold text-green-500">
                  {totalLoans}
                </div>
                <div className="text-sm text-gray-600">Active Loans</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold text-purple-500">
                  {totalVolume}
                </div>
                <div className="text-sm text-gray-600">Total Volume</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold text-orange-500">
                  {currentFeeRate}
                </div>
                <div className="text-sm text-gray-600">Platform Fee</div>
              </div>
            </div>
          </div>

          {/* Oracle Management */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Oracle Management</h2>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
              <div>
                <h3 className="font-medium mb-2">Current Oracle</h3>
                <Address address={currentOracle as `0x${string}`} />
              </div>
              <div>
                <h3 className="font-medium mb-2">Set New Oracle</h3>
                <div className="flex gap-2">
                  <AddressInput
                    value={newOracle}
                    onChange={setNewOracle}
                    placeholder="Enter new oracle address"
                  />
                  <button
                    onClick={handleSetOracle}
                    disabled={!newOracle || isLoading}
                    className="bg-blue-500 hover:bg-blue-600 disabled:bg-gray-400 text-white font-bold py-2 px-4 rounded transition-colors"
                  >
                    {isLoading ? "..." : "Set"}
                  </button>
                </div>
              </div>
            </div>
          </div>

          {/* Fee Management */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Fee Management</h2>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
              <div>
                <h3 className="font-medium mb-2">Current Platform Fee</h3>
                <div className="text-2xl font-bold text-green-500">{currentFeeRate}</div>
              </div>
              <div>
                <h3 className="font-medium mb-2">Set New Fee Rate</h3>
                <div className="flex gap-2">
                  <input
                    type="number"
                    value={newFeeRate}
                    onChange={(e) => setNewFeeRate(e.target.value)}
                    placeholder="Enter fee rate (0-10)"
                    className="flex-1 p-2 border border-gray-300 rounded focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                    min="0"
                    max="10"
                    step="0.1"
                  />
                  <button
                    onClick={handleSetFeeRate}
                    disabled={!newFeeRate || isLoading}
                    className="bg-green-500 hover:bg-green-600 disabled:bg-gray-400 text-white font-bold py-2 px-4 rounded transition-colors"
                  >
                    {isLoading ? "..." : "Set"}
                  </button>
                </div>
                <div className="text-sm text-gray-600 mt-1">Fee rate in percentage (0-10%)</div>
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
                <h3 className="font-medium mb-2">PageRank Computation</h3>
                <p className="text-sm text-gray-600 mb-3">
                  Manually trigger PageRank score computation for all participants
                </p>
                <button
                  onClick={handleComputePageRank}
                  disabled={isLoading}
                  className="bg-orange-500 hover:bg-orange-600 disabled:bg-gray-400 text-white font-bold py-2 px-4 rounded transition-colors"
                >
                  {isLoading ? "Computing..." : "Compute PageRank"}
                </button>
              </div>
              <div>
                <h3 className="font-medium mb-2">System Health</h3>
                <div className="space-y-2 text-sm">
                  <div className="flex justify-between">
                    <span>Contract Status:</span>
                    <span className="text-green-500 font-medium">Healthy</span>
                  </div>
                  <div className="flex justify-between">
                    <span>Oracle Status:</span>
                    <span className="text-green-500 font-medium">Connected</span>
                  </div>
                  <div className="flex justify-between">
                    <span>Last Update:</span>
                    <span>2 minutes ago</span>
                  </div>
                </div>
              </div>
            </div>
          </div>

          {/* Admin Information */}
          <div className="bg-base-300 rounded-lg p-6">
            <h2 className="text-xl font-semibold mb-4">Admin Information</h2>
            <div className="space-y-4">
              <div>
                <h3 className="font-medium mb-2">Current Admin</h3>
                <Address address={connectedAddress as `0x${string}`} />
              </div>
              <div>
                <h3 className="font-medium mb-2">Permissions</h3>
                <ul className="text-sm text-gray-600 space-y-1">
                  <li>• Set and update oracle addresses</li>
                  <li>• Modify platform fee rates</li>
                  <li>• Update credit scores manually</li>
                  <li>• Trigger PageRank computations</li>
                  <li>• Access system statistics</li>
                </ul>
              </div>
              <div>
                <h3 className="font-medium mb-2">Security Notes</h3>
                <div className="text-sm text-gray-600 space-y-1">
                  <p>• Admin actions are irreversible and affect the entire system</p>
                  <p>• Always verify addresses and values before confirming changes</p>
                  <p>• Monitor system health after making changes</p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </>
  );
};

export default AdminPage; 