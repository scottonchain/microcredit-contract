"use client";

import { NextPage } from "next";
import { useState } from "react";
import { useAccount } from "wagmi";
import { useScaffoldWriteContract, useScaffoldReadContract } from "~~/hooks/scaffold-eth";
import { CurrencyDollarIcon, EyeIcon } from "@heroicons/react/24/outline";

const RepayPage: NextPage = () => {
  const { address: connectedAddress } = useAccount();
  const [selectedLoanId, setSelectedLoanId] = useState<number | null>(null);
  const [repayAmount, setRepayAmount] = useState("");
  const [isLoading, setIsLoading] = useState(false);

  // For now, we'll use a placeholder array since there's no function to get user loans
  const userLoans: bigint[] = [];

  const { writeContractAsync: writeYourContractAsync } = useScaffoldWriteContract({
    contractName: "DecentralizedMicrocredit",
  });

  const handleFullRepayment = async (loanId: number) => {
    setIsLoading(true);
    try {
      // For now, we'll use a placeholder outstanding amount
      // In a real implementation, you'd get this from the loan details
      const outstandingAmount = BigInt(1000000); // 1 USDC as placeholder
      await writeYourContractAsync({
        functionName: "repayLoan",
        args: [BigInt(loanId), outstandingAmount],
      });
    } catch (error) {
      console.error("Error repaying loan:", error);
    } finally {
      setIsLoading(false);
    }
  };

  const handlePartialRepayment = async (loanId: number) => {
    if (!repayAmount) return;
    
    setIsLoading(true);
    try {
      await writeYourContractAsync({
        functionName: "repayLoan",
        args: [BigInt(loanId), BigInt(parseFloat(repayAmount) * 1e6)], // Convert to USDC with 6 decimals
      });
      setRepayAmount("");
    } catch (error) {
      console.error("Error making partial repayment:", error);
    } finally {
      setIsLoading(false);
    }
  };

  const getStatusColor = (isActive: boolean) => {
    if (!isActive) return "text-gray-500";
    return "text-green-500";
  };

  const getStatusText = (isActive: boolean) => {
    if (!isActive) return "Repaid";
    return "Active";
  };

  // Calculate summary statistics
  const calculateSummary = () => {
    if (!userLoans || userLoans.length === 0) {
      return { activeLoans: 0, totalBorrowed: 0n, outstandingBalance: 0n, overdueCount: 0 };
    }

    let activeLoans = 0;
    let totalBorrowed = 0n;
    let outstandingBalance = 0n;
    let overdueCount = 0;

    // This would need to be implemented with individual loan queries
    // For now, we'll show basic counts
    activeLoans = userLoans.length;

    return { activeLoans, totalBorrowed, outstandingBalance, overdueCount };
  };

  const summary = calculateSummary();

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
            <CurrencyDollarIcon className="h-8 w-8 mr-3" />
            <h1 className="text-3xl font-bold">Repay Loans</h1>
          </div>

          {/* Loan Summary */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Your Loan Summary</h2>
            <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
              <div className="text-center">
                <div className="text-2xl font-bold text-blue-500">
                  {summary.activeLoans}
                </div>
                <div className="text-sm text-gray-600">Active Loans</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold text-green-500">
                  {formatUSDC(summary.totalBorrowed)}
                </div>
                <div className="text-sm text-gray-600">Total Borrowed</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold text-orange-500">
                  {formatUSDC(summary.outstandingBalance)}
                </div>
                <div className="text-sm text-gray-600">Outstanding Balance</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold text-purple-500">
                  {summary.overdueCount}
                </div>
                <div className="text-sm text-gray-600">Overdue Loans</div>
              </div>
            </div>
          </div>

          {/* Your Loans */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Your Active Loans</h2>
            
            {!userLoans || userLoans.length === 0 ? (
              <div className="text-center py-8 text-gray-600">
                You don&apos;t have any active loans.
              </div>
            ) : (
              <div className="space-y-4">
                {userLoans.map((loanId) => (
                  <UserLoanCard 
                    key={loanId.toString()} 
                    loanId={loanId} 
                    onFullRepayment={handleFullRepayment}
                    onPartialRepayment={handlePartialRepayment}
                    onViewDetails={() => setSelectedLoanId(selectedLoanId === Number(loanId) ? null : Number(loanId))}
                    isSelected={selectedLoanId === Number(loanId)}
                    isLoading={isLoading}
                    repayAmount={repayAmount}
                    setRepayAmount={setRepayAmount}
                  />
                ))}
              </div>
            )}
          </div>

          {/* Repayment Tips */}
          <div className="bg-base-300 rounded-lg p-6">
            <h2 className="text-xl font-semibold mb-4">Repayment Tips</h2>
            <div className="space-y-4">
              <div className="flex items-start space-x-3">
                <div className="flex-shrink-0 w-6 h-6 bg-green-100 rounded-full flex items-center justify-center">
                  <span className="text-green-600 text-sm font-bold">1</span>
                </div>
                <div>
                  <h3 className="font-medium text-gray-900">Pay on time</h3>
                  <p className="text-gray-600">Avoid late fees by making payments before the due date.</p>
                </div>
              </div>
              <div className="flex items-start space-x-3">
                <div className="flex-shrink-0 w-6 h-6 bg-blue-100 rounded-full flex items-center justify-center">
                  <span className="text-blue-600 text-sm font-bold">2</span>
                </div>
                <div>
                  <h3 className="font-medium text-gray-900">Consider partial payments</h3>
                  <p className="text-gray-600">You can make partial payments to reduce your outstanding balance.</p>
                </div>
              </div>
              <div className="flex items-start space-x-3">
                <div className="flex-shrink-0 w-6 h-6 bg-purple-100 rounded-full flex items-center justify-center">
                  <span className="text-purple-600 text-sm font-bold">3</span>
                </div>
                <div>
                  <h3 className="font-medium text-gray-900">Monitor your credit score</h3>
                  <p className="text-gray-600">Timely repayments improve your credit score and future loan terms.</p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </>
  );
};

// Component for displaying individual user loan cards
const UserLoanCard = ({ 
  loanId, 
  onFullRepayment, 
  onPartialRepayment, 
  onViewDetails, 
  isSelected, 
  isLoading,
  repayAmount,
  setRepayAmount
}: { 
  loanId: bigint; 
  onFullRepayment: (id: number) => void; 
  onPartialRepayment: (id: number) => void; 
  onViewDetails: () => void; 
  isSelected: boolean; 
  isLoading: boolean;
  repayAmount: string;
  setRepayAmount: (amount: string) => void;
}) => {
  const { data: loanDetails } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getLoan",
    args: [loanId],
  });

  const formatUSDC = (amount: bigint | undefined) => {
    if (!amount) return "$0.00";
    return `$${(Number(amount) / 1e6).toFixed(2)}`;
  };

  const formatInterestRate = (rate: bigint | undefined) => {
    if (!rate) return "0%";
    return `${(Number(rate) / 100).toFixed(2)}%`;
  };

  const getStatusColor = (isActive: boolean) => {
    if (!isActive) return "text-gray-500";
    return "text-green-500";
  };

  const getStatusText = (isActive: boolean) => {
    if (!isActive) return "Repaid";
    return "Active";
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
          <div className="font-medium">Loan ID</div>
          <div className="text-lg font-bold">#{loanId.toString()}</div>
        </div>
        <div>
          <div className="font-medium">Principal</div>
          <div className="text-lg font-bold">{formatUSDC(principal)} USDC</div>
        </div>
        <div>
          <div className="font-medium">Outstanding</div>
          <div className="text-lg font-bold text-orange-500">{formatUSDC(outstanding)} USDC</div>
        </div>
        <div>
          <div className="font-medium">Interest Rate</div>
          <div className="text-lg font-bold text-blue-500">{formatInterestRate(interestRate)} APR</div>
        </div>
        <div>
          <div className="font-medium">Status</div>
          <div className={`text-lg font-bold ${getStatusColor(isActive)}`}>
            {getStatusText(isActive)}
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
        {isActive && (
          <>
            <button
              onClick={() => onFullRepayment(Number(loanId))}
              disabled={isLoading}
              className="bg-green-500 hover:bg-green-600 disabled:bg-gray-400 text-white font-bold py-2 px-4 rounded-lg transition-colors"
            >
              {isLoading ? "Repaying..." : "Full Repayment"}
            </button>
            <button
              onClick={() => onPartialRepayment(Number(loanId))}
              disabled={isLoading || !repayAmount}
              className="bg-blue-500 hover:bg-blue-600 disabled:bg-gray-400 text-white font-bold py-2 px-4 rounded-lg transition-colors"
            >
              {isLoading ? "Repaying..." : "Partial Repayment"}
            </button>
          </>
        )}
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
              <div className="font-medium">{getStatusText(isActive)}</div>
            </div>
          </div>
          
          {/* Partial Repayment Form */}
          {isActive && (
            <div className="mt-4 pt-4 border-t border-gray-300">
              <h5 className="font-medium mb-2">Partial Repayment</h5>
              <div className="flex gap-2">
                <input
                  type="number"
                  value={repayAmount}
                  onChange={(e) => setRepayAmount(e.target.value)}
                  placeholder="Enter amount in USDC"
                  className="flex-1 p-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                  min="0.01"
                  step="0.01"
                />
                <button
                  onClick={() => onPartialRepayment(Number(loanId))}
                  disabled={isLoading || !repayAmount}
                  className="bg-blue-500 hover:bg-blue-600 disabled:bg-gray-400 text-white font-bold py-2 px-4 rounded-lg transition-colors"
                >
                  {isLoading ? "Repaying..." : "Repay"}
                </button>
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
};

export default RepayPage; 