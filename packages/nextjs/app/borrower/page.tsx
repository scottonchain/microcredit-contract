"use client";

import React, { useEffect, useMemo, useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { createPublicClient, http } from "viem";
import { localhost } from "viem/chains";
import deployedContracts from "~~/contracts/deployedContracts";
import type { NextPage } from "next";
import { useAccount, useSignTypedData } from "wagmi";
import { CreditCardIcon, CalculatorIcon, InformationCircleIcon, DocumentDuplicateIcon, CurrencyDollarIcon } from "@heroicons/react/24/outline";
import Link from "next/link";
import { useScaffoldReadContract } from "~~/hooks/scaffold-eth";
import { formatUSDC, getCreditScoreColor } from "~~/utils/format";
import QRCodeDisplay from "~~/components/QRCodeDisplay";
import { useDisplayName } from "~~/components/scaffold-eth/DisplayNameContext";
import { splitSignature } from "../../utils/usdc";

const BorrowPage: NextPage = () => {
  const { address: connectedAddress } = useAccount();
  const [loanAmount, setLoanAmount] = useState(""); // For loan requests
  const [repayAmount, setRepayAmount] = useState(""); // For partial repayments
  const [repaymentPeriod, setRepaymentPeriod] = useState(7); // Default 1 week
  const [isLoading, setIsLoading] = useState(false);
  const [permitError, setPermitError] = useState<string | null>(null);

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

  // (event-driven sync inserted below after dependencies)

  // (moved) event-driven sync is defined below after dependencies are declared

  // Helper function to round up to the nearest penny (0.01 USDC = 10000 wei)
  const roundUpToNearestPenny = (amount: bigint): bigint => {
    const pennyInWei = 10000n;
    if (amount % pennyInWei === 0n) return amount;
    return ((amount / pennyInWei) + 1n) * pennyInWei;
  };

  // Preferred display rounding (half-up) for parity with contract helper
  const roundToCentHalfUp = (amount: bigint): bigint => ((amount + 5_000n) / 10_000n) * 10_000n;

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

  // Dev-only domain sanity: warn if token name differs
  useEffect(() => {
    if (usdcTokenName && process.env.NODE_ENV !== "production") {
      if (usdcTokenName !== "USD Coin") {
        console.warn(`[permit-domain] USDC token name is "${usdcTokenName}". Ensure relayer & client use the exact same domain name.`);
      }
    }
  }, [usdcTokenName]);

  // Note: No approval fallback. Repayments require ERC-2612 permit. Dev escape hatch is intentionally disabled by default.

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

  const borrowAndDisburseTypes = {
    BorrowAndDisburse: [
      { name: "borrower", type: "address" },
      { name: "amount", type: "uint256" },
      { name: "to", type: "address" },
      { name: "repaymentPeriod", type: "uint256" },
      { name: "maxAprBps", type: "uint256" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" },
    ],
  } as const;

  // Removed RepayRequest typed-data. Repay now uses only USDC Permit.

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

  // Using splitSignature from utils/usdc.

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
  const queryClient = useQueryClient();
  const signingRef = useRef(false);

  // Borrower loans (ids) — keep the full result object for queryKey/loading
  const borrowerLoanIdsRes = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getBorrowerLoanIds" as any,
    args: connectedAddress ? ([connectedAddress as `0x${string}`] as any) : undefined,
    watch: true,
    query: { refetchOnMount: "always", refetchOnWindowFocus: "always", staleTime: 0, gcTime: 0 },
  });
  const borrowerLoanIds = borrowerLoanIdsRes.data as bigint[] | undefined;
  // Active id (newest) — deterministic within component
  const activeLoanId = useMemo(() => {
    if (!Array.isArray(borrowerLoanIds) || borrowerLoanIds.length === 0) return undefined;
    return [...borrowerLoanIds].sort((a, b) => (a > b ? -1 : 1))[0];
  }, [borrowerLoanIds]);

  // Loan details — keep result object
  const loanRes = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getLoan" as any,
    args: activeLoanId !== undefined ? ([activeLoanId as bigint] as any) : undefined,
    query: {
      enabled: activeLoanId !== undefined,
      refetchOnMount: "always",
      refetchOnWindowFocus: "always",
      staleTime: 0,
      gcTime: 0,
    },
    watch: true,
  });
  const activeLoan = loanRes.data as any | undefined;
  const loanIsActive = !!activeLoan?.[4];
  const activePrincipal: bigint | undefined = loanIsActive ? activeLoan?.[0] : undefined;
  const activeOutstanding: bigint | undefined = loanIsActive ? activeLoan?.[1] : undefined;

  // Outstanding rounded — disable when inactive; keep result object
  const outRoundedRes = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getOutstandingRoundedToCent" as any,
    args: activeLoanId !== undefined ? ([activeLoanId as bigint] as any) : undefined,
    query: {
      enabled: activeLoanId !== undefined && loanIsActive,
      refetchOnMount: "always",
      refetchOnWindowFocus: "always",
      staleTime: 0,
      gcTime: 0,
    },
    watch: true,
  });
  const roundedOutstanding = outRoundedRes.data as bigint | undefined;
  // Use rounded outstanding if available, fallback to cached
  const displayOutstanding: bigint = loanIsActive ? (roundedOutstanding ?? activeOutstanding ?? 0n) : 0n;

  // Deterministic refresh after a repay/disburse mutation
  const refreshAfterMutation = async () => {
    // 1) Invalidate ids so activeLoanId can flip
    if ((borrowerLoanIdsRes as any).queryKey) {
      await queryClient.invalidateQueries({ queryKey: (borrowerLoanIdsRes as any).queryKey });
    } else if (borrowerLoanIdsRes.refetch) {
      await borrowerLoanIdsRes.refetch();
    }
    // 2) Allow activeLoanId to recompute
    await Promise.resolve();
    // 3) Invalidate/Refetch loan + outstanding for the (possibly new) id
    const ops: Promise<any>[] = [];
    if ((loanRes as any).queryKey) ops.push(queryClient.invalidateQueries({ queryKey: (loanRes as any).queryKey }));
    else if (loanRes.refetch) ops.push(loanRes.refetch());
    if ((outRoundedRes as any).queryKey) ops.push(queryClient.invalidateQueries({ queryKey: (outRoundedRes as any).queryKey }));
    else if (outRoundedRes.refetch) ops.push(outRoundedRes.refetch());
    await Promise.allSettled(ops);
  };

  // Event-driven sync to avoid races after repayments/disbursements
  useEffect(() => {
    if (!CONTRACT_ADDRESS || !CONTRACT_ABI || !connectedAddress) return;
    const isMine = (a?: any) => a?.toLowerCase?.() === connectedAddress.toLowerCase();

    const off1 = publicClient.watchContractEvent({
      address: CONTRACT_ADDRESS,
      abi: CONTRACT_ABI,
      eventName: "LoanRepaid",
      onLogs: (logs: any[]) => {
        if (logs?.some?.(l => isMine((l as any)?.args?.borrower))) void refreshAfterMutation();
      },
    });
    const off2 = publicClient.watchContractEvent({
      address: CONTRACT_ADDRESS,
      abi: CONTRACT_ABI,
      eventName: "MetaLoanRepaid",
      onLogs: (logs: any[]) => {
        if (logs?.some?.(l => isMine((l as any)?.args?.borrower))) void refreshAfterMutation();
      },
    });
    const off3 = publicClient.watchContractEvent({
      address: CONTRACT_ADDRESS,
      abi: CONTRACT_ABI,
      eventName: "MetaLoanDisbursed",
      onLogs: (logs: any[]) => {
        if (logs?.some?.(l => isMine((l as any)?.args?.borrower))) void refreshAfterMutation();
      },
    });

    return () => {
      try {
        off1?.();
        off2?.();
        off3?.();
      } catch {
        /* noop */
      }
    };
  }, [CONTRACT_ADDRESS, CONTRACT_ABI, publicClient, connectedAddress]);

  const handleOneClickBorrow = async () => {
    if (!loanAmount || !connectedAddress) return;
    
    setIsLoading(true);
    try {
      const principal = parseLoanAmount(loanAmount);
      if (!principal) return;
      if (!CONTRACT_ADDRESS || !CONTRACT_ABI) throw new Error("Contract not available");
      // === One-Click Borrow (BorrowAndDisburse) ===
      const nonce = (await publicClient.readContract({
        address: CONTRACT_ADDRESS,
        abi: CONTRACT_ABI,
        functionName: "nonces",
        args: [connectedAddress],
      })) as bigint;
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
      const repaymentPeriodSecs = BigInt(repaymentPeriod * 24 * 60 * 60);

      // APR guard: use the current on-chain rate (basis points)
      const maxAprBps = loanRateBp !== undefined ? BigInt(loanRateBp as bigint) : 10_000n; // default cap 100%

      const borrowReq = {
        borrower: connectedAddress,
        amount: principal,
        to: connectedAddress,
        repaymentPeriod: repaymentPeriodSecs,
        maxAprBps,
        nonce,
        deadline,
      } as const;

      const sig = await signTypedDataAsync({
        domain: domain as any,
        types: borrowAndDisburseTypes as any,
        primaryType: "BorrowAndDisburse",
        message: borrowReq as any,
      });

      const resp = await fetch("/api/meta/borrow", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          chainId: CHAIN_ID,
          contractAddress: CONTRACT_ADDRESS,
          req: {
            borrower: borrowReq.borrower,
            amount: borrowReq.amount.toString(),
            to: borrowReq.to,
            repaymentPeriod: borrowReq.repaymentPeriod.toString(),
            maxAprBps: borrowReq.maxAprBps.toString(),
            nonce: borrowReq.nonce.toString(),
            deadline: borrowReq.deadline.toString(),
          },
          signature: sig,
        }),
      });
      if (!resp.ok) throw new Error(`Relayer borrow failed: ${await resp.text()}`);
      const resJson = await resp.json();
      console.log("One-click borrow completed:", { txHash: resJson.txHash, status: resJson.status, loanId: resJson.loanId });

      // Refresh frontend state deterministically
      await refreshAfterMutation();
      setLoanAmount("");
    } catch (error) {
      console.error("Error in one-click borrow:", error);
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

  // Prefill amount when eligible known
  useEffect(() => {
    if (hasCredit && maxEligibleAmount > 0n && loanAmount === "") {
      const floorTwoDecimals = Math.floor(Number(maxEligibleAmount) / 1e4) / 100; // safe floor
      setLoanAmount(floorTwoDecimals.toFixed(2));
    }
  }, [hasCredit, maxEligibleAmount, loanAmount]);

  // Ensure user-entered amount does not exceed maximum
  const isAmountTooHigh = () => {
    const parsed = parseLoanAmount(loanAmount);
    return parsed !== null && parsed > maxEligibleAmount;
  };

  const [showInfo, setShowInfo] = useState(false);
  const attestationUrl = connectedAddress ? `${window.location.origin}/attest?borrower=${connectedAddress}` : "";

  return (
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
                      {displayOutstanding !== undefined ? formatUSDC(displayOutstanding) : "-"}
                    </div>
                    <div className="text-sm text-gray-600">Payoff Amount</div>
                    <div className="text-xs text-gray-500 mt-1">Interest starts 24 hours after disbursement. You can repay immediately.</div>
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
                onClick={handleOneClickBorrow}
                disabled={!loanAmount || !connectedAddress || isLoading || !hasCredit || isAmountTooHigh()}
                className="w-full bg-green-500 hover:bg-green-600 disabled:bg-gray-400 text-white font-bold py-3 px-4 rounded-lg transition-colors mb-4"
              >
                {isLoading ? "Processing..." : "One-Click Borrow — Sign Once, Get Funds"}
              </button>
              <p className="text-xs text-gray-600 -mt-2 mb-2 text-center">No gas fees — you’ll just sign messages; LoanLink pays gas.</p>

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

          {/* Active Loan & Repayment Section (persistently mounted) */}
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
                      <span className="font-medium">{loanRes.isLoading ? <span className="skeleton h-4 w-24 inline-block" /> : (activePrincipal !== undefined ? formatUSDC(activePrincipal) : "-")}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-gray-600">Outstanding:</span>
                      <span className="font-medium">{outRoundedRes.isLoading ? <span className="skeleton h-4 w-24 inline-block" /> : (displayOutstanding !== undefined ? formatUSDC(displayOutstanding) : "-")}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-gray-600">Status:</span>
                      <span className="font-medium">{loanIsActive ? "Current" : "Closed"}</span>
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
                <p className="text-xs text-gray-600 mb-3">One approval, no gas. You’ll sign a permit; our relayer submits the repayment.</p>
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                  {/* Full Repayment */}
                  <div className="bg-green-50 border border-green-200 rounded-lg p-4">
                    <h4 className="font-medium text-green-800 mb-2">Full Repayment</h4>
                    <p className="text-sm text-green-600 mb-3">Pay off your entire outstanding balance</p>
                    <button
                      disabled={
                        isLoading ||
                        signingRef.current ||
                        activeLoanId === undefined ||
                        !loanIsActive ||
                        displayOutstanding === undefined
                      }
                      onClick={async () => {
                        if (signingRef.current) return;
                        if (!activeLoanId || !connectedAddress) return;
                        signingRef.current = true;
                        setIsLoading(true);
                        try {
                          setPermitError(null);
                          console.log("Starting full repayment process (gasless meta)...");
                          if (!CONTRACT_ADDRESS || !CONTRACT_ABI) throw new Error("Missing contracts");
                          // Read canonical outstanding rounded to cent (contract view)
                          const out = (await publicClient.readContract({
                            address: CONTRACT_ADDRESS,
                            abi: CONTRACT_ABI,
                            functionName: "getOutstandingRoundedToCent",
                            args: [activeLoanId as bigint],
                          })) as bigint;
                          const amountToRepay = out;

                          // Check USDC balance first
                          await checkUSDCBalance(amountToRepay);

                          if (!CONTRACT_ADDRESS || !CONTRACT_ABI || !USDC_ADDRESS || !USDC_ABI) throw new Error("Missing contracts");

                          // 1) Build EIP-2612 permit for USDC (spender = micro contract). Permit is REQUIRED.
                          let permitPayload: { value: string; deadline: string; v: number; r: `0x${string}`; s: `0x${string}` };
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
                            console.count("permit:sign");
                            signingRef.current = true;
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
                          } catch (e: any) {
                            console.error("Permit signing failed:", e);
                            setPermitError(e?.message?.includes("expired") || e?.message?.includes("nonce") ? "Permit expired or already used. Please try again." : "Permit required. This token must support ERC-2612.");
                            return;
                          }

                          // 2) Call relayer API — single approval (permit only). amount: "0" => repay-all up to permit value
                          const resp = await fetch("/api/meta/repay-one", {
                            method: "POST",
                            headers: { "Content-Type": "application/json" },
                            body: JSON.stringify({
                              chainId: CHAIN_ID,
                              contractAddress: CONTRACT_ADDRESS,
                              borrower: connectedAddress,
                              loanId: (activeLoanId as bigint).toString(),
                              amount: "0",
                              permit: permitPayload,
                            }),
                          });
                          if (!resp.ok) throw new Error(await resp.text());
                          const result = await resp.json();
                          console.log("Repayment submitted (gasless, single approval)", { txHash: result.txHash, amountUsed: result.amountUsed });

                          // Transaction is mined. Refetch state in parallel.
                          await refreshAfterMutation();
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
                          signingRef.current = false;
                          setIsLoading(false);
                        }
                      }}
                      className="w-full bg-green-500 hover:bg-green-600 disabled:bg-gray-400 text-white font-bold py-2 px-4 rounded-lg transition-colors"
                    >
                      {isLoading ? "Processing..." : loanIsActive && displayOutstanding !== undefined ? `Pay ${formatUSDC(displayOutstanding)}` : "Pay"}
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
                        disabled={
                          isLoading ||
                          signingRef.current ||
                          activeLoanId === undefined ||
                          !loanIsActive ||
                          !repayAmount ||
                          !parseLoanAmount(repayAmount)
                        }
                        onClick={async () => {
                          if (signingRef.current) return;
                          if (!activeLoanId || !repayAmount || !connectedAddress) return;
                          signingRef.current = true;
                          const repayAmountBigInt = parseLoanAmount(repayAmount);
                          if (!repayAmountBigInt) return;
                          setIsLoading(true);
                          try {
                            console.log("Starting partial repayment process (gasless meta)...");

                            // Check USDC balance first
                            await checkUSDCBalance(repayAmountBigInt);

                            if (!CONTRACT_ADDRESS || !CONTRACT_ABI || !USDC_ADDRESS || !USDC_ABI) throw new Error("Missing contracts");

                            // 1) Build USDC EIP-2612 permit (REQUIRED)
                            let permitPayload: { value: string; deadline: string; v: number; r: `0x${string}`; s: `0x${string}` };
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
                              console.count("permit:sign");
                              signingRef.current = true;
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
                            } catch (e: any) {
                              console.error("Permit signing failed:", e);
                              setPermitError(e?.message?.includes("expired") || e?.message?.includes("nonce") ? "Permit expired or already used. Please try again." : "Permit required. This token must support ERC-2612.");
                              return;
                            }
                            // 2) Call relayer API — single approval (permit only)
                            const resp = await fetch("/api/meta/repay-one", {
                              method: "POST",
                              headers: { "Content-Type": "application/json" },
                              body: JSON.stringify({
                                chainId: CHAIN_ID,
                                contractAddress: CONTRACT_ADDRESS,
                                borrower: connectedAddress,
                                loanId: (activeLoanId as bigint).toString(),
                                amount: repayAmountBigInt.toString(),
                                permit: permitPayload,
                              }),
                            });
                            if (!resp.ok) throw new Error(await resp.text());
                            const result = await resp.json();
                            console.log("Partial repayment submitted (gasless, single approval)", { txHash: result.txHash, amountUsed: result.amountUsed });
                            setRepayAmount("");
                            // Transaction is mined. Refetch state in parallel.
                            await refreshAfterMutation();
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
                            signingRef.current = false;
                            setIsLoading(false);
                          }
                        }}
                        className="bg-blue-500 hover:bg-blue-600 disabled:bg-gray-400 text-white font-bold py-2 px-4 rounded-lg transition-colors"
                      >
                        {isLoading ? "Processing..." : "Repay"}
                      </button>
                    </div>
                  </div>
                  {permitError && (
                    <div className="col-span-1 md:col-span-2 mt-2 p-3 rounded-md bg-red-50 border border-red-200 text-red-700 text-sm">
                      {permitError}
                    </div>
                  )}
                </div>
              </div>
            </div>
        </div>
      </div>
  );
};

export default BorrowPage; 