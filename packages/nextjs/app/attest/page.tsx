"use client";

import { useState } from "react";
import type { NextPage } from "next";
import { useAccount } from "wagmi";
import { HandThumbUpIcon } from "@heroicons/react/24/outline";
import { Address, AddressInput } from "~~/components/scaffold-eth";

const AttestPage: NextPage = () => {
  const { address: connectedAddress } = useAccount();
  const [borrowerAddress, setBorrowerAddress] = useState("");
  const [weight, setWeight] = useState(50); // Default 50% confidence
  const [isLoading, setIsLoading] = useState(false);

  const handleAttest = async () => {
    if (!borrowerAddress || !connectedAddress) return;
    
    setIsLoading(true);
    try {
      // TODO: Implement contract interaction
      console.log("Recording attestation:", { borrowerAddress, weight });
      setBorrowerAddress("");
      setWeight(50);
    } catch (error) {
      console.error("Error recording attestation:", error);
    } finally {
      setIsLoading(false);
    }
  };

  const getWeightLabel = (value: number) => {
    if (value < 20) return "Very Low";
    if (value < 40) return "Low";
    if (value < 60) return "Medium";
    if (value < 80) return "High";
    return "Very High";
  };

  const getWeightColor = (value: number) => {
    if (value < 20) return "text-red-500";
    if (value < 40) return "text-orange-500";
    if (value < 60) return "text-yellow-500";
    if (value < 80) return "text-blue-500";
    return "text-green-500";
  };

  return (
    <>
      <div className="flex items-center flex-col grow pt-10">
        <div className="px-5 w-full max-w-4xl">
          <div className="flex items-center justify-center mb-8">
            <HandThumbUpIcon className="h-8 w-8 mr-3" />
            <h1 className="text-3xl font-bold">Make Attestation</h1>
          </div>

          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Attest to Creditworthiness</h2>
            <p className="text-gray-600 mb-6">
              Provide a confidence rating for someone&apos;s ability to repay loans. Your attestation will influence their PageRank-based credit score.
            </p>

            <div className="space-y-6">
              {/* Borrower Address Input */}
              <div>
                <label className="block text-sm font-medium mb-2">Borrower Address</label>
                <AddressInput
                  value={borrowerAddress}
                  onChange={setBorrowerAddress}
                  placeholder="Enter borrower's address"
                />
              </div>

              {/* Confidence Weight Slider */}
              <div>
                <label className="block text-sm font-medium mb-2">
                  Confidence Level: {weight}% ({getWeightLabel(weight)})
                </label>
                <input
                  type="range"
                  min="1"
                  max="100"
                  value={weight}
                  onChange={(e) => setWeight(Number(e.target.value))}
                  className="w-full h-2 bg-gray-200 rounded-lg appearance-none cursor-pointer"
                />
                <div className="flex justify-between text-xs text-gray-500 mt-1">
                  <span>Very Low</span>
                  <span>Low</span>
                  <span>Medium</span>
                  <span>High</span>
                  <span>Very High</span>
                </div>
              </div>

              {/* Attestation Button */}
              <button
                onClick={handleAttest}
                disabled={!borrowerAddress || !connectedAddress || isLoading}
                className="w-full bg-blue-500 hover:bg-blue-600 disabled:bg-gray-400 text-white font-bold py-3 px-4 rounded-lg transition-colors"
              >
                {isLoading ? "Recording Attestation..." : "Record Attestation"}
              </button>
            </div>
          </div>

          {/* Borrower Information */}
          {borrowerAddress && (
            <div className="bg-base-100 rounded-lg p-6 shadow-lg">
              <h2 className="text-xl font-semibold mb-4">Borrower Information</h2>
              
              <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                <div>
                  <h3 className="font-medium mb-2">Address</h3>
                  <Address address={borrowerAddress as `0x${string}`} />
                </div>
                
                <div>
                  <h3 className="font-medium mb-2">Credit Score</h3>
                  <div className="text-lg font-bold text-green-500">
                    Not available (demo mode)
                  </div>
                </div>
              </div>
            </div>
          )}

          {/* How Attestations Work */}
          <div className="mt-8 bg-base-300 rounded-lg p-6">
            <h2 className="text-xl font-semibold mb-4">How Attestations Work</h2>
            <div className="space-y-4">
              <div className="flex items-start space-x-3">
                <div className="bg-blue-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                  1
                </div>
                <div>
                  <h3 className="font-medium">Build Trust Network</h3>
                  <p className="text-gray-600">Attestations create a social graph of trust relationships</p>
                </div>
              </div>
              <div className="flex items-start space-x-3">
                <div className="bg-blue-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                  2
                </div>
                <div>
                  <h3 className="font-medium">PageRank Algorithm</h3>
                  <p className="text-gray-600">The system uses PageRank to calculate credit scores based on attestation weights</p>
                </div>
              </div>
              <div className="flex items-start space-x-3">
                <div className="bg-blue-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                  3
                </div>
                <div>
                  <h3 className="font-medium">Credit Score Impact</h3>
                  <p className="text-gray-600">Higher credit scores lead to better loan terms and lower interest rates</p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </>
  );
};

export default AttestPage; 