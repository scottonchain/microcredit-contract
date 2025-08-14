"use client";

import { useState, useEffect, useMemo } from "react";
import { createPublicClient, http } from "viem";
import { localhost } from "viem/chains";
import deployedContracts from "~~/contracts/deployedContracts";
import type { NextPage } from "next";
import { useAccount, useSignTypedData } from "wagmi";
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

  // Helper function to round up to the nearest penny (0.01 USDC = 10000 wei)
  const roundUpToNearestPenny = (amount: bigint): bigint => {
    const pennyInWei = 10000n;
    if (amount % pennyInWei === 0n) return amount;
    return ((amount / pennyInWei) + 1n) * pennyInWei;
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
  // Note: All writes are routed via meta-tx relayer except this USDC approval fallback
  // used only when permit is unavailable in dev/local environments.
  const { writeContractAsync: writeUsdcAsync } = useScaffoldWriteContract({
    contractName: "MockUSDC",
  });

  // Contract configs
  const contracts = deployedContracts[31337];
  const USDC_ADDRESS = contracts?.MockUSDC?.address as `0x${string}` | undefined;
  const USDC_ABI = contracts?.MockUSDC?.abi;
  const MICRO_ADDRESS = contracts?.DecentralizedMicrocredit?.address as `0x${string}` | undefined;
  const MICRO_ABI = contracts?.DecentralizedMicrocredit?.abi;

  // Cache USDC token name for EIP-2612 domain (avoid hardcoding to prevent invalid signatures)
  const [usdcTokenName, setUsdcTokenName] = useState<string | undefined>(undefined);
  useEffect(() => {
    let cancelled = false;
    const loadName = async () => {
      try {
        if (!USDC_ADDRESS || !USDC_ABI) return;
        const name = (await publicClient.readContract({
          address: USDC_ADDRESS,
          abi: USDC_ABI,
          functionName: "name",
          args: [],
        })) as string;
        if (!cancelled) setUsdcTokenName(name);
      } catch (e) {
        // Fallback handled below with default name
        console.warn("Unable to read USDC token name; falling back to 'USD Coin'", e);
      }
    };
    loadName();
    return () => {
      cancelled = true;
    };
  }, [USDC_ADDRESS, USDC_ABI]);

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
  const CONTRACT_ABI = microcreditData?.abi;

  // EIP-712 signing
  const { signTypedDataAsync } = useSignTypedData();

  // Helpers for meta-transaction domain and types (Microcredit)
  const domain = useMemo(
    () => ({
      name: "DecentralizedMicrocredit",
      version: "1",
      chainId: CHAIN_ID,
      verifyingContract: CONTRACT_ADDRESS as `0x${string}` | undefined,
    }),
    [CHAIN_ID, CONTRACT_ADDRESS]
  );

  const loanRequestTypes = {
    LoanRequest: [
      { name: "borrower", type: "address" },
      { name: "amount", type: "uint256" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" },
    ],
  } as const;

  const disburseRequestTypes = {
    DisburseRequest: [
      { name: "borrower", type: "address" },
      { name: "loanId", type: "uint256" },
      { name: "to", type: "address" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" },
    ],
  } as const;

  const repayRequestTypes = {
    RepayRequest: [
      { name: "borrower", type: "address" },
      { name: "loanId", type: "uint256" },
      { name: "amount", type: "uint256" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" },
    ],
  } as const;

  // ERC-2612 Permit typed data domain for USDC
  // Use on-chain token name when available; default to "USD Coin" (MockUSDC constructor) to maintain compatibility
  const usdcPermitDomain = useMemo(
    () => ({
      name: usdcTokenName || "USD Coin",
      version: "1",
      chainId: CHAIN_ID,
      verifyingContract: USDC_ADDRESS as `0x${string}` | undefined,
    }),
    [CHAIN_ID, USDC_ADDRESS, usdcTokenName]
  );

  const permitTypes = {
    Permit: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
      { name: "value", type: "uint256" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" },
    ],
  } as const;

  // Helper: split 65-byte sig into {v,r,s}
  const splitSignature = (sig: `0x${string}`) => {
    const hex = sig.slice(2);
    const r = ("0x" + hex.slice(0, 64)) as `0x${string}`;
    const s = ("0x" + hex.slice(64, 128)) as `0x${string}`;
    const v = Number("0x" + hex.slice(128, 130));
    return { v, r, s } as const;
  };

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
    watch: true,
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
    watch: true,
  });

  const activePrincipal: bigint | undefined = latestLoan && (latestLoan as any)[4] ? (latestLoan as any)[0] : undefined;
  const activeOutstanding: bigint | undefined = latestLoan && (latestLoan as any)[4] ? (latestLoan as any)[1] : undefined;

  // Fetch live outstanding amount including accrued interest
  const { data: liveOutstanding, refetch: refetchLiveOutstanding } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getCurrentOutstandingAmount" as any,
    args: latestLoanId !== undefined ? ([latestLoanId as bigint] as any) : undefined,
    query: {
      enabled: latestLoanId !== undefined && latestLoan && (latestLoan as any)[4],
    },
    watch: true,
  });

  // Use live outstanding if available, fallback to cached
  const displayOutstanding = liveOutstanding !== undefined ? (liveOutstanding as unknown as bigint) : activeOutstanding;

  const handleRequestLoan = async () => {
    if (!loanAmount || !connectedAddress) return;
    
    setIsLoading(true);
    try {
      const principal = parseLoanAmount(loanAmount);
      if (!principal) return;
      if (!CONTRACT_ADDRESS || !CONTRACT_ABI) throw new Error("Contract not available");

      // === Meta: Request Loan ===
      const nonce1 = (await publicClient.readContract({
        address: CONTRACT_ADDRESS,
        abi: CONTRACT_ABI,
        functionName: "nonces",
        args: [connectedAddress],
      })) as bigint;
      const deadline1 = BigInt(Math.floor(Date.now() / 1000) + 3600);

      const loanReq = {
        borrower: connectedAddress,
        amount: principal,
        nonce: nonce1,
        deadline: deadline1,
      } as const;

      const sig1 = await signTypedDataAsync({
        domain: domain as any,
        types: loanRequestTypes as any,
        primaryType: "LoanRequest",
        message: loanReq as any,
      });

      const req1 = await fetch("/api/meta/request-loan", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          chainId: CHAIN_ID,
          contractAddress: CONTRACT_ADDRESS,
          req: {
            borrower: loanReq.borrower,
            amount: loanReq.amount.toString(),
            nonce: loanReq.nonce.toString(),
            deadline: loanReq.deadline.toString(),
          },
          signature: sig1,
        }),
      });
      if (!req1.ok) throw new Error(`Relayer request failed: ${await req1.text()}`);
      const req1Json = await req1.json();
      console.log("Loan request completed:", { txHash: req1Json.txHash, status: req1Json.status });
      let loanIdStr = (req1Json as { loanId: string | null }).loanId ?? null;

      // Fallback: derive latest loanId from chain if API couldn't determine it yet
      if (!loanIdStr) {
        try {
          const ids = (await publicClient.readContract({
            address: CONTRACT_ADDRESS,
            abi: CONTRACT_ABI,
            functionName: "getBorrowerLoanIds",
            args: [connectedAddress],
          })) as bigint[];
          if (ids && ids.length > 0) {
            loanIdStr = ids[ids.length - 1].toString();
          }
        } catch (e) {
          console.warn("Failed to derive loanId from chain:", e);
        }
      }

      if (!loanIdStr) {
        throw new Error("Loan request submitted but loanId not available yet. Please try again in a moment.");
      }

      // === Meta: Disburse Loan ===
      const nonce2 = (await publicClient.readContract({
        address: CONTRACT_ADDRESS,
        abi: CONTRACT_ABI,
        functionName: "nonces",
        args: [connectedAddress],
      })) as bigint;
      const deadline2 = BigInt(Math.floor(Date.now() / 1000) + 3600);

      const disburseReq = {
        borrower: connectedAddress,
        loanId: BigInt(loanIdStr),
        to: connectedAddress,
        nonce: nonce2,
        deadline: deadline2,
      } as const;

      const sig2 = await signTypedDataAsync({
        domain: domain as any,
        types: disburseRequestTypes as any,
        primaryType: "DisburseRequest",
        message: disburseReq as any,
      });

      const req2 = await fetch("/api/meta/disburse-loan", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          chainId: CHAIN_ID,
          contractAddress: CONTRACT_ADDRESS,
          req: {
            borrower: disburseReq.borrower,
            loanId: disburseReq.loanId.toString(),
            to: disburseReq.to,
            nonce: disburseReq.nonce.toString(),
            deadline: disburseReq.deadline.toString(),
          },
          signature: sig2,
        }),
      });
      if (!req2.ok) throw new Error(`Relayer disburse failed: ${await req2.text()}`);
      const req2Json = await req2.json();
      console.log("Loan disbursement completed:", { txHash: req2Json.txHash, status: req2Json.status });

      // Refresh frontend state
      await refetchBorrowerLoanIds();
      await refetchLatestLoan();
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
                      {displayOutstanding !== undefined ? formatUSDC(roundDownToNearestPenny(displayOutstanding)) : "-"}
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
                      <span className="font-medium text-orange-500">{displayOutstanding !== undefined ? formatUSDC(roundDownToNearestPenny(displayOutstanding)) : "-"}</span>
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
                        if (!latestLoanId || !displayOutstanding || !connectedAddress) return;
                        setIsLoading(true);
                        try {
                          console.log("Starting full repayment process (gasless meta)...");
                          if (!CONTRACT_ADDRESS || !CONTRACT_ABI) throw new Error("Missing contracts");
                          // Always fetch the live outstanding including accrued interest and round UP to nearest cent
                          const liveOutstanding = (await publicClient.readContract({
                            address: CONTRACT_ADDRESS,
                            abi: CONTRACT_ABI,
                            functionName: "getCurrentOutstandingAmount",
                            args: [latestLoanId as bigint],
                          })) as bigint;
                          const amountToRepay = roundUpToNearestPenny(liveOutstanding);

                          // Check USDC balance first
                          await checkUSDCBalance(amountToRepay);

                          if (!CONTRACT_ADDRESS || !CONTRACT_ABI || !USDC_ADDRESS || !USDC_ABI) throw new Error("Missing contracts");

                          // 1) Try to build EIP-2612 permit for USDC (spender = micro contract). If it fails (e.g. stale USDC), fallback to allowance.
                          let permitPayload: | { value: string; deadline: string; v: number; r: `0x${string}`; s: `0x${string}` } | undefined;
                          try {
                            const usdcNonce = (await publicClient.readContract({
                              address: USDC_ADDRESS,
                              abi: USDC_ABI,
                              functionName: "nonces",
                              args: [connectedAddress],
                            })) as bigint;
                            const permitDeadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
                            const permitMsg = {
                              owner: connectedAddress,
                              spender: CONTRACT_ADDRESS,
                              value: amountToRepay,
                              nonce: usdcNonce,
                              deadline: permitDeadline,
                            } as const;
                            const permitSig = await signTypedDataAsync({
                              domain: usdcPermitDomain as any,
                              types: permitTypes as any,
                              primaryType: "Permit",
                              message: permitMsg as any,
                            });
                            const { v, r, s } = splitSignature(permitSig);
                            permitPayload = {
                              value: permitMsg.value.toString(),
                              deadline: permitMsg.deadline.toString(),
                              v,
                              r,
                              s,
                            };
                          } catch (e) {
                            console.warn("USDC permit unavailable, falling back to allowance path:", e);
                            await ensureAllowance(amountToRepay);
                            permitPayload = undefined;
                          }

                          // 2) Build RepayRequest and signature
                          const repayNonce = (await publicClient.readContract({
                            address: CONTRACT_ADDRESS,
                            abi: CONTRACT_ABI,
                            functionName: "nonces",
                            args: [connectedAddress],
                          })) as bigint;
                          const repayDeadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
                          const repayReq = {
                            borrower: connectedAddress,
                            loanId: latestLoanId as bigint,
                            amount: amountToRepay,
                            nonce: repayNonce,
                            deadline: repayDeadline,
                          } as const;
                          const repaySig = await signTypedDataAsync({
                            domain: domain as any,
                            types: repayRequestTypes as any,
                            primaryType: "RepayRequest",
                            message: repayReq as any,
                          });

                          // 3) Call relayer API
                          const payload: any = {
                            method: "POST",
                            headers: { "Content-Type": "application/json" },
                            body: JSON.stringify({
                              chainId: CHAIN_ID,
                              contractAddress: CONTRACT_ADDRESS,
                              req: {
                                borrower: repayReq.borrower,
                                loanId: repayReq.loanId.toString(),
                                amount: repayReq.amount.toString(),
                                nonce: repayReq.nonce.toString(),
                                deadline: repayReq.deadline.toString(),
                              },
                              signature: repaySig,
                              ...(permitPayload ? { permit: permitPayload } : {}),
                            }),
                          };
                          const resp = await fetch("/api/meta/repay-loan", payload);
                          if (!resp.ok) throw new Error(await resp.text());
                          const result = await resp.json();

                          console.log("Repayment completed successfully (gasless)!", { txHash: result.txHash, status: result.status });
                          
                          // Transaction is already mined (relayer waited for confirmation)
                          // Now refetch state to reflect the changes
                          await refetchBorrowerLoanIds();
                          await refetchLatestLoan();
                          await refetchLiveOutstanding();
                        } catch (error) {
                          const errorType = handleTransferError(error);
                          switch (errorType) {
                            case "TRANSFER_FAILED":
                              console.error("USDC transfer failed. Please check your USDC balance and try again.");
                              break;
                            case "ERC20_APPROVAL_NEEDED":
                              console.error("ERC20 Allowance Error (should be handled via permit). Try again.");
                              break;
                            case "INSUFFICIENT_FUNDS":
                              console.error("Insufficient funds for USDC balance.");
                              break;
                            case "USER_REJECTED":
                              console.error("Signature was rejected by user.");
                              break;
                            default:
                              console.error("Unknown error occurred:", error);
                          }
                        } finally {
                          setIsLoading(false);
                        }
                      }}
                      disabled={isLoading || !displayOutstanding}
                      className="w-full bg-green-500 hover:bg-green-600 disabled:bg-gray-400 text-white font-bold py-2 px-4 rounded-lg transition-colors"
                    >
                      {isLoading ? "Processing..." : `Pay ${displayOutstanding !== undefined ? formatUSDC(roundUpToNearestPenny(displayOutstanding)) : "-"}`}
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
                          if (!latestLoanId || !repayAmount || !connectedAddress) return;
                          const repayAmountBigInt = parseLoanAmount(repayAmount);
                          if (!repayAmountBigInt) return;
                          setIsLoading(true);
                          try {
                            console.log("Starting partial repayment process (gasless meta)...");

                            // Check USDC balance first
                            await checkUSDCBalance(repayAmountBigInt);

                            if (!CONTRACT_ADDRESS || !CONTRACT_ABI || !USDC_ADDRESS || !USDC_ABI) throw new Error("Missing contracts");

                            // 1) Try USDC EIP-2612 permit; fallback to allowance if unavailable
                            let permitPayload: | { value: string; deadline: string; v: number; r: `0x${string}`; s: `0x${string}` } | undefined;
                            try {
                              const usdcNonce = (await publicClient.readContract({
                                address: USDC_ADDRESS,
                                abi: USDC_ABI,
                                functionName: "nonces",
                                args: [connectedAddress],
                              })) as bigint;
                              const permitDeadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
                              const permitMsg = {
                                owner: connectedAddress,
                                spender: CONTRACT_ADDRESS,
                                value: repayAmountBigInt,
                                nonce: usdcNonce,
                                deadline: permitDeadline,
                              } as const;
                              const permitSig = await signTypedDataAsync({
                                domain: usdcPermitDomain as any,
                                types: permitTypes as any,
                                primaryType: "Permit",
                                message: permitMsg as any,
                              });
                              const { v, r, s } = splitSignature(permitSig);
                              permitPayload = {
                                value: permitMsg.value.toString(),
                                deadline: permitMsg.deadline.toString(),
                                v,
                                r,
                                s,
                              };
                            } catch (e) {
                              console.warn("USDC permit unavailable (partial), falling back to allowance path:", e);
                              await ensureAllowance(repayAmountBigInt);
                              permitPayload = undefined;
                            }

                            // 2) RepayRequest signed by borrower
                            const repayNonce = (await publicClient.readContract({
                              address: CONTRACT_ADDRESS,
                              abi: CONTRACT_ABI,
                              functionName: "nonces",
                              args: [connectedAddress],
                            })) as bigint;
                            const repayDeadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
                            const repayReq = {
                              borrower: connectedAddress,
                              loanId: latestLoanId as bigint,
                              amount: repayAmountBigInt,
                              nonce: repayNonce,
                              deadline: repayDeadline,
                            } as const;
                            const repaySig = await signTypedDataAsync({
                              domain: domain as any,
                              types: repayRequestTypes as any,
                              primaryType: "RepayRequest",
                              message: repayReq as any,
                            });

                            // 3) Call relayer API
                            const resp = await fetch("/api/meta/repay-loan", {
                              method: "POST",
                              headers: { "Content-Type": "application/json" },
                              body: JSON.stringify({
                                chainId: CHAIN_ID,
                                contractAddress: CONTRACT_ADDRESS,
                                req: {
                                  borrower: repayReq.borrower,
                                  loanId: repayReq.loanId.toString(),
                                  amount: repayReq.amount.toString(),
                                  nonce: repayReq.nonce.toString(),
                                  deadline: repayReq.deadline.toString(),
                                },
                                signature: repaySig,
                                ...(permitPayload ? { permit: permitPayload } : {}),
                              }),
                            });
                            if (!resp.ok) throw new Error(await resp.text());
                            const result = await resp.json();

                            console.log("Partial repayment completed successfully (gasless)!", { txHash: result.txHash, status: result.status });
                            setRepayAmount("");
                            // Transaction is already mined (relayer waited for confirmation)
                            // Now refetch state to reflect the changes
                            await refetchBorrowerLoanIds();
                            await refetchLatestLoan();
                            await refetchLiveOutstanding();
                          } catch (error) {
                            const errorType = handleTransferError(error);
                            switch (errorType) {
                              case "TRANSFER_FAILED":
                                console.error("USDC transfer failed. Please check your USDC balance and try again.");
                                break;
                              case "ERC20_APPROVAL_NEEDED":
                                console.error("ERC20 Allowance Error (should be handled via permit). Try again.");
                                break;
                              case "INSUFFICIENT_FUNDS":
                                console.error("Insufficient funds for USDC balance.");
                                break;
                              case "USER_REJECTED":
                                console.error("Signature was rejected by user.");
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