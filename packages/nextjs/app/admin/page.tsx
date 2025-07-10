"use client";

import { useState } from "react";
import type { NextPage } from "next";
import { useAccount } from "wagmi";
import { CogIcon, ShieldCheckIcon } from "@heroicons/react/24/outline";
import { Address, AddressInput } from "~~/components/scaffold-eth";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { formatPercent } from "~~/utils/format";

const AdminPage: NextPage = () => {
  const { address: connectedAddress } = useAccount();
  const [userAddress, setUserAddress] = useState("");
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
  const { writeContractAsync } = useScaffoldWriteContract({
    contractName: "DecentralizedMicrocredit",
  });

  // Removed manual credit score management – scores are now computed automatically from PageRank

  // Additional whitelisted admin addresses
  const ADDITIONAL_ADMINS = [
    "0x8b45296027564EF1e472EEa87B4D03BBF9DAD149".toLowerCase(),
  ];

  // Check permissions
  const isOwner = connectedAddress && owner && connectedAddress.toLowerCase() === owner.toLowerCase();
  const isOracle = oracle && connectedAddress && connectedAddress.toLowerCase() === oracle.toLowerCase();
  const isWhitelisted = connectedAddress ? ADDITIONAL_ADMINS.includes(connectedAddress.toLowerCase()) : false;
  const hasAccess = isOwner || isOracle || isWhitelisted;

  // Credit score lookup
  const [lookupAddress, setLookupAddress] = useState<string>("");
  const { data: lookupScore } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getPageRankScore",
    args: [lookupAddress as `0x${string}` | undefined],
  });

  // Lender lookup state
  const [lenderLookup, setLenderLookup] = useState<string>("");
  const { data: lenderDeposit } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "lenderDeposits",
    args: [lenderLookup as `0x${string}` | undefined],
  });
  const { data: poolInfo } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getPoolInfo",
  });
  const availableFunds = poolInfo ? poolInfo[1] : undefined;
  const lenderCount = poolInfo ? poolInfo[3] : undefined;
  const [withdrawAmount, setWithdrawAmount] = useState("");
  const [withdrawLoading, setWithdrawLoading] = useState(false);

  const handleWithdraw = async () => {
    if (!withdrawAmount || !connectedAddress) return;
    setWithdrawLoading(true);
    try {
      await writeContractAsync({
        functionName: "withdrawFunds",
        args: [BigInt(Math.floor(parseFloat(withdrawAmount) * 1e6))],
      });
      setWithdrawAmount("");
    } catch (error) {
      console.error("Error withdrawing funds:", error);
    } finally {
      setWithdrawLoading(false);
    }
  };

  // Helper to get lenderDeposit as a number (USDC)
  const lenderDepositNumber = lenderDeposit !== undefined ? Number(lenderDeposit) : 0;
  const availableFundsNumber = availableFunds !== undefined ? Number(availableFunds) : 0;

  // Show access denied if user doesn't have permissions
  if (!hasAccess) {
    return (
      <div className="flex items-center justify-center min-h-screen">
        <div className="text-center">
          <ShieldCheckIcon className="h-16 w-16 mx-auto text-red-500 mb-4" />
          <h1 className="text-2xl font-bold text-red-500 mb-2">Access Denied</h1>
          <p className="text-gray-600 mb-4">
            You need to be the contract owner, oracle, or whitelisted to access this page.
          </p>
          <div className="space-y-2 text-sm text-gray-500">
            <div>Current Oracle: {oracle ? <Address address={oracle as `0x${string}`} /> : "Loading..."}</div>
            <div>Contract Owner: {owner ? <Address address={owner as `0x${string}`} /> : "Loading..."}</div>
            <div>Your Address: {connectedAddress ? <Address address={connectedAddress} /> : "Not connected"}</div>
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

          {/* Lender Management */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Lender Management</h2>
            <div className="mb-4">
              <label className="block text-sm font-medium mb-2">Lender Address Lookup</label>
              <AddressInput value={lenderLookup} onChange={setLenderLookup} placeholder="0x..." />
              <div className="mt-2 text-sm">
                {lenderDeposit !== undefined && lenderDepositNumber > 0 ? (
                  <span>Deposit Balance: {(lenderDepositNumber / 1e6).toLocaleString()} USDC</span>
                ) : (
                  <span>No deposit found for this address.</span>
                )}
              </div>
            </div>
            <div className="mb-4">
              <span className="text-sm">Total Lenders: {lenderCount !== undefined ? lenderCount.toString() : "Loading..."}</span>
            </div>
            {connectedAddress && lenderLookup.toLowerCase() === connectedAddress.toLowerCase() && lenderDepositNumber > 0 && (
              <div className="mt-4">
                <label className="block text-sm font-medium mb-2">Withdraw Amount (USDC)</label>
                <input
                  type="number"
                  value={withdrawAmount}
                  onChange={e => setWithdrawAmount(e.target.value)}
                  min="0.000001"
                  max={Math.min(lenderDepositNumber / 1e6, availableFundsNumber / 1e6)}
                  step="0.000001"
                  className="w-full p-2 border border-gray-300 rounded focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                  placeholder="Enter amount to withdraw"
                />
                <button
                  onClick={handleWithdraw}
                  disabled={withdrawLoading || !withdrawAmount || Number(withdrawAmount) <= 0 || Number(withdrawAmount) > lenderDepositNumber / 1e6 || Number(withdrawAmount) > availableFundsNumber / 1e6}
                  className="w-full bg-blue-500 hover:bg-blue-600 disabled:bg-gray-400 text-white font-bold py-2 px-4 rounded transition-colors mt-2"
                >
                  {withdrawLoading ? "Withdrawing..." : "Withdraw"}
                </button>
              </div>
            )}
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
                    <span>Role: {isOwner ? "Owner" : isOracle ? "Oracle" : isWhitelisted ? "Whitelisted" : "None"}</span>
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