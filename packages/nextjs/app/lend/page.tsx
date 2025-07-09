"use client";

import { useState } from "react";
import type { NextPage } from "next";
import { useAccount } from "wagmi";
import { formatUSDC, getCreditScoreColor } from "~~/utils/format";
import { BanknotesIcon, PlusIcon, EyeIcon } from "@heroicons/react/24/outline";
import { Address } from "~~/components/scaffold-eth";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import HowItWorks from "~~/components/HowItWorks";
// removed parseEther import because USDC uses 6 decimals

const LendPage: NextPage = () => {
  const { address: connectedAddress } = useAccount();
  const [depositAmount, setDepositAmount] = useState("");
  const [selectedLoanId, setSelectedLoanId] = useState<number | null>(null);
  const [isLoading, setIsLoading] = useState(false);

  // Contract hooks
  const { writeContractAsync } = useScaffoldWriteContract({
    contractName: "DecentralizedMicrocredit",
  });

  // Remove placeholder arrays and fetch on-chain data
  const { data: poolInfo } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getPoolInfo",
  });

  // poolInfo returns [_totalDeposits, _availableFunds, _lenderCount]
  const totalDeposits = poolInfo ? poolInfo[0] : undefined;
  const availableFunds = poolInfo ? poolInfo[1] : undefined;
  const lenderCount = poolInfo ? poolInfo[2] : undefined;
  // TODO: replace these with real data once contract supports them
  const lenderInfo: bigint[] | undefined = undefined;
  const availableLoans: bigint[] = [];

  const handleDeposit = async () => {
    if (!depositAmount || !connectedAddress) return;
    
    setIsLoading(true);
    try {
      // Convert USDC (6-decimals) string amount to integer with 6 decimals
      const amountInt = BigInt(Math.floor(parseFloat(depositAmount) * 1e6));
      await writeContractAsync({
        functionName: "depositFunds",
        args: [amountInt],
      });
      setDepositAmount("");
    } catch (error) {
      console.error("Error depositing funds:", error);
    } finally {
      setIsLoading(false);
    }
  };

  const handleFundLoan = async (loanId: number) => {
    // TODO: Implement fund loan functionality when contract is updated
  };

  const handleClaimYield = async () => {
    // TODO: Implement claim yield functionality when contract is updated
  };

  // imported helpers handle color & formatting


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
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
              <div className="text-center">
                <div className="text-2xl font-bold text-green-500">
                  {totalDeposits !== undefined ? formatUSDC(totalDeposits) : "Loading..."}
                </div>
                <div className="text-sm text-gray-600">Total Deposits</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold text-blue-500">
                  {availableFunds !== undefined ? formatUSDC(availableFunds) : "Loading..."}
                </div>
                <div className="text-sm text-gray-600">Available Funds</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold text-orange-500">
                  {lenderCount !== undefined ? lenderCount.toString() : "Loading..."}
                </div>
                <div className="text-sm text-gray-600">Active Lenders</div>
              </div>
            </div>
          </div>

          {/* Lender-specific stats will be added once contract exposes them */}

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

          {/* How Lending Works */}
          <HowItWorks
            title="How Lending Works"
            steps={[
              { icon: null, title: "Deposit Funds", description: "Add USDC to the shared pool" },
              { icon: null, title: "Automatic Allocation", description: "Protocol distributes liquidity to qualified borrowers" },
              { icon: null, title: "Earn Interest", description: "Interest accrues to your share of the pool" },
            ]}
          />
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

  const formatInterestRate = (rate: bigint | undefined) => {
    if (!rate) return "0%";
    return `${(Number(rate) / 100).toFixed(2)}%`;
  };

  const getCreditScoreColorStyle = (score: bigint | undefined) => {
    if (!score) return "text-gray-500";
    return getCreditScoreColor(Number(score) / 1e4);
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
          <div className={`text-lg font-bold ${getCreditScoreColorStyle(borrowerScore)}`}>
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