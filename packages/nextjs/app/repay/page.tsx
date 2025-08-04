"use client";

import { NextPage } from "next";
import { useState } from "react";
import { useAccount } from "wagmi";
import { useScaffoldWriteContract, useScaffoldReadContract } from "~~/hooks/scaffold-eth";
import { formatUSDC } from "~~/utils/format";
import { CurrencyDollarIcon, EyeIcon } from "@heroicons/react/24/outline";
import { createPublicClient, http } from "viem";
import { localhost } from "viem/chains";
import deployedContracts from "~~/contracts/deployedContracts";
import Link from "next/link";

const CHAIN_ID = 31337;
const RPC_URL = "http://localhost:8545";

// Public client for read operations
const publicClient = createPublicClient({
  chain: { ...localhost, id: CHAIN_ID },
  transport: http(RPC_URL),
});

// Contract configs
const contracts = deployedContracts[31337];
const USDC_ADDRESS = contracts?.MockUSDC?.address as `0x${string}` | undefined;
const USDC_ABI = contracts?.MockUSDC?.abi;
const MICRO_ADDRESS = contracts?.DecentralizedMicrocredit?.address as `0x${string}` | undefined;
const MICRO_ABI = contracts?.DecentralizedMicrocredit?.abi;

const RepayPage: NextPage = () => {
  const { address: connectedAddress } = useAccount();
  const [selectedLoanId, setSelectedLoanId] = useState<number | null>(null);
  const [repayAmount, setRepayAmount] = useState("");
  const [isLoading, setIsLoading] = useState(false);

  // For now, we'll use a placeholder array since there's no function to get user loans
  const userLoans: bigint[] = [];

  const { writeContractAsync } = useScaffoldWriteContract({
    contractName: "DecentralizedMicrocredit",
  });

  // Separate hook for USDC approvals
  const { writeContractAsync: writeUsdcAsync } = useScaffoldWriteContract({
    contractName: "MockUSDC",
  });

  // Helper function to check and handle USDC allowance
  const ensureAllowance = async (amount: bigint) => {
    if (!connectedAddress || !USDC_ADDRESS || !MICRO_ADDRESS) {
      throw new Error("Missing required addresses");
    }

    try {
      // Check current allowance
      const currentAllowance = await publicClient.readContract({
        address: USDC_ADDRESS,
        abi: USDC_ABI,
        functionName: "allowance",
        args: [connectedAddress, MICRO_ADDRESS],
      });

      console.log("Current allowance:", currentAllowance.toString());
      console.log("Required amount:", amount.toString());

      // If allowance is insufficient, approve
      if (currentAllowance < amount) {
        console.log("Insufficient allowance, approving...");
        await writeUsdcAsync({
          functionName: "approve",
          args: [MICRO_ADDRESS, amount],
        });
        
        // Wait for approval to be processed
        await new Promise(resolve => setTimeout(resolve, 3000));
        
        // Verify the approval
        const newAllowance = await publicClient.readContract({
          address: USDC_ADDRESS,
          abi: USDC_ABI,
          functionName: "allowance",
          args: [connectedAddress, MICRO_ADDRESS],
        });
        
        console.log("New allowance:", newAllowance.toString());
        
        if (newAllowance < amount) {
          throw new Error("Allowance approval failed");
        }
      } else {
        console.log("Sufficient allowance already exists");
      }
    } catch (error) {
      console.error("Error in ensureAllowance:", error);
      throw error;
    }
  };

  // Helper function to handle ERC20 allowance errors
  const handleERC20Error = (error: any) => {
    console.error("Transaction error:", error);
    
    // Check for ERC20 allowance error (0xfb8f41b2)
    if (error && typeof error === 'object') {
      const errorMessage = error.message || '';
      const errorData = error.data || error.error?.data || '';
      
      // Check for transfer failed error (0xe450d38c)
      if (errorMessage.includes('0xe450d38c') || 
          errorData.includes('0xe450d38c') ||
          errorMessage.includes('Transfer failed') ||
          errorMessage.includes('transfer failed')) {
        
        console.error("USDC Transfer Failed!");
        console.error("This could be due to:");
        console.error("1. Insufficient USDC balance");
        console.error("2. Insufficient allowance (though we tried to approve)");
        console.error("3. MockUSDC contract issues");
        
        return "TRANSFER_FAILED";
      }
      
      // Check various ways the error might be encoded
      if (errorMessage.includes('0xfb8f41b2') || 
          errorData.includes('0xfb8f41b2') ||
          errorMessage.includes('insufficient allowance') ||
          errorMessage.includes('ERC20InsufficientAllowance') ||
          errorMessage.includes('transfer amount exceeds allowance')) {
        
        console.error("ERC20 Allowance Error Detected!");
        console.error("This means the USDC contract doesn&apos;t have permission to transfer your tokens.");
        console.error("Please try the repayment again - it should automatically approve the allowance.");
        
        return "ERC20_APPROVAL_NEEDED";
      }
      
      // Check for other common errors
      if (errorMessage.includes('insufficient funds') || errorMessage.includes('gas')) {
        return "INSUFFICIENT_FUNDS";
      }
      
      if (errorMessage.includes('user rejected') || errorMessage.includes('User denied')) {
        return "USER_REJECTED";
      }
    }
    
    return "UNKNOWN_ERROR";
  };

  // Helper function to check USDC balance
  const checkUSDCBalance = async (amount: bigint) => {
    if (!connectedAddress || !USDC_ADDRESS) {
      throw new Error("Missing required addresses");
    }

    try {
      const balance = await publicClient.readContract({
        address: USDC_ADDRESS,
        abi: USDC_ABI,
        functionName: "balanceOf",
        args: [connectedAddress],
      });

      console.log("USDC Balance:", balance.toString());
      console.log("Required amount:", amount.toString());

      if (balance < amount) {
        throw new Error(`Insufficient USDC balance. You have ${formatUSDC(balance)} but need ${formatUSDC(amount)}`);
      }

      return balance;
    } catch (error) {
      console.error("Error checking USDC balance:", error);
      throw error;
    }
  };

  const handleFullRepayment = async (loanId: number) => {
    setIsLoading(true);
    try {
      // Fetch outstanding amount from contract
      if (!MICRO_ADDRESS || !MICRO_ABI || !USDC_ADDRESS) throw new Error("Contracts not ready");
      const loan = await publicClient.readContract({
        address: MICRO_ADDRESS,
        abi: MICRO_ABI,
        functionName: "getLoan",
        args: [BigInt(loanId)],
      });
      const outstandingAmount = loan[1] as bigint;
      
      console.log("Outstanding amount:", outstandingAmount.toString());
      
      // Ensure USDC allowance
      console.log("Ensuring USDC allowance...");
      await ensureAllowance(outstandingAmount);

      // Check USDC balance
      console.log("Checking USDC balance...");
      await checkUSDCBalance(outstandingAmount);
      
      // Repay
      console.log("Executing repayment...");
      await writeContractAsync({
        functionName: "repayLoan",
        args: [BigInt(loanId), outstandingAmount],
      });
      
      console.log("Repayment completed successfully!");
    } catch (error) {
      const errorType = handleERC20Error(error);
      
      switch (errorType) {
        case "ERC20_APPROVAL_NEEDED":
          console.error("Please try the repayment again. The system will automatically handle the USDC approval.");
          break;
        case "INSUFFICIENT_FUNDS":
          console.error("Insufficient funds for gas or USDC balance.");
          break;
        case "USER_REJECTED":
          console.error("Transaction was rejected by user.");
          break;
        case "TRANSFER_FAILED":
          console.error("USDC transfer failed. Please ensure you have sufficient USDC balance and allowance.");
          break;
        default:
          console.error("Unknown error occurred:", error);
      }
    } finally {
      setIsLoading(false);
    }
  };

  const handlePartialRepayment = async (loanId: number) => {
    if (!repayAmount) return;
    
    setIsLoading(true);
    try {
      const amountInWei = BigInt(parseFloat(repayAmount) * 1e6); // Convert to USDC with 6 decimals
      
      console.log("Partial repayment amount:", amountInWei.toString());
      
      // Ensure USDC allowance for partial amount
      console.log("Ensuring USDC allowance for partial repayment...");
      await ensureAllowance(amountInWei);

      // Check USDC balance
      console.log("Checking USDC balance...");
      await checkUSDCBalance(amountInWei);
      
      // Execute partial repayment
      console.log("Executing partial repayment...");
      await writeContractAsync({
        functionName: "repayLoan",
        args: [BigInt(loanId), amountInWei],
      });
      
      console.log("Partial repayment completed successfully!");
      setRepayAmount("");
    } catch (error) {
      const errorType = handleERC20Error(error);
      
      switch (errorType) {
        case "ERC20_APPROVAL_NEEDED":
          console.error("Please try the partial repayment again. The system will automatically handle the USDC approval.");
          break;
        case "INSUFFICIENT_FUNDS":
          console.error("Insufficient funds for gas or USDC balance.");
          break;
        case "USER_REJECTED":
          console.error("Transaction was rejected by user.");
          break;
        case "TRANSFER_FAILED":
          console.error("USDC transfer failed. Please ensure you have sufficient USDC balance and allowance.");
          break;
        default:
          console.error("Unknown error occurred:", error);
      }
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
  const formatUSDCAmount = formatUSDC;

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
                  {formatUSDCAmount(summary.totalBorrowed)}
                </div>
                <div className="text-sm text-gray-600">Total Borrowed</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold text-orange-500">
                  {formatUSDCAmount(summary.outstandingBalance)}
                </div>
                <div className="text-sm text-gray-600">Payoff Amount</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold text-red-500">
                  {summary.overdueCount}
                </div>
                <div className="text-sm text-gray-600">Overdue</div>
              </div>
            </div>
          </div>

          {/* No Loans Message */}
          {userLoans.length === 0 && (
            <div className="text-center py-12">
              <CurrencyDollarIcon className="h-16 w-16 text-gray-400 mx-auto mb-4" />
              <h3 className="text-xl font-semibold text-gray-600 mb-2">No Active Loans</h3>
              <p className="text-gray-500 mb-6">
                You don&apos;t have any active loans to repay at the moment.
              </p>
              <Link
                href="/borrow"
                className="inline-flex items-center px-4 py-2 bg-blue-500 text-white rounded-lg hover:bg-blue-600 transition-colors"
              >
                <CurrencyDollarIcon className="h-5 w-5 mr-2" />
                Apply for a Loan
              </Link>
            </div>
          )}

          {/* Loan Cards */}
          {userLoans.length > 0 && (
            <div className="space-y-6">
              <h2 className="text-xl font-semibold">Your Loans</h2>
              {userLoans.map((loanId, index) => (
                <UserLoanCard
                  key={index}
                  loanId={loanId}
                  onFullRepayment={handleFullRepayment}
                  onPartialRepayment={handlePartialRepayment}
                  onViewDetails={() => setSelectedLoanId(Number(loanId))}
                  isSelected={selectedLoanId === Number(loanId)}
                  isLoading={isLoading}
                  repayAmount={repayAmount}
                  setRepayAmount={setRepayAmount}
                />
              ))}
            </div>
          )}
        </div>
      </div>
    </>
  );
};

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
  // Placeholder data - in a real implementation, you'd fetch this from the contract
  const loanAmount = 1000000n; // 1 USDC
  const outstandingAmount = 1000000n; // 1 USDC
  const interestRate = 1000n; // 10% in basis points
  const isActive = true;

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

  return (
    <div className="bg-base-100 rounded-lg p-6 shadow-lg border border-gray-200">
      <div className="flex justify-between items-start mb-4">
        <div>
          <h3 className="text-lg font-semibold">Loan #{loanId.toString()}</h3>
          <p className="text-sm text-gray-600">Created recently</p>
        </div>
        <div className="text-right">
          <div className={`text-sm font-medium ${getStatusColor(isActive)}`}>
            {getStatusText(isActive)}
          </div>
          <div className="text-xs text-gray-500">
            Rate: {formatInterestRate(interestRate)}
          </div>
        </div>
      </div>

      <div className="grid grid-cols-2 gap-4 mb-4">
        <div>
          <div className="text-sm text-gray-600">Original Amount</div>
          <div className="font-semibold">{formatUSDC(loanAmount)}</div>
        </div>
        <div>
          <div className="text-sm text-gray-600">Outstanding Balance</div>
          <div className="font-semibold text-orange-600">{formatUSDC(outstandingAmount)}</div>
        </div>
      </div>

      <div className="flex gap-2">
        <button
          onClick={() => onFullRepayment(Number(loanId))}
          disabled={isLoading || !isActive}
          className="flex-1 bg-green-500 hover:bg-green-600 disabled:bg-gray-400 text-white font-bold py-2 px-4 rounded-lg transition-colors"
        >
          {isLoading ? "Processing..." : "Full Repayment"}
        </button>
        
        <div className="flex-1 flex gap-2">
          <input
            type="number"
            value={repayAmount}
            onChange={(e) => setRepayAmount(e.target.value)}
            placeholder="Amount"
            className="flex-1 p-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent"
            min="0.01"
            step="0.01"
          />
          <button
            onClick={() => onPartialRepayment(Number(loanId))}
            disabled={isLoading || !repayAmount || !isActive}
            className="bg-blue-500 hover:bg-blue-600 disabled:bg-gray-400 text-white font-bold py-2 px-4 rounded-lg transition-colors"
          >
            {isLoading ? "..." : "Repay"}
          </button>
        </div>
        
        <button
          onClick={onViewDetails}
          className="bg-gray-500 hover:bg-gray-600 text-white font-bold py-2 px-4 rounded-lg transition-colors"
        >
          <EyeIcon className="h-4 w-4" />
        </button>
      </div>
    </div>
  );
};

export default RepayPage; 