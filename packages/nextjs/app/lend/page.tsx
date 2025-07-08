"use client";

import { useState } from "react";
import type { NextPage } from "next";
import { useAccount } from "wagmi";
import { BanknotesIcon, PlusIcon, EyeIcon } from "@heroicons/react/24/outline";
import { Address } from "~~/components/scaffold-eth";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { parseEther } from "viem";

const LendPage: NextPage = () => {
  const { address: connectedAddress } = useAccount();
  const [depositAmount, setDepositAmount] = useState("");
  const [selectedLoanId, setSelectedLoanId] = useState<number | null>(null);
  const [isLoading, setIsLoading] = useState(false);

  // Contract hooks
  const { writeContractAsync: writeYourContractAsync } = useScaffoldWriteContract({
    contractName: "DecentralizedMicrocredit",
  });

  // Temporary fallback - empty data until contract is redeployed
  const poolInfo = [0n, 0n, 0n, 0n]; // [totalDeposits, availableFunds, totalEarned, activeLenders]
  const lenderInfo = [0n, 0n, 0n]; // [totalDeposited, availableToLend, earnedYield]
  const availableLoans: bigint[] = [];

  const handleDeposit = async () => {
    if (!depositAmount || !connectedAddress) return;
    
    setIsLoading(true);
    try {
      await writeYourContractAsync({
        functionName: "depositFunds",
        args: [parseEther(depositAmount)],
      });
      setDepositAmount("");
    } catch (error) {
      console.error("Error depositing funds:", error);
    } finally {
      setIsLoading(false);
    }
  };

  // TODO: These functions need to be added to the contract
  const handleFundLoan = async (loanId: number) => {
    console.log("Fund loan function not yet implemented in contract");
  };

  const handleClaimYield = async () => {
    console.log("Claim yield function not yet implemented in contract");
  };

  const getCreditScoreColor = (score: number) => {
    if (score < 30) return "text-red-500";
    if (score < 50) return "text-orange-500";
    if (score < 70) return "text-yellow-500";
    if (score < 90) return "text-blue-500";
    return "text-green-500";
  };

  // Format USDC amounts (assuming 6 decimals)
  const formatUSDC = (amount: bigint | undefined) => {
    if (!amount) return "$0.00";
    return `$${(Number(amount) / 1e6).toFixed(2)}`;
  };



  return (
    <>
      <div className="flex items-center flex-col grow pt-10">
        <div className="px-5 w-full max-w-6xl">
          <div className="flex items-center justify-center mb-8">
            <BanknotesIcon className="h-8 w-8 mr-3" />
            <h1 className="text-3xl font-bold">Lend Funds</h1>
          </div>

          {/* Pool Overview */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Lending Pool Overview</h2>
            <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
              <div className="text-center">
                <div className="text-2xl font-bold text-green-500">
                  {poolInfo ? formatUSDC(poolInfo[0]) : "$0.00"}
                </div>
                <div className="text-sm text-gray-600">Total Deposits</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold text-blue-500">
                  {poolInfo ? formatUSDC(poolInfo[1]) : "$0.00"}
                </div>
                <div className="text-sm text-gray-600">Available Funds</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold text-purple-500">
                  {poolInfo ? formatUSDC(poolInfo[2]) : "$0.00"}
                </div>
                <div className="text-sm text-gray-600">Total Earned</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold text-orange-500">
                  {poolInfo ? poolInfo[3].toString() : "0"}
                </div>
                <div className="text-sm text-gray-600">Active Lenders</div>
              </div>
            </div>
          </div>

          {/* Your Lender Profile */}
          {connectedAddress && (
            <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
              <h2 className="text-xl font-semibold mb-4">Your Lender Profile</h2>
              <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
                <div>
                  <h3 className="font-medium mb-2">Total Deposited</h3>
                  <div className="text-2xl font-bold text-green-500">
                    {lenderInfo ? formatUSDC(lenderInfo[0]) : "$0.00"} USDC
                  </div>
                </div>
                <div>
                  <h3 className="font-medium mb-2">Available to Lend</h3>
                  <div className="text-2xl font-bold text-blue-500">
                    {lenderInfo ? formatUSDC(lenderInfo[1]) : "$0.00"} USDC
                  </div>
                </div>
                <div>
                  <h3 className="font-medium mb-2">Earned Yield</h3>
                  <div className="text-2xl font-bold text-purple-500">
                    {lenderInfo ? formatUSDC(lenderInfo[2]) : "$0.00"} USDC
                  </div>
                </div>
              </div>
              
              {/* Action Buttons */}
              <div className="flex gap-4 mt-6">
                <button
                  onClick={handleClaimYield}
                  disabled={isLoading || !lenderInfo || lenderInfo[2] === 0n}
                  className="bg-purple-500 hover:bg-purple-600 disabled:bg-gray-400 text-white font-bold py-2 px-4 rounded-lg transition-colors"
                >
                  Claim Yield
                </button>
              </div>
            </div>
          )}

          {/* Deposit Funds */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4 flex items-center">
              <PlusIcon className="h-6 w-6 mr-2" />
              Deposit Funds
            </h2>
            <div className="flex gap-4">
              <input
                type="number"
                value={depositAmount}
                onChange={(e) => setDepositAmount(e.target.value)}
                placeholder="Enter amount in USDC"
                className="flex-1 p-3 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                min="1"
              />
              <button
                onClick={handleDeposit}
                disabled={!depositAmount || !connectedAddress || isLoading}
                className="bg-blue-500 hover:bg-blue-600 disabled:bg-gray-400 text-white font-bold py-3 px-6 rounded-lg transition-colors"
              >
                {isLoading ? "Depositing..." : "Deposit"}
              </button>
            </div>
          </div>

          {/* Available Loans */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Available Loans to Fund</h2>
            
            {!availableLoans || availableLoans.length === 0 ? (
              <div className="text-center py-8 text-gray-600">
                No loans available for funding at the moment.
              </div>
            ) : (
              <div className="space-y-4">
                {availableLoans.map((loanId) => (
                  <AvailableLoanCard 
                    key={loanId.toString()} 
                    loanId={loanId} 
                    onFund={handleFundLoan}
                    onViewDetails={() => setSelectedLoanId(selectedLoanId === Number(loanId) ? null : Number(loanId))}
                    isSelected={selectedLoanId === Number(loanId)}
                    isLoading={isLoading}
                  />
                ))}
              </div>
            )}
          </div>

          {/* How Lending Works */}
          <div className="bg-base-300 rounded-lg p-6">
            <h2 className="text-xl font-semibold mb-4">How Lending Works</h2>
            <div className="space-y-4">
              <div className="flex items-start space-x-3">
                <div className="bg-blue-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                  1
                </div>
                <div>
                  <h3 className="font-medium">Deposit Funds</h3>
                  <p className="text-gray-600">Add USDC to the lending pool to start earning yield</p>
                </div>
              </div>
              <div className="flex items-start space-x-3">
                <div className="bg-blue-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                  2
                </div>
                <div>
                  <h3 className="font-medium">Fund Loans</h3>
                  <p className="text-gray-600">Your funds are automatically allocated to loan requests</p>
                </div>
              </div>
              <div className="flex items-start space-x-3">
                <div className="bg-blue-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                  3
                </div>
                <div>
                  <h3 className="font-medium">Earn Interest</h3>
                  <p className="text-gray-600">Receive interest payments when borrowers repay their loans</p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </>
  );
};

// Component for displaying individual loan cards
const AvailableLoanCard = ({ 
  loanId, 
  onFund, 
  onViewDetails, 
  isSelected, 
  isLoading 
}: { 
  loanId: bigint; 
  onFund: (id: number) => void; 
  onViewDetails: () => void; 
  isSelected: boolean; 
  isLoading: boolean; 
}) => {
  const { data: loanDetails } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getLoan",
    args: [loanId],
  });

  const { data: borrowerScore } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getCreditScore",
    args: [loanDetails?.[2] as `0x${string}`],
  });

  const formatUSDC = (amount: bigint | undefined) => {
    if (!amount) return "$0.00";
    return `$${(Number(amount) / 1e6).toFixed(2)}`;
  };

  const formatInterestRate = (rate: bigint | undefined) => {
    if (!rate) return "0%";
    return `${(Number(rate) / 100).toFixed(2)}%`;
  };

  const getCreditScoreColor = (score: bigint | undefined) => {
    if (!score) return "text-gray-500";
    const scoreNum = Number(score) / 1e4; // Convert from basis points
    if (scoreNum < 30) return "text-red-500";
    if (scoreNum < 50) return "text-orange-500";
    if (scoreNum < 70) return "text-yellow-500";
    if (scoreNum < 90) return "text-blue-500";
    return "text-green-500";
  };

  if (!loanDetails) {
    return (
      <div className="border border-gray-200 rounded-lg p-4">
        <div className="text-center text-gray-600">Loading loan details...</div>
      </div>
    );
  }

  // Destructure the loan details: (principal, outstanding, borrower, interestRate, isActive)
  const [principal, outstanding, borrower, interestRate, isActive] = loanDetails;

  return (
    <div className="border border-gray-200 rounded-lg p-4">
      <div className="grid grid-cols-1 md:grid-cols-5 gap-4 items-center">
        <div>
          <div className="font-medium">Borrower</div>
          <Address address={borrower as `0x${string}`} />
        </div>
        <div>
          <div className="font-medium">Amount</div>
          <div className="text-lg font-bold">{formatUSDC(principal)} USDC</div>
        </div>
        <div>
          <div className="font-medium">Interest Rate</div>
          <div className="text-lg font-bold text-green-500">{formatInterestRate(interestRate)} APR</div>
        </div>
        <div>
          <div className="font-medium">Status</div>
          <div className={`text-lg font-bold ${isActive ? 'text-green-500' : 'text-gray-500'}`}>
            {isActive ? 'Active' : 'Inactive'}
          </div>
        </div>
        <div>
          <div className="font-medium">Credit Score</div>
          <div className={`text-lg font-bold ${getCreditScoreColor(borrowerScore)}`}>
            {borrowerScore ? `${(Number(borrowerScore) / 1e4).toFixed(1)}%` : "N/A"}
          </div>
        </div>
      </div>
      
      <div className="flex gap-2 mt-4">
        <button
          onClick={onViewDetails}
          className="bg-gray-500 hover:bg-gray-600 text-white font-bold py-2 px-4 rounded-lg transition-colors flex items-center"
        >
          <EyeIcon className="h-4 w-4 mr-2" />
          View Details
        </button>
        <button
          onClick={() => onFund(Number(loanId))}
          disabled={isLoading || !isActive}
          className="bg-green-500 hover:bg-green-600 disabled:bg-gray-400 text-white font-bold py-2 px-4 rounded-lg transition-colors"
        >
          {isLoading ? "Funding..." : "Fund Loan"}
        </button>
      </div>

      {/* Loan Details (expandable) */}
      {isSelected && (
        <div className="mt-4 p-4 bg-base-200 rounded-lg">
          <h4 className="font-medium mb-2">Loan Details</h4>
          <div className="grid grid-cols-2 gap-4 text-sm">
            <div>
              <span className="text-gray-600">Principal:</span>
              <div className="font-medium">{formatUSDC(principal)}</div>
            </div>
            <div>
              <span className="text-gray-600">Outstanding:</span>
              <div className="font-medium">{formatUSDC(outstanding)}</div>
            </div>
            <div>
              <span className="text-gray-600">Interest Rate:</span>
              <div className="font-medium">{formatInterestRate(interestRate)} APR</div>
            </div>
            <div>
              <span className="text-gray-600">Status:</span>
              <div className="font-medium">{isActive ? 'Active' : 'Inactive'}</div>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};

export default LendPage; 