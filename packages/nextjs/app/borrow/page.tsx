"use client";

import { useState, useEffect, useMemo } from "react";
import { createPublicClient, http } from "viem";
import { localhost } from "viem/chains";
import deployedContracts from "~~/contracts/deployedContracts";
import type { NextPage } from "next";
import { useAccount } from "wagmi";
import { CreditCardIcon, CalculatorIcon, InformationCircleIcon, DocumentDuplicateIcon, CurrencyDollarIcon } from "@heroicons/react/24/outline";
import Link from "next/link";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { formatUSDC, getCreditScoreColor } from "~~/utils/format";
import QRCodeDisplay from "~~/components/QRCodeDisplay";
import { useDisplayName } from "~~/components/scaffold-eth/DisplayNameContext";

const BorrowPage: NextPage = () => {
  const { address: connectedAddress } = useAccount();
  const [loanAmount, setLoanAmount] = useState(""); // For loan requests
  const [repayAmount, setRepayAmount] = useState(""); // For partial repayments
  const [repaymentPeriod, setRepaymentPeriod] = useState(7); // Default 1 week
  const [isLoading, setIsLoading] = useState(false);

  // Fetch on-chain credit score (0 – 1e6)
  const { data: creditScore } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getCreditScore",
    args: [connectedAddress],
  });

  // Fetch pool info for total participants
  const { data: poolInfo } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getPoolInfo",
  });

  // Fetch borrower APR (loan rate) so borrowers know expected rate
  const { data: loanRateBp } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getLoanRate",
  });
  // Convert basis-points to percentage with two decimals (e.g. 1000 ⇒ "10.00")
  const borrowerAprPercent = loanRateBp !== undefined ? (Number(loanRateBp) / 100).toFixed(2) : undefined;
  // Removed lenderCount usage

  // Fetch maxLoanAmount to compute eligible amount
  const { data: maxLoanAmount } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "maxLoanAmount",
  });

  // Helper function to round down to the nearest penny (0.01 USDC = 10000 wei)
  const roundDownToNearestPenny = (amount: bigint): bigint => {
    const pennyInWei = 10000n; // 0.01 USDC = 10000 wei
    return (amount / pennyInWei) * pennyInWei;
  };

  // Compute max eligible amount (BigInt, 6-decimals)
  // TODO: This should be made consistent with best practices for loan amount calculation
  // Current implementation reduces borrowable amount by 1% for each additional week beyond 1 week
  const maxEligibleAmount = useMemo(() => {
    if (!creditScore || !maxLoanAmount) return 0n;
    const baseAmount = (BigInt(maxLoanAmount) * creditScore) / BigInt(1e6);
    
    // Calculate weeks from repayment period (repaymentPeriod is in days)
    const weeks = Math.ceil(repaymentPeriod / 7);
    
    // For 1 week, full amount is available. For each additional week, reduce by 1%
    if (weeks <= 1) {
      return roundDownToNearestPenny(baseAmount);
    }
    
    // Calculate reduction factor: (0.99)^(weeks-1)
    const reductionFactor = Math.pow(0.99, weeks - 1);
    const reducedAmount = BigInt(Math.floor(Number(baseAmount) * reductionFactor));
    return roundDownToNearestPenny(reducedAmount);
  }, [creditScore, maxLoanAmount, repaymentPeriod]);

  // Auto-update loan amount when repayment period changes
  useEffect(() => {
    if (maxEligibleAmount > 0n) {
      const maxAmountInUSDC = Number(maxEligibleAmount) / 1e6;
      setLoanAmount(maxAmountInUSDC.toFixed(2));
    }
  }, [maxEligibleAmount]);

  const { displayName } = useDisplayName();

  // Pre-populate amount once eligible amount known and input empty (hasCredit defined below)
  // This useEffect must come after hasCredit declaration to avoid linter error

  // Helper to convert token amount (string) to micro-USDC BigInt
  const parseLoanAmount = (val: string): bigint | null => {
    if (!val || val.trim() === "") return null;
    const num = parseFloat(val);
    if (isNaN(num) || num <= 0) return null;
    // Use string manipulation to avoid floating-point precision issues
    const parts = val.split('.');
    let amountInWei: bigint;
    if (parts.length === 1) {
      // No decimal part
      amountInWei = BigInt(parseInt(parts[0]) * 1e6);
    } else {
      // Has decimal part
      const whole = parts[0];
      const decimal = parts[1].padEnd(6, '0').substring(0, 6); // Pad to 6 digits and truncate
      amountInWei = BigInt(parseInt(whole) * 1e6 + parseInt(decimal));
    }
    
    // Round down to the nearest penny to ensure borrowers can always repay
    return roundDownToNearestPenny(amountInWei);
  };

  // Write contract functions
  const { writeContractAsync } = useScaffoldWriteContract({
    contractName: "DecentralizedMicrocredit",
  });

  // Separate hook for USDC approvals
  const { writeContractAsync: writeUsdcAsync } = useScaffoldWriteContract({
    contractName: "MockUSDC",
  });

  // Contract configs
  const contracts = deployedContracts[31337];
  const USDC_ADDRESS = contracts?.MockUSDC?.address as `0x${string}` | undefined;
  const USDC_ABI = contracts?.MockUSDC?.abi;
  const MICRO_ADDRESS = contracts?.DecentralizedMicrocredit?.address as `0x${string}` | undefined;

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
      // Always compare with the required amount rounded down to the nearest penny
      const required = roundDownToNearestPenny(amount);
      console.log("Required amount (rounded to cent):", required.toString());
      console.log("Balance as number:", Number(balance));
      console.log("Amount as number:", Number(required));
      console.log("Balance >= Amount:", balance >= required);
      console.log("Balance == Amount:", balance === required);

      if (balance < required) {
        throw new Error(`Insufficient USDC balance. You have ${formatUSDC(balance)} but need ${formatUSDC(required)}`);
      }

      return balance;
    } catch (error) {
      console.error("Error checking USDC balance:", error);
      throw error;
    }
  };

  // Helper function to handle transfer errors
  const handleTransferError = (error: any) => {
    console.error("Transaction error:", error);
    
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
      
      // Check for ERC20 allowance error (0xfb8f41b2)
      if (errorMessage.includes('0xfb8f41b2') || 
          errorData.includes('0xfb8f41b2') ||
          errorMessage.includes('insufficient allowance') ||
          errorMessage.includes('ERC20InsufficientAllowance')) {
        
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

  // --- viem public client (local Anvil) -----------------------------------
  const CHAIN_ID = 31337;
  const RPC_URL = "http://localhost:8545";

  const publicClient = useMemo(
    () =>
      createPublicClient({
        chain: { ...localhost, id: CHAIN_ID },
        transport: http(RPC_URL),
      }),
    []
  );

  // Deployed Microcredit contract address / ABI
  const microcreditData = deployedContracts[CHAIN_ID]?.DecentralizedMicrocredit as any;
  const CONTRACT_ADDRESS = microcreditData?.address as `0x${string}` | undefined;

  // Preview loan terms when amount or repayment period changes
  const { data: previewTermsData } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "previewLoanTerms",
    args: [
      connectedAddress as `0x${string}` | undefined,
      connectedAddress && loanAmount ? parseLoanAmount(loanAmount) ?? undefined : undefined,
      connectedAddress && loanAmount ? BigInt(repaymentPeriod * 24 * 60 * 60) : undefined,
    ],
  });

  // ───────────── Borrower current loan ─────────────
  const { data: borrowerLoanIds, refetch: refetchBorrowerLoanIds } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getBorrowerLoanIds" as any,
    args: connectedAddress ? ([connectedAddress as `0x${string}`] as any) : undefined,
  });

  // There is at most one active loan per borrower; take first
  const latestLoanId = borrowerLoanIds && Array.isArray(borrowerLoanIds) && borrowerLoanIds.length > 0 ? (borrowerLoanIds[0] as bigint) : undefined;

  const { data: latestLoan, refetch: refetchLatestLoan } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getLoan" as any,
    args: latestLoanId !== undefined ? ([latestLoanId as bigint] as any) : undefined,
    query: {
      enabled: latestLoanId !== undefined,
    },
  });

  const activePrincipal: bigint | undefined = latestLoan && (latestLoan as any)[4] ? (latestLoan as any)[0] : undefined;
  const activeOutstanding: bigint | undefined = latestLoan && (latestLoan as any)[4] ? (latestLoan as any)[1] : undefined;

  const handleRequestLoan = async () => {
    if (!loanAmount || !connectedAddress) return;
    
    setIsLoading(true);
    try {
      const principal = parseLoanAmount(loanAmount);
      if (!principal) return;
      // 1) Request the loan (returns loanId in the tx logs)
      const hash = await writeContractAsync({
        functionName: "requestLoan",
        args: [principal],
      });

      /**
       * 2) Once the request tx is mined, look up the borrower’s latest loan
       *    and immediately call `disburseLoan` so funds are transferred in a
       *    single UX flow (demo convenience – in production a keeper / oracle
       *    might handle disbursement).
       */
      try {
        // Wait ~3 seconds for the tx to be mined
        await new Promise(r => setTimeout(r, 3000));

        if (!publicClient || !CONTRACT_ADDRESS) throw new Error("Missing client or contract");

        // Fetch borrower loan IDs and pick the most recent
        const loanIds = (await publicClient.readContract({
          address: CONTRACT_ADDRESS,
          abi: microcreditData.abi,
          functionName: "getBorrowerLoanIds",
          args: [connectedAddress as `0x${string}`],
        })) as bigint[];

        const newLoanId = loanIds.length > 0 ? loanIds[loanIds.length - 1] : undefined;

        if (newLoanId !== undefined) {
          await writeContractAsync({
            functionName: "disburseLoan",
            args: [newLoanId],
          });

          // Refresh frontend state
          await refetchBorrowerLoanIds();
          await refetchLatestLoan();
        }
      } catch (e) {
        console.error("Auto-disburse failed", e);
      }
      setLoanAmount("");
    } catch (error) {
      console.error("Error requesting loan:", error);
    } finally {
      setIsLoading(false);
    }
  };

  const getPeriodLabel = (days: number) => {
    const weeks = Math.ceil(days / 7);
    if (weeks === 1) return "1 Week";
    if (weeks === 2) return "2 Weeks";
    if (weeks === 4) return "4 Weeks";
    if (weeks === 8) return "8 Weeks";
    if (weeks === 12) return "12 Weeks";
    if (weeks === 26) return "26 Weeks";
    if (weeks === 52) return "52 Weeks";
    return `${weeks} Weeks`;
  };

  const hasCredit = creditScore && Number(creditScore) > 0;

  useEffect(() => {
    if (hasCredit && maxEligibleAmount > 0n && loanAmount === "") {
      const floorTwoDecimals = Math.floor(Number(maxEligibleAmount) / 1e4) / 100; // safe floor
      setLoanAmount(floorTwoDecimals.toFixed(2));
    }
  }, [hasCredit, maxEligibleAmount, loanAmount]);

  // Whenever loanId changes, refetch its details once
  useEffect(() => {
    if (latestLoanId !== undefined) {
      refetchLatestLoan();
    }
  }, [latestLoanId, refetchLatestLoan]);

  // Ensure user-entered amount does not exceed maximum
  const isAmountTooHigh = () => {
    const parsed = parseLoanAmount(loanAmount);
    return parsed !== null && parsed > maxEligibleAmount;
  };

  const [showInfo, setShowInfo] = useState(false);
  const attestationUrl = connectedAddress ? `${window.location.origin}/attest?borrower=${connectedAddress}` : "";

  return (
    <>
      <div className="flex items-center flex-col grow pt-10">
        <div className="px-5 w-full max-w-4xl">
          <div className="flex items-center justify-center mb-8">
            <CreditCardIcon className="h-8 w-8 mr-3" />
            <h1 className="text-3xl font-bold">Request Loan</h1>
          </div>

          {/* Attestation Call-to-Action */}
          {!hasCredit && (
            <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
              <div className="flex items-center justify-center mb-4 gap-2">
                <h2 className="text-lg font-semibold text-center">Attestation Link</h2>
                <button
                  onClick={() => setShowInfo(true)}
                  className="text-info hover:text-info/80"
                  aria-label="What does this mean?"
                >
                  <InformationCircleIcon className="h-5 w-5" />
                </button>
              </div>
              
              <div className="flex items-start gap-6">
                {/* QR Code on the left */}
                <div className="flex-shrink-0">
                  <div
                    onClick={() => {
                      navigator.clipboard.writeText(attestationUrl);
                      alert("Attestation link copied! Share it with your community.");
                    }}
                    className="cursor-pointer flex flex-col items-center"
                  >
                    <QRCodeDisplay value={attestationUrl} size={80} />
                    <span className="text-xs text-gray-500 mt-2">Click to copy</span>
                  </div>
                </div>
                
                {/* Instructions and link on the right */}
                <div className="flex-1">
                  <div className="mb-3">
                    <p className="text-gray-700 mb-2">
                      <strong>Share this link with people who know you well</strong>
                    </p>
                    <p className="text-sm text-gray-600 mb-2">
                      You need at least one attestation to request a loan. Share your attestation link with trusted peers and build your credit score.
                    </p>
                    <p className="text-sm text-gray-600">
                      Ask friends, family, or community members to vouch for your trustworthiness. 
                      Each person who attests to you helps build your credit score.
                    </p>
                  </div>
                  
                  <div className="text-xs flex items-center gap-1 text-blue-600">
                    <span
                      className="underline truncate max-w-[300px] cursor-pointer"
                      title={attestationUrl}
                      onClick={() => { navigator.clipboard.writeText(attestationUrl); alert("Attestation link copied! Share it with your community."); }}
                    >
                      {attestationUrl}
                    </span>
                    <DocumentDuplicateIcon
                      className="h-4 w-4 cursor-pointer flex-shrink-0"
                      onClick={() => { navigator.clipboard.writeText(attestationUrl); alert("Attestation link copied! Share it with your community."); }}
                    />
                  </div>
                </div>
              </div>
            </div>
          )}

          {/* Welcome Section for Borrowers */}
          <div className="bg-gradient-to-br from-green-50 to-green-100 border border-green-200 rounded-xl p-6 mb-8">
            <div className="text-center mb-6">
              <h2 className="text-2xl font-bold text-green-800 mb-3">Welcome to Social Borrowing</h2>
              <p className="text-green-700 max-w-3xl mx-auto">
                Access fair microloans based on your community&apos;s trust, not traditional credit scores. 
                Your friends, family, and community members vouch for your reliability, creating a credit score that reflects your real-world reputation.
              </p>
            </div>
            
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4 text-center">
              <div className="bg-white rounded-lg p-4">
                <div className="text-2xl font-bold text-green-600 mb-2">No Bank Required</div>
                <div className="text-sm text-gray-600">No traditional credit history or bank account needed</div>
              </div>
              <div className="bg-white rounded-lg p-4">
                <div className="text-2xl font-bold text-green-600 mb-2">Community Trust</div>
                <div className="text-sm text-gray-600">Your credit score is built through social attestations</div>
              </div>
              <div className="bg-white rounded-lg p-4">
                <div className="text-2xl font-bold text-green-600 mb-2">Fair Terms</div>
                <div className="text-sm text-gray-600">Transparent loan terms based on your social reputation</div>
              </div>
            </div>
          </div>

          {/* Your Account Profile - Full Width */}
          {connectedAddress && hasCredit && (
            <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
              <h2 className="text-xl font-semibold mb-4">Your Account Profile{displayName && ` – ${displayName}`}</h2>

              <div className="flex items-center justify-between flex-wrap gap-4">
                {/* Credit Score */}
                <div className="flex items-center gap-3">
                  <div className="text-center">
                    <div className="text-3xl font-bold text-green-500">
                      {(Number(creditScore) / 10000).toFixed(2)}%
                    </div>
                    <div className="text-sm text-gray-600">Credit Score</div>
                  </div>
                </div>

                {/* Eligible Amount */}
                <div className="flex items-center gap-3">
                  <div className="text-center">
                    <div className="text-2xl font-bold text-blue-500">
                      {maxEligibleAmount > 0n ? formatUSDC(maxEligibleAmount) : "-"}
                    </div>
                    <div className="text-sm text-gray-600">
                      {(() => {
                        const weeks = Math.ceil(repaymentPeriod / 7);
                        if (weeks <= 1) return "Eligible to Borrow";
                        const reduction = ((1 - Math.pow(0.99, weeks - 1)) * 100).toFixed(1);
                        return `Eligible (${reduction}% reduced)`;
                      })()}
                    </div>
                  </div>
                </div>

                {/* Loan Principal */}
                <div className="flex items-center gap-3">
                  <div className="text-center">
                    <div className="text-2xl font-bold text-purple-500">
                      {activePrincipal !== undefined ? formatUSDC(activePrincipal) : "-"}
                    </div>
                    <div className="text-sm text-gray-600">Loan Principal</div>
                  </div>
                </div>

                {/* Outstanding / Payoff */}
                <div className="flex items-center gap-3">
                  <div className="text-center">
                    <div className="text-2xl font-bold text-orange-500">
                      {activeOutstanding !== undefined ? formatUSDC(roundDownToNearestPenny(activeOutstanding)) : "-"}
                    </div>
                    <div className="text-sm text-gray-600">Payoff Amount</div>
                  </div>
                </div>

                {/* Borrower APR */}
                <div className="flex items-center gap-3">
                  <div className="text-center">
                    <div className="text-2xl font-bold text-purple-500">
                      {borrowerAprPercent !== undefined ? `${borrowerAprPercent}%` : "-"}
                    </div>
                    <div className="text-sm text-gray-600">Borrower APR</div>
                  </div>
                </div>
              </div>
            </div>
          )}

          {showInfo && (
            <div className="fixed inset-0 flex items-center justify-center bg-black/50 z-50">
              <div className="bg-base-100 rounded-lg p-6 max-w-md w-11/12 shadow-lg">
                <h3 className="text-lg font-semibold mb-3">How LoanLink attestations work</h3>
                <p className="text-sm mb-3">
                  LoanLink builds your credit score from trust attestations your friends and community members give you. Share the link or QR code on this page with people who know you. Each attestation lifts your score.
                </p>
                <p className="text-sm mb-3">
                  Once your score is above zero, the loan request form unlocks and you can apply for your first loan.
                </p>
                <p className="text-sm mb-5">
                  Need a deeper dive?&nbsp;
                  <Link href="/help/borrow" className="link">Read the Borrower guide</Link>.
                </p>
                <button onClick={() => setShowInfo(false)} className="btn btn-primary w-full">Got it</button>
              </div>
            </div>
          )}

          {/* Loan Request Section */}
          {hasCredit && (
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Request New Loan</h2>
            <div className="space-y-6">
              {/* Loan Amount */}
              <div>
                <label className="block text-sm font-medium mb-2">Loan Amount (USDC)</label>
                <input
                  type="number"
                  value={loanAmount}
                  onChange={(e) => setLoanAmount(e.target.value)}
                  placeholder="Enter amount in USDC"
                  className="w-full p-3 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                  min="1"
                  max="1000000"
                />
              </div>

              {/* Repayment Period */}
              <div>
                <label className="block text-sm font-medium mb-2">Repayment Period (Weekly Increments)</label>
                <select
                  value={repaymentPeriod}
                  onChange={(e) => setRepaymentPeriod(Number(e.target.value))}
                  className="w-full p-3 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                >
                  <option value={7}>1 Week</option>
                  <option value={14}>2 Weeks</option>
                  <option value={28}>4 Weeks</option>
                  <option value={56}>8 Weeks</option>
                  <option value={84}>12 Weeks</option>
                  <option value={182}>26 Weeks</option>
                  <option value={364}>52 Weeks</option>
                </select>
                <p className="text-xs text-gray-500 mt-1">
                  Note: Borrowable amount decreases by 1% for each additional week beyond 1 week
                </p>
              </div>

              {/* Request Button */}
              <button
                onClick={handleRequestLoan}
                disabled={!loanAmount || !connectedAddress || isLoading || !hasCredit || isAmountTooHigh()}
                className="w-full bg-green-500 hover:bg-green-600 disabled:bg-gray-400 text-white font-bold py-3 px-4 rounded-lg transition-colors mb-4"
              >
                {isLoading ? "Requesting Loan..." : "Request Loan"}
              </button>

              {isAmountTooHigh() && (
                <p className="text-red-600 text-sm">Amount exceeds your maximum eligible loan. Lower the amount.</p>
              )}

              {/* Loan Terms Preview & Repayment Schedule */}
              {loanAmount && previewTermsData && (
                <div className="bg-base-200 rounded-lg p-4">
                  <h3 className="font-medium mb-3 flex items-center">
                    <CalculatorIcon className="h-5 w-5 mr-2" />
                    Loan Terms Preview
                  </h3>
                  <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <div>
                      <span className="text-sm text-gray-600">Interest Rate:</span>
                      <div className="text-lg font-bold text-blue-500">
                        {(Number(previewTermsData[0]) / 10000).toFixed(2)}% APR
                      </div>
                    </div>
                    <div>
                      <span className="text-sm text-gray-600">Weekly Payment:</span>
                      <div className="text-lg font-bold text-green-500">
                        ${(Number(previewTermsData[1]) / 1e6).toFixed(2)} USDC
                      </div>
                    </div>
                    <div>
                      <span className="text-sm text-gray-600">Total Interest:</span>
                      <div className="text-lg font-bold text-orange-500">
                        {(() => {
                          const interest = Number(loanAmount) * Number(previewTermsData[0]) / 10000;
                          return interest.toFixed(2);
                        })()} USDC
                      </div>
                    </div>
                    <div>
                      <span className="text-sm text-gray-600">Total Repayment:</span>
                      <div className="text-lg font-bold text-purple-500">
                        {(() => {
                          const total = Number(loanAmount) * (1 + Number(previewTermsData[0]) / 10000);
                          return total.toFixed(2);
                        })()} USDC
                      </div>
                    </div>
                  </div>

                  {/* Repayment Schedule */}
                  {repaymentPeriod && (
                    <div className="mt-6 overflow-x-auto text-xs">
                      <h4 className="font-medium mb-2">Weekly Repayment Schedule</h4>
                      <table className="table w-full">
                        <thead>
                          <tr>
                            <th>Week #</th>
                            <th>Due Date</th>
                            <th>Weekly Payment (USDC)</th>
                            <th>Remaining Balance (USDC)</th>
                          </tr>
                        </thead>
                        <tbody>
                          {Array.from({ length: Math.ceil(repaymentPeriod / 7) }).map((_, idx) => {
                            const weekNumber = idx + 1;
                            const weeklyPayment = Number(previewTermsData[1]) / 1e6;
                            const totalWeeks = Math.ceil(repaymentPeriod / 7);
                            const totalAmount = Number(loanAmount) * (1 + Number(previewTermsData[0]) / 10000);
                            const remainingBalance = totalAmount - (weeklyPayment * weekNumber);
                            
                            // For the final payment, ensure we pay exactly the remaining balance
                            const isFinalPayment = weekNumber === totalWeeks;
                            const paymentAmount = isFinalPayment ? Math.max(0, remainingBalance + weeklyPayment) : weeklyPayment;
                            const finalRemainingBalance = isFinalPayment ? 0 : Math.max(0, remainingBalance);
                            
                            return (
                              <tr key={idx}>
                                <td>{weekNumber}</td>
                                <td>Week {weekNumber}</td>
                                <td>{paymentAmount.toFixed(2)}</td>
                                <td>{finalRemainingBalance.toFixed(2)}</td>
                              </tr>
                            );
                          })}
                        </tbody>
                      </table>
                    </div>
                  )}
                </div>
              )}
            </div>
          </div>
          )}

          {/* Active Loan & Repayment Section */}
          {latestLoan && (latestLoan as any)[4] && (
            <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
              <h2 className="text-xl font-semibold mb-4 flex items-center">
                <CurrencyDollarIcon className="h-5 w-5 mr-2" />
                Active Loan & Repayment
              </h2>
              
              <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                {/* Loan Summary */}
                <div className="bg-base-200 rounded-lg p-4">
                  <h3 className="font-medium mb-3">Loan Summary</h3>
                  <div className="space-y-2 text-sm">
                    <div className="flex justify-between">
                      <span className="text-gray-600">Principal:</span>
                      <span className="font-medium">{activePrincipal !== undefined ? formatUSDC(activePrincipal) : "-"}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-gray-600">Outstanding:</span>
                      <span className="font-medium text-orange-500">{activeOutstanding !== undefined ? formatUSDC(roundDownToNearestPenny(activeOutstanding)) : "-"}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-gray-600">Interest Rate:</span>
                      <span className="font-medium text-blue-500">
                        {latestLoan && (latestLoan as any)[3] ? `${(Number((latestLoan as any)[3]) / 100).toFixed(2)}% APR` : "-"}
                      </span>
                    </div>
                  </div>
                </div>

                {/* Next Payment Due */}
                <div className="bg-base-200 rounded-lg p-4">
                  <h3 className="font-medium mb-3">Next Payment Due</h3>
                  <div className="space-y-2 text-sm">
                    <div className="flex justify-between">
                      <span className="text-gray-600">Weekly Payment:</span>
                      <span className="font-medium text-green-500">
                        {previewTermsData && loanAmount ? `${(Number(previewTermsData[1]) / 1e6).toFixed(2)} USDC` : "-"}
                      </span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-gray-600">Due Date:</span>
                      <span className="font-medium">Next Week</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-gray-600">Status:</span>
                      <span className="font-medium text-green-500">Current</span>
                    </div>
                  </div>
                </div>
              </div>

              {/* Repayment Actions */}
              <div className="mt-6 pt-4 border-t border-gray-300">
                <h3 className="font-medium mb-3">Make a Payment</h3>
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                  {/* Full Repayment */}
                  <div className="bg-green-50 border border-green-200 rounded-lg p-4">
                    <h4 className="font-medium text-green-800 mb-2">Full Repayment</h4>
                    <p className="text-sm text-green-600 mb-3">Pay off your entire outstanding balance</p>
                    <button
                      onClick={async () => {
                        if (!latestLoanId || !activeOutstanding) return;
                        setIsLoading(true);
                        try {
                          console.log("Starting full repayment process...");
                           
                          // Check USDC balance first
                          console.log("Checking USDC balance...");
                          const amountToRepay = roundDownToNearestPenny(activeOutstanding as bigint);
                          await checkUSDCBalance(amountToRepay);
                           
                          // Ensure USDC allowance
                          console.log("Ensuring USDC allowance...");
                          await ensureAllowance(amountToRepay);
                           
                          // Execute repayment
                          console.log("Executing repayment...");
                          await writeContractAsync({
                            functionName: "repayLoan",
                            args: [latestLoanId as bigint, amountToRepay],
                          });
                           
                          console.log("Repayment completed successfully!");
                          await refetchLatestLoan();
                        } catch (error) {
                          const errorType = handleTransferError(error);
                           
                          switch (errorType) {
                            case "TRANSFER_FAILED":
                              console.error("USDC transfer failed. Please check your USDC balance and try again.");
                              break;
                            case "ERC20_APPROVAL_NEEDED":
                              console.error("ERC20 Allowance Error: Please try again. The system will handle the approval automatically.");
                              break;
                            case "INSUFFICIENT_FUNDS":
                              console.error("Insufficient funds for gas or USDC balance.");
                              break;
                            case "USER_REJECTED":
                              console.error("Transaction was rejected by user.");
                              break;
                            default:
                              console.error("Unknown error occurred:", error);
                          }
                        } finally {
                          setIsLoading(false);
                        }
                      }}
                      disabled={isLoading || !activeOutstanding}
                      className="w-full bg-green-500 hover:bg-green-600 disabled:bg-gray-400 text-white font-bold py-2 px-4 rounded-lg transition-colors"
                    >
                      {isLoading ? "Processing..." : `Pay ${activeOutstanding !== undefined ? formatUSDC(roundDownToNearestPenny(activeOutstanding)) : "-"}`}
                    </button>
                  </div>

                  {/* Partial Repayment */}
                  <div className="bg-blue-50 border border-blue-200 rounded-lg p-4">
                    <h4 className="font-medium text-blue-800 mb-2">Partial Repayment</h4>
                    <p className="text-sm text-blue-600 mb-3">Make a partial payment to reduce your balance</p>
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
                        onClick={async () => {
                          if (!latestLoanId || !repayAmount) return;
                          const repayAmountBigInt = parseLoanAmount(repayAmount);
                          if (!repayAmountBigInt) return;
                          setIsLoading(true);
                          try {
                            console.log("Starting partial repayment process...");
                            
                            // Check USDC balance first
                            console.log("Checking USDC balance for partial repayment...");
                            await checkUSDCBalance(repayAmountBigInt);
                            
                            // Ensure USDC allowance for partial amount
                            console.log("Ensuring USDC allowance for partial repayment...");
                            await ensureAllowance(repayAmountBigInt);
                            
                            // Execute partial repayment
                            console.log("Executing partial repayment...");
                            await writeContractAsync({
                              functionName: "repayLoan",
                              args: [latestLoanId as bigint, repayAmountBigInt],
                            });
                            
                            console.log("Partial repayment completed successfully!");
                            setRepayAmount("");
                            await refetchLatestLoan();
                          } catch (error) {
                            const errorType = handleTransferError(error);
                            
                            switch (errorType) {
                              case "TRANSFER_FAILED":
                                console.error("USDC transfer failed. Please check your USDC balance and try again.");
                                break;
                              case "ERC20_APPROVAL_NEEDED":
                                console.error("ERC20 Allowance Error: Please try again. The system will handle the approval automatically.");
                                break;
                              case "INSUFFICIENT_FUNDS":
                                console.error("Insufficient funds for gas or USDC balance.");
                                break;
                              case "USER_REJECTED":
                                console.error("Transaction was rejected by user.");
                                break;
                              default:
                                console.error("Unknown error occurred:", error);
                            }
                          } finally {
                            setIsLoading(false);
                          }
                        }}
                        disabled={isLoading || !repayAmount || !parseLoanAmount(repayAmount)}
                        className="bg-blue-500 hover:bg-blue-600 disabled:bg-gray-400 text-white font-bold py-2 px-4 rounded-lg transition-colors"
                      >
                        {isLoading ? "Processing..." : "Repay"}
                      </button>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          )}


        </div>
      </div>
    </>
  );
};

export default BorrowPage; 