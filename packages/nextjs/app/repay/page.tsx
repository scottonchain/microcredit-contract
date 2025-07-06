"use client";

import { useState } from "react";
import type { NextPage } from "next";
import { useAccount } from "wagmi";
import { CurrencyDollarIcon, ClockIcon, ExclamationTriangleIcon } from "@heroicons/react/24/outline";
import { Address } from "~~/components/scaffold-eth";

const RepayPage: NextPage = () => {
  const { address: connectedAddress } = useAccount();
  const [selectedLoanId, setSelectedLoanId] = useState<number | null>(null);
  const [repayAmount, setRepayAmount] = useState("");
  const [isLoading, setIsLoading] = useState(false);

  const handleFullRepayment = async (loanId: number) => {
    setIsLoading(true);
    try {
      // TODO: Implement contract interaction
      console.log("Full repayment for loan:", loanId);
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
      // TODO: Implement contract interaction
      console.log("Partial repayment:", { loanId, repayAmount });
      setRepayAmount("");
    } catch (error) {
      console.error("Error making partial repayment:", error);
    } finally {
      setIsLoading(false);
    }
  };

  const formatDate = (timestamp: number) => {
    return new Date(timestamp).toLocaleDateString();
  };

  const getDaysUntilDue = (dueDate: number) => {
    const days = Math.ceil((dueDate - Date.now()) / (1000 * 60 * 60 * 24));
    return days;
  };

  const getStatusColor = (loan: any) => {
    const daysUntilDue = getDaysUntilDue(loan.dueDate);
    if (daysUntilDue < 0) return "text-red-500";
    if (daysUntilDue <= 7) return "text-orange-500";
    return "text-green-500";
  };

  const getStatusText = (loan: any) => {
    const daysUntilDue = getDaysUntilDue(loan.dueDate);
    if (daysUntilDue < 0) return `${Math.abs(daysUntilDue)} days overdue`;
    if (daysUntilDue === 0) return "Due today";
    if (daysUntilDue === 1) return "Due tomorrow";
    if (daysUntilDue <= 7) return `Due in ${daysUntilDue} days`;
    return `Due in ${daysUntilDue} days`;
  };

  // Mock data for user's loans
  const userLoans = [
    {
      id: 1,
      principal: 1000,
      outstanding: 1000,
      interestRate: 8.5,
      repaymentPeriod: 365,
      dueDate: Date.now() + 30 * 24 * 60 * 60 * 1000, // 30 days from now
      isActive: true,
      isFunded: true,
    },
    {
      id: 2,
      principal: 2500,
      outstanding: 1800,
      interestRate: 12.0,
      repaymentPeriod: 730,
      dueDate: Date.now() - 5 * 24 * 60 * 60 * 1000, // 5 days overdue
      isActive: true,
      isFunded: true,
    },
  ];

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
                  {userLoans.length}
                </div>
                <div className="text-sm text-gray-600">Active Loans</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold text-green-500">
                  ${userLoans.reduce((sum, loan) => sum + loan.principal, 0)}
                </div>
                <div className="text-sm text-gray-600">Total Borrowed</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold text-orange-500">
                  ${userLoans.reduce((sum, loan) => sum + loan.outstanding, 0)}
                </div>
                <div className="text-sm text-gray-600">Outstanding Balance</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold text-purple-500">
                  {userLoans.filter(loan => getDaysUntilDue(loan.dueDate) < 0).length}
                </div>
                <div className="text-sm text-gray-600">Overdue Loans</div>
              </div>
            </div>
          </div>

          {/* Your Loans */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Your Active Loans</h2>
            
            {userLoans.length === 0 ? (
              <div className="text-center py-8 text-gray-600">
                You don&apos;t have any active loans.
              </div>
            ) : (
              <div className="space-y-4">
                {userLoans.map((loan) => (
                  <div key={loan.id} className="border border-gray-200 rounded-lg p-4">
                    <div className="grid grid-cols-1 md:grid-cols-6 gap-4 items-center">
                      <div>
                        <div className="font-medium">Loan #{loan.id}</div>
                        <div className="text-sm text-gray-600">Principal: ${loan.principal}</div>
                      </div>
                      <div>
                        <div className="font-medium">Outstanding</div>
                        <div className="text-lg font-bold text-orange-500">
                          ${loan.outstanding} USDC
                        </div>
                      </div>
                      <div>
                        <div className="font-medium">Interest Rate</div>
                        <div className="text-lg font-bold text-green-500">{loan.interestRate}% APR</div>
                      </div>
                      <div>
                        <div className="font-medium">Due Date</div>
                        <div className="text-sm">{formatDate(loan.dueDate)}</div>
                      </div>
                      <div>
                        <div className="font-medium">Status</div>
                        <div className={`text-sm font-medium ${getStatusColor(loan)}`}>
                          {getStatusText(loan)}
                        </div>
                      </div>
                      <div>
                        <div className="font-medium">Actions</div>
                        <div className="flex gap-2">
                          <button
                            onClick={() => setSelectedLoanId(selectedLoanId === loan.id ? null : loan.id)}
                            className="bg-gray-500 hover:bg-gray-600 text-white font-bold py-1 px-3 rounded text-sm transition-colors"
                          >
                            Details
                          </button>
                          <button
                            onClick={() => handleFullRepayment(loan.id)}
                            disabled={isLoading}
                            className="bg-green-500 hover:bg-green-600 disabled:bg-gray-400 text-white font-bold py-1 px-3 rounded text-sm transition-colors"
                          >
                            {isLoading ? "..." : "Repay"}
                          </button>
                        </div>
                      </div>
                    </div>

                    {/* Loan Details (expandable) */}
                    {selectedLoanId === loan.id && (
                      <div className="mt-4 p-4 bg-base-200 rounded-lg">
                        <h4 className="font-medium mb-3">Loan Details</h4>
                        
                        <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                          <div>
                            <h5 className="font-medium mb-2">Payment Information</h5>
                            <div className="space-y-2 text-sm">
                              <div className="flex justify-between">
                                <span>Original Principal:</span>
                                <span>${loan.principal} USDC</span>
                              </div>
                              <div className="flex justify-between">
                                <span>Interest Rate:</span>
                                <span>{loan.interestRate}% APR</span>
                              </div>
                              <div className="flex justify-between">
                                <span>Loan Term:</span>
                                <span>{loan.repaymentPeriod} days</span>
                              </div>
                              <div className="flex justify-between">
                                <span>Monthly Payment:</span>
                                <span>${(loan.principal * (1 + loan.interestRate / 100) / (loan.repaymentPeriod / 30)).toFixed(2)}</span>
                              </div>
                            </div>
                          </div>
                          
                          <div>
                            <h5 className="font-medium mb-2">Repayment Options</h5>
                            
                            {/* Full Repayment */}
                            <div className="mb-4">
                              <button
                                onClick={() => handleFullRepayment(loan.id)}
                                disabled={isLoading}
                                className="w-full bg-green-500 hover:bg-green-600 disabled:bg-gray-400 text-white font-bold py-2 px-4 rounded-lg transition-colors"
                              >
                                {isLoading ? "Processing..." : `Repay Full Amount ($${loan.outstanding})`}
                              </button>
                            </div>

                            {/* Partial Repayment */}
                            <div>
                              <div className="flex gap-2">
                                <input
                                  type="number"
                                  value={repayAmount}
                                  onChange={(e) => setRepayAmount(e.target.value)}
                                  placeholder="Enter amount"
                                  className="flex-1 p-2 border border-gray-300 rounded focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                                  min="1"
                                  max={loan.outstanding}
                                />
                                <button
                                  onClick={() => handlePartialRepayment(loan.id)}
                                  disabled={!repayAmount || isLoading}
                                  className="bg-blue-500 hover:bg-blue-600 disabled:bg-gray-400 text-white font-bold py-2 px-4 rounded transition-colors"
                                >
                                  {isLoading ? "..." : "Partial"}
                                </button>
                              </div>
                            </div>
                          </div>
                        </div>

                        {/* Overdue Warning */}
                        {getDaysUntilDue(loan.dueDate) < 0 && (
                          <div className="mt-4 p-3 bg-red-100 border border-red-300 rounded-lg">
                            <div className="flex items-center">
                              <ExclamationTriangleIcon className="h-5 w-5 text-red-500 mr-2" />
                              <div>
                                <div className="font-medium text-red-800">Loan Overdue</div>
                                <div className="text-sm text-red-600">
                                  This loan is {Math.abs(getDaysUntilDue(loan.dueDate))} days overdue. Late fees may apply.
                                </div>
                              </div>
                            </div>
                          </div>
                        )}
                      </div>
                    )}
                  </div>
                ))}
              </div>
            )}
          </div>

          {/* Repayment Tips */}
          <div className="bg-base-300 rounded-lg p-6">
            <h2 className="text-xl font-semibold mb-4">Repayment Tips</h2>
            <div className="space-y-4">
              <div className="flex items-start space-x-3">
                <div className="bg-green-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                  1
                </div>
                <div>
                  <h3 className="font-medium">Pay on Time</h3>
                  <p className="text-gray-600">Timely repayments improve your credit score and avoid late fees</p>
                </div>
              </div>
              <div className="flex items-start space-x-3">
                <div className="bg-green-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                  2
                </div>
                <div>
                  <h3 className="font-medium">Consider Partial Payments</h3>
                  <p className="text-gray-600">You can make partial payments to reduce your outstanding balance</p>
                </div>
              </div>
              <div className="flex items-start space-x-3">
                <div className="bg-green-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                  3
                </div>
                <div>
                  <h3 className="font-medium">Monitor Due Dates</h3>
                  <p className="text-gray-600">Keep track of payment deadlines to maintain good credit standing</p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </>
  );
};

export default RepayPage; 