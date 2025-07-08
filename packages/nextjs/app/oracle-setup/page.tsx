"use client";

import { useState } from "react";
import type { NextPage } from "next";
import { useAccount } from "wagmi";
import { CogIcon, ShieldCheckIcon } from "@heroicons/react/24/outline";
import { Address } from "~~/components/scaffold-eth";
import { useScaffoldReadContract } from "~~/hooks/scaffold-eth";

const OracleSetupPage: NextPage = () => {
  const { address: connectedAddress } = useAccount();

  // Read contract data - always call hooks at the top level
  const { data: oracle } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "oracle",
  });

  const { data: owner } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "owner",
  });

  const isOwner = connectedAddress && owner && connectedAddress.toLowerCase() === owner.toLowerCase();
  const isOracle = oracle && connectedAddress && connectedAddress.toLowerCase() === oracle.toLowerCase();

  return (
    <>
      <div className="flex items-center flex-col grow pt-10">
        <div className="px-5 w-full max-w-4xl">
          <div className="flex items-center justify-center mb-8">
            <CogIcon className="h-8 w-8 mr-3" />
            <h1 className="text-3xl font-bold">Oracle Setup</h1>
          </div>

          {/* Current Status */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Current Status</h2>
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

          {/* Your Address */}
          {connectedAddress && (
            <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
              <h2 className="text-xl font-semibold mb-4">Your Address</h2>
              <Address address={connectedAddress} />
              <div className="mt-4 space-y-2">
                <div className={`flex items-center space-x-2 ${isOwner ? 'text-green-600' : 'text-red-600'}`}>
                  <ShieldCheckIcon className="h-5 w-5" />
                  <span>{isOwner ? 'You are the contract owner' : 'You are not the contract owner'}</span>
                </div>
                <div className={`flex items-center space-x-2 ${isOracle ? 'text-green-600' : 'text-red-600'}`}>
                  <ShieldCheckIcon className="h-5 w-5" />
                  <span>{isOracle ? 'You are the oracle' : 'You are not the oracle'}</span>
                </div>
              </div>
            </div>
          )}

          {/* Instructions */}
          <div className="bg-base-300 rounded-lg p-6">
            <h2 className="text-xl font-semibold mb-4">How to Access Admin Page</h2>
            <div className="space-y-4">
              <div className="flex items-start space-x-3">
                <div className="bg-blue-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                  1
                </div>
                <div>
                  <h3 className="font-medium">Check Current Status</h3>
                  <p className="text-gray-600">Verify if you are the owner or oracle above</p>
                </div>
              </div>
              <div className="flex items-start space-x-3">
                <div className="bg-blue-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                  2
                </div>
                <div>
                  <h3 className="font-medium">If You&apos;re the Owner</h3>
                  <p className="text-gray-600">Use the debug page to call setOracle and set yourself as the oracle</p>
                </div>
              </div>
              <div className="flex items-start space-x-3">
                <div className="bg-blue-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                  3
                </div>
                <div>
                  <h3 className="font-medium">If You&apos;re Not the Owner</h3>
                  <p className="text-gray-600">Ask the contract owner to set you as the oracle, or use the debug page to call setOracle directly</p>
                </div>
              </div>
              <div className="flex items-start space-x-3">
                <div className="bg-blue-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                  4
                </div>
                <div>
                  <h3 className="font-medium">Access Admin Page</h3>
                  <p className="text-gray-600">Once you&apos;re the oracle, you can access <a href="/admin" className="text-blue-500 underline">/admin</a> to manage the system</p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </>
  );
};

export default OracleSetupPage; 