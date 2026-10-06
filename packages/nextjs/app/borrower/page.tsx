"use client";

import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import type { NextPage } from "next";
import { useAccount, usePublicClient, useSignTypedData, useWriteContract } from "wagmi";
import { CreditCardIcon, CalculatorIcon, DocumentDuplicateIcon, CurrencyDollarIcon } from "@heroicons/react/24/outline";
import Link from "next/link";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { useUsdcWrite } from "~~/hooks/useUsdc";
import { getParsedError } from "~~/utils/scaffold-eth";
import { TestnetMint } from "~~/components/TestnetMint";
import { toast } from "react-hot-toast";
import { formatUSDC } from "~~/utils/format";
import {
  type OriginationIntent,
  type ReconcileFacts,
  clearIntent,
  decideOrigination,
  intentKey,
  isUserRejection,
  loadIntent,
  matchRequestedLoan,
  newIntent,
  reconcileIntent,
  saveIntent,
} from "~~/utils/originationIntent";
import { type Signer, assertSameSigner, captureSigner, requireHash } from "~~/utils/walletWrite";
import { relayerErrorMessage } from "~~/utils/contractErrors";
import QRCodeDisplay from "~~/components/QRCodeDisplay";
import { useDisplayName } from "~~/components/scaffold-eth/DisplayNameContext";
import { MICRO_DOMAIN, type PermitDomain, TYPES, readPermitDomain, splitSignature } from "~~/utils/eip712";
import {
  BASE_PATH,
  CHAIN_ID,
  LENS_ABI,
  LENS_ADDRESS,
  MICROCREDIT_ABI,
  MICROCREDIT_ADDRESS,
  RELAYER_ENABLED,
  USDC_ABI,
  USDC_ADDRESS,
} from "~~/utils/microcredit";

const BorrowPage: NextPage = () => {
  const { address: connectedAddress } = useAccount();
  // Wallet-direct writes (used when this build has no relayer): the borrower signs and pays for each transaction.
  const { writeContractAsync: writeCreditAsync } = useScaffoldWriteContract({ contractName: "DecentralizedMicrocredit" });
  // Raw wagmi write for the two origination transactions: it returns the hash as soon as the wallet does, so the
  // intent below is bound to its transaction before the receipt is awaited (scaffold's transactor returns after mining).
  const { writeContractAsync: wagmiWriteAsync } = useWriteContract();
  const writeUsdc = useUsdcWrite();
  const [loanAmount, setLoanAmount] = useState(""); // For loan requests
  const [repayAmount, setRepayAmount] = useState(""); // For partial repayments
  const [repaymentPeriod, setRepaymentPeriod] = useState(7); // Default 1 week (relayed app only)
  // Wallet-direct origination: the persisted intent and what reconciliation currently says about it.
  const [intent, setIntentState] = useState<OriginationIntent | null>(null);
  const [reconcileNote, setReconcileNote] = useState("");
  const [mayDismiss, setMayDismiss] = useState(false);
  const [offeredLoanId, setOfferedLoanId] = useState<bigint | undefined>(undefined);
  // The term requestLoan applies when the loan is not relayed (seconds, from the deployed pool).
  const { data: defaultLoanTerm } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "DEFAULT_LOAN_TERM",
  });
  const effectivePeriodDays = RELAYER_ENABLED
    ? repaymentPeriod
    : defaultLoanTerm !== undefined
      ? Number(defaultLoanTerm) / 86400
      : 30;
  const [isLoading, setIsLoading] = useState(false);
  const [permitError, setPermitError] = useState<string | null>(null);

  // Fetch pool info for total participants
  const { data: poolInfo } = useScaffoldReadContract({
    contractName: "MicrocreditLens",
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

  // [limit, available]: your own credit not committed to others plus backing received, and how
  // much of it your open loans leave unused.
  const { data: borrowLimit } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getBorrowLimit",
    args: [connectedAddress],
  });
  // While paused, new loans and disbursements revert (LendingPaused); repayments still work.
  const { data: lendingPaused } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "paused",
  });
  // Interest you have paid (net of the protocol fee): the part of your own credit you earned.
  const { data: duesPaid } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "duesPaid",
    args: [connectedAddress],
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
    if (!borrowLimit) return 0n;
    const baseAmount = borrowLimit[1];
    
    // Calculate weeks from repayment period (repaymentPeriod is in days)
    const weeks = Math.ceil(effectivePeriodDays / 7);

    // For 1 week, full amount is available. For each additional week, reduce by 1%
    if (weeks <= 1) {
      return roundDownToNearestPenny(baseAmount);
    }

    // Calculate reduction factor: (0.99)^(weeks-1)
    const reductionFactor = Math.pow(0.99, weeks - 1);
    const reducedAmount = BigInt(Math.floor(Number(baseAmount) * reductionFactor));
    return roundDownToNearestPenny(reducedAmount);
  }, [borrowLimit, effectivePeriodDays]);

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

  const publicClient = usePublicClient({ chainId: CHAIN_ID });

  // The token's EIP-2612 domain, read from the token and checked against its DOMAIN_SEPARATOR
  // (MockUSDC and Circle's USDC differ in name and version).
  const [usdcPermitDomain, setUsdcPermitDomain] = useState<PermitDomain | undefined>(undefined);
  useEffect(() => {
    let cancelled = false;
    if (!publicClient || !USDC_ADDRESS) return;
    readPermitDomain(publicClient, USDC_ADDRESS, CHAIN_ID)
      .then(domain => {
        if (!cancelled) setUsdcPermitDomain(domain);
      })
      .catch(e => console.error("Unable to read the USDC permit domain", e));
    return () => {
      cancelled = true;
    };
  }, [publicClient]);

  // Note: No approval fallback. Repayments require ERC-2612 permit. Dev escape hatch is intentionally disabled by default.

  // Helper function to check USDC balance
  const checkUSDCBalance = async (amount: bigint) => {
    if (!connectedAddress || !USDC_ADDRESS || !USDC_ABI || !publicClient) {
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

  // EIP-712 signing
  const { signTypedDataAsync } = useSignTypedData();

  const domain = MICRO_DOMAIN(CHAIN_ID, MICROCREDIT_ADDRESS);
  const borrowAndDisburseTypes = { BorrowAndDisburse: TYPES.BorrowAndDisburse };

  // ERC-2612 permit domain; uses the on-chain token name when available ("USD Coin" for MockUSDC).
  const permitTypes = { Permit: TYPES.Permit };

  // Preview loan terms when amount or repayment period changes
  const { data: previewTermsData } = useScaffoldReadContract({
    contractName: "MicrocreditLens",
    functionName: "previewLoanTerms",
    args: [
      connectedAddress as `0x${string}` | undefined,
      connectedAddress && loanAmount ? parseLoanAmount(loanAmount) ?? undefined : undefined,
      connectedAddress && loanAmount ? BigInt(Math.round(effectivePeriodDays * 24 * 60 * 60)) : undefined,
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

  // Schedule of the newest loan: [status, term, requestedAt, disbursedAt, dueAt] (seconds)
  const { data: loanTerms } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getLoanTerms",
    args: [activeLoanId],
    query: { enabled: activeLoanId !== undefined },
  });
  // A loan that is requested and reserved but not yet disbursed (LoanStatus.Requested = 1): the wallet-direct
  // path needs a second transaction for it, and a reload must offer that step rather than a new loan.
  const loanIsRequested = loanIsActive && loanTerms !== undefined && Number(loanTerms[0]) === 1;
  const { data: latePeriod } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "LATE_PERIOD",
  });
  const dueAt = loanTerms && loanTerms[4] > 0n ? Number(loanTerms[4]) : undefined;
  const nowSecs = Math.floor(Date.now() / 1000);
  const daysOverdue = dueAt !== undefined && nowSecs > dueAt ? Math.floor((nowSecs - dueAt) / 86400) : 0;
  const defaultableAt = dueAt !== undefined && latePeriod !== undefined ? dueAt + Number(latePeriod) : undefined;
  const formatDate = (secs: number) => new Date(secs * 1000).toLocaleDateString();

  // Outstanding rounded to the cent; the contract returns 0 once the loan is closed.
  const outRoundedRes = useScaffoldReadContract({
    contractName: "MicrocreditLens",
    functionName: "getOutstandingRoundedToCent" as any,
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

  // Event-driven sync to avoid races after repayments/disbursements. Watchers call the latest
  // refreshAfterMutation through a ref so they are not re-subscribed on every render.
  const refreshAfterMutationRef = useRef(refreshAfterMutation);
  refreshAfterMutationRef.current = refreshAfterMutation;
  useEffect(() => {
    if (!publicClient || !connectedAddress) return;
    const isMine = (a?: any) => a?.toLowerCase?.() === connectedAddress.toLowerCase();

    const off1 = publicClient.watchContractEvent({
      address: MICROCREDIT_ADDRESS,
      abi: MICROCREDIT_ABI,
      eventName: "LoanRepaid",
      onLogs: (logs: any[]) => {
        if (logs?.some?.(l => isMine((l as any)?.args?.borrower))) void refreshAfterMutationRef.current();
      },
    });
    const off2 = publicClient.watchContractEvent({
      address: MICROCREDIT_ADDRESS,
      abi: MICROCREDIT_ABI,
      eventName: "MetaLoanRepaid",
      onLogs: (logs: any[]) => {
        if (logs?.some?.(l => isMine((l as any)?.args?.borrower))) void refreshAfterMutationRef.current();
      },
    });
    const off3 = publicClient.watchContractEvent({
      address: MICROCREDIT_ADDRESS,
      abi: MICROCREDIT_ABI,
      eventName: "MetaLoanDisbursed",
      onLogs: (logs: any[]) => {
        if (logs?.some?.(l => isMine((l as any)?.args?.borrower))) void refreshAfterMutationRef.current();
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
  }, [publicClient, connectedAddress]);

  // ───────────── Wallet-direct origination: an intent bound to its receipts, failing closed ─────────────
  const storage = typeof window !== "undefined" ? window.localStorage : undefined;
  const intentStorageKey = connectedAddress
    ? intentKey(CHAIN_ID, MICROCREDIT_ADDRESS, connectedAddress as `0x${string}`)
    : undefined;
  const setIntent = useCallback(
    (next: OriginationIntent | null) => {
      if (intentStorageKey) {
        if (next) saveIntent(storage, intentStorageKey, next);
        else clearIntent(storage, intentStorageKey);
      }
      setIntentState(next);
    },
    [intentStorageKey, storage],
  );
  // The intent for this wallet: loaded on connect, and again whenever another tab changes it.
  useEffect(() => {
    if (RELAYER_ENABLED || !intentStorageKey) {
      setIntentState(null);
      return;
    }
    setIntentState(loadIntent(storage, intentStorageKey));
    const onStorage = (e: StorageEvent) => {
      if (e.key === intentStorageKey) setIntentState(loadIntent(storage, intentStorageKey));
    };
    window.addEventListener("storage", onStorage);
    return () => window.removeEventListener("storage", onStorage);
  }, [intentStorageKey, storage]);

  const newestLoanStatus = loanTerms !== undefined ? Number(loanTerms[0]) : undefined;
  // What the page may offer: unloaded reads are never "no loan", and an unresolved intent always wins.
  const decision = useMemo(
    () => decideOrigination(intent, { loanIds: borrowerLoanIds, newestLoanStatus }),
    [intent, borrowerLoanIds, newestLoanStatus],
  );

  // Reconcile an intent against the chain until it is settled: by its receipt when a hash exists, by a matching new
  // loan when the wallet returned none; then offer the second step for exactly that loan id.
  useEffect(() => {
    if (!intent || !publicClient || !connectedAddress) {
      setReconcileNote("");
      setMayDismiss(false);
      setOfferedLoanId(undefined);
      return;
    }
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const pool = { address: MICROCREDIT_ADDRESS, abi: MICROCREDIT_ABI } as const;
    const run = async () => {
      const facts: ReconcileFacts = {};
      try {
        if (intent.stage === "requesting" && intent.requestTxHash) {
          facts.requestReceipt = await publicClient
            .getTransactionReceipt({ hash: intent.requestTxHash })
            .then(r => ({ status: r.status, logs: r.logs }))
            .catch(() => null);
        } else if (intent.stage === "requesting") {
          const ids = (await publicClient.readContract({
            ...pool,
            functionName: "getBorrowerLoanIds",
            args: [connectedAddress],
          })) as readonly bigint[];
          const fresh = ids.filter(id => !intent.idsBefore.includes(id.toString()));
          facts.candidates = await Promise.all(
            fresh.map(async loanId => {
              const [loan, terms] = await Promise.all([
                publicClient.readContract({ ...pool, functionName: "getLoan", args: [loanId] }) as Promise<any>,
                publicClient.readContract({ ...pool, functionName: "getLoanTerms", args: [loanId] }) as Promise<any>,
              ]);
              return { loanId, status: Number(terms[0]), amount: loan[0] as bigint, requestedAtMs: Number(terms[2]) * 1000 };
            }),
          );
        } else if (intent.stage === "requested") {
          const terms = (await publicClient.readContract({
            ...pool,
            functionName: "getLoanTerms",
            args: [BigInt(intent.loanId ?? "0")],
          })) as any;
          facts.loanStatus = Number(terms[0]);
        } else if (intent.disburseTxHash) {
          facts.disburseReceipt = await publicClient
            .getTransactionReceipt({ hash: intent.disburseTxHash })
            .then(r => ({ status: r.status }))
            .catch(() => null);
        }
      } catch (e) {
        if (cancelled) return;
        setReconcileNote(`Could not read the chain (${getParsedError(e)}); retrying.`);
        timer = setTimeout(run, 4000);
        return;
      }
      if (cancelled) return;
      const outcome = reconcileIntent(intent, facts, Date.now());
      setMayDismiss(outcome.kind === "may_dismiss");
      setOfferedLoanId(outcome.kind === "offer_disburse" ? outcome.loanId : undefined);
      if (outcome.kind === "adopt") {
        setIntent({ ...intent, stage: "requested", loanId: outcome.loanId.toString() });
        return;
      }
      if (outcome.kind === "clear") {
        setIntent(null);
        void refreshAfterMutationRef.current();
        return;
      }
      setReconcileNote(outcome.kind === "offer_disburse" ? "" : outcome.reason + ".");
      timer = setTimeout(run, outcome.kind === "offer_disburse" ? 8000 : 4000);
    };
    void run();
    return () => {
      cancelled = true;
      if (timer) clearTimeout(timer);
    };
  }, [intent, publicClient, connectedAddress, setIntent]);

  // The second origination transaction, bound to the loan id the first one created.
  const disburseIntent = async (current: OriginationIntent, signer: Signer) => {
    if (!publicClient) throw new Error("Contract not available");
    const loanId = BigInt(current.loanId ?? "0");
    assertSameSigner(signer);
    await publicClient.simulateContract({
      address: MICROCREDIT_ADDRESS,
      abi: MICROCREDIT_ABI,
      functionName: "disburseLoan",
      args: [loanId],
      account: signer.address,
    });
    // A rejected signature leaves the intent at "requested": the card keeps offering this loan id.
    const hash = await wagmiWriteAsync({
      address: MICROCREDIT_ADDRESS,
      abi: MICROCREDIT_ABI,
      functionName: "disburseLoan",
      args: [loanId],
      chainId: CHAIN_ID,
    });
    setIntent({ ...current, stage: "disbursing", disburseTxHash: hash });
    const toastId = toast.loading("Waiting for the disbursement to be mined", { position: "top-center" });
    try {
      const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 180_000 });
      if (receipt.status !== "success") {
        setIntent({ ...current, stage: "requested" });
        throw new Error("The disbursement reverted; the loan is still requested");
      }
    } finally {
      toast.dismiss(toastId);
    }
    setIntent(null);
    toast.success("Loan disbursed", { position: "top-center" });
    await refreshAfterMutation();
  };

  const handleOneClickBorrow = async () => {
    if (!loanAmount || !connectedAddress) return;
    
    setIsLoading(true);
    try {
      const principal = parseLoanAmount(loanAmount);
      if (!principal) return;
      if (!publicClient) throw new Error("Contract not available");
      if (!RELAYER_ENABLED) {
        // Wallet-direct: requestLoan, then disburseLoan, as two transactions with the pool's default term. The
        // intent is persisted before the wallet is asked and bound to the transaction hash before the receipt is
        // awaited; the loan id comes from this transaction's LoanRequested event, never from the id array's length.
        if (decision.kind !== "allow_new_request") {
          throw new Error("A loan request is still open or unresolved; finish or resolve it first");
        }
        const signer = captureSigner("The loan request");
        const idsBefore = (await publicClient.readContract({
          address: MICROCREDIT_ADDRESS,
          abi: MICROCREDIT_ABI,
          functionName: "getBorrowerLoanIds",
          args: [signer.address],
        })) as readonly bigint[];
        // A simulation failure throws before any intent exists: nothing was broadcast.
        await publicClient.simulateContract({
          address: MICROCREDIT_ADDRESS,
          abi: MICROCREDIT_ABI,
          functionName: "requestLoan",
          args: [principal],
          account: signer.address,
        });
        const pending = newIntent({
          chainId: CHAIN_ID,
          pool: MICROCREDIT_ADDRESS,
          borrower: signer.address,
          amount: principal,
          idsBefore,
          now: Date.now(),
        });
        setIntent(pending);
        let requestHash: `0x${string}`;
        try {
          requestHash = await wagmiWriteAsync({
            address: MICROCREDIT_ADDRESS,
            abi: MICROCREDIT_ABI,
            functionName: "requestLoan",
            args: [principal],
            chainId: CHAIN_ID,
          });
        } catch (e) {
          // Only a rejection in the wallet means nothing left it; any other failure keeps the intent for reconciliation.
          if (isUserRejection(e)) setIntent(null);
          throw e;
        }
        const withHash: OriginationIntent = { ...pending, requestTxHash: requestHash };
        setIntent(withHash);
        const toastId = toast.loading("Waiting for the loan request to be mined", { position: "top-center" });
        let receipt;
        try {
          receipt = await publicClient.waitForTransactionReceipt({ hash: requestHash, timeout: 180_000 });
        } finally {
          toast.dismiss(toastId);
        }
        if (receipt.status !== "success") {
          setIntent(null);
          throw new Error("The loan request reverted; nothing was reserved");
        }
        const loanId = matchRequestedLoan(receipt.logs, {
          pool: MICROCREDIT_ADDRESS,
          borrower: signer.address,
          amount: principal,
        });
        const requested: OriginationIntent = { ...withHash, stage: "requested", loanId: loanId.toString() };
        setIntent(requested);
        await disburseIntent(requested, signer);
        setLoanAmount("");
        return;
      }
      // === One-Click Borrow (BorrowAndDisburse) ===
      const nonce = (await publicClient.readContract({
        address: MICROCREDIT_ADDRESS,
        abi: MICROCREDIT_ABI,
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
          contractAddress: MICROCREDIT_ADDRESS,
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
      if (!resp.ok) throw new Error(await relayerErrorMessage(resp));
      const resJson = await resp.json();
      console.log("One-click borrow completed:", { txHash: resJson.txHash, status: resJson.status, loanId: resJson.loanId });

      // Refresh frontend state deterministically
      await refreshAfterMutation();
      setLoanAmount("");
    } catch (error) {
      console.error("Error in one-click borrow:", error);
      toast.error(`Borrowing failed: ${getParsedError(error)}`);
      await refreshAfterMutation();
    } finally {
      setIsLoading(false);
    }
  };

  // Second step for a requested loan, by its own id: the intent's loan, or one found on chain without an intent.
  const handleDisburseRequested = async (loanId: bigint) => {
    setIsLoading(true);
    try {
      const signer = captureSigner("The disbursement");
      const current: OriginationIntent =
        intent && intent.loanId === loanId.toString()
          ? intent
          : {
              ...newIntent({
                chainId: CHAIN_ID,
                pool: MICROCREDIT_ADDRESS,
                borrower: signer.address,
                amount: activePrincipal ?? 0n,
                idsBefore: [],
                now: Date.now(),
              }),
              stage: "requested",
              loanId: loanId.toString(),
            };
      await disburseIntent(current, signer);
    } catch (error) {
      toast.error(`Disbursement failed: ${getParsedError(error)}`);
    } finally {
      setIsLoading(false);
    }
  };

  const handleCancelRequested = async (loanId: bigint) => {
    setIsLoading(true);
    try {
      requireHash(await writeCreditAsync({ functionName: "cancelLoan", args: [loanId] }), "The cancellation");
      if (intent && intent.loanId === loanId.toString()) setIntent(null);
      await refreshAfterMutation();
    } catch (error) {
      toast.error(`Cancellation failed: ${getParsedError(error)}`);
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

  const hasCredit = borrowLimit !== undefined && borrowLimit[0] > 0n;

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

  const backingUrl = connectedAddress ? `${window.location.origin}${BASE_PATH}/attest?borrower=${connectedAddress}` : "";

  const [copied, setCopied] = useState(false);
  const copyBackingUrl = () => {
    navigator.clipboard.writeText(backingUrl);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  return (
  <div className="flex items-center flex-col grow pt-10">
    <div className="px-5 w-full max-w-4xl">
      <div className="flex items-center justify-center mb-8">
        <CreditCardIcon className="h-8 w-8 mr-3" />
        <h1 className="text-3xl font-bold">{hasCredit ? "Request Loan" : "Build Credit"}</h1>
      </div>
      <div className="flex justify-center mb-4">
        <TestnetMint onMinted={refreshAfterMutation} />
      </div>

      {/* ── Credit Stats (always visible) ─────────────────────────── */}
      <div className="grid grid-cols-3 gap-4 mb-6">
        <div className="bg-base-100 rounded-lg p-4 shadow text-center">
          <div className="text-xs text-gray-500 mb-1">Credit Limit</div>
          <div className="text-2xl font-bold">{borrowLimit !== undefined ? formatUSDC(borrowLimit[0]) : "—"}</div>
          <div className="text-xs text-gray-400">your credit + backing</div>
          {duesPaid !== undefined && duesPaid > 0n && borrowLimit !== undefined && borrowLimit[0] > 0n && (
            <div className="text-xs text-gray-500 mt-1">includes {formatUSDC(duesPaid)} earned from interest you paid into the reserve</div>
          )}
        </div>
        <div className="bg-base-100 rounded-lg p-4 shadow text-center">
          <div className="text-xs text-gray-500 mb-1">Max Loan</div>
          <div className="text-2xl font-bold">
            {maxEligibleAmount !== undefined ? formatUSDC(maxEligibleAmount) : "—"}
          </div>
          <div className="text-xs text-gray-400">available now</div>
        </div>
        <div className="bg-base-100 rounded-lg p-4 shadow text-center">
          <div className="text-xs text-gray-500 mb-1">APR</div>
          <div className="text-2xl font-bold">
            {borrowerAprPercent ? `${borrowerAprPercent}%` : "—"}
          </div>
          <div className="text-xs text-gray-400">fixed rate</div>
        </div>
      </div>

      {/* ── Backing CTA (shown when there is no credit yet, no active loan) ── */}
      {!loanIsActive && !hasCredit && (
        <div className="bg-base-100 rounded-lg p-5 shadow-lg mb-6 border border-base-300">
          <div className="flex items-start gap-4">
            <div className="flex-shrink-0 pt-0.5">
              <div
                onClick={copyBackingUrl}
                className="cursor-pointer flex flex-col items-center"
                title="Click to copy link"
              >
                <QRCodeDisplay value={backingUrl} size={72} />
                <span className="text-xs text-gray-400 mt-1">scan or copy</span>
              </div>
            </div>
            <div className="flex-1 min-w-0">
              <p className="font-semibold mb-1">Share your backing link to get credit</p>
              <p className="text-sm text-gray-500 mb-3">
                You can borrow against credit you already have, or credit that someone who has credit backs you
                with from their own. Send this link to people who know you: what they back you with becomes your
                limit, and they stand behind it if you do not repay.
              </p>
              <div className="flex items-center gap-2">
                <span
                  className="text-xs text-blue-600 underline truncate cursor-pointer"
                  title={backingUrl}
                  onClick={copyBackingUrl}
                >
                  {backingUrl}
                </span>
                <button
                  onClick={copyBackingUrl}
                  className="btn btn-xs btn-outline flex-shrink-0 gap-1"
                >
                  <DocumentDuplicateIcon className="h-3 w-3" />
                  {copied ? "Copied!" : "Copy"}
                </button>
              </div>
            </div>
          </div>
        </div>
      )}

      {lendingPaused && <div className="alert alert-warning mb-6">New lending is paused. You can still repay.</div>}

      {/* An origination intent whose outcome is not settled: reconciliation, never a new request */}
      {decision.kind === "reconcile" && (
        <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8 border border-warning">
          <h2 className="text-xl font-semibold mb-2">
            {offeredLoanId !== undefined ? "Loan requested, not yet disbursed" : "Checking a loan request"}
          </h2>
          <p className="text-sm text-gray-600 mb-4">
            {offeredLoanId !== undefined
              ? `${formatUSDC(BigInt(decision.intent.amount))} is reserved for you as loan #${offeredLoanId.toString()} but has not been paid out. Disburse it to receive the funds, or cancel it to release the reservation. Nothing else can be requested until one of the two is done.`
              : `A request for ${formatUSDC(BigInt(decision.intent.amount))} started at ${new Date(decision.intent.createdAt).toLocaleString()} is not settled yet${decision.intent.requestTxHash ? ` (transaction ${decision.intent.requestTxHash})` : " (the wallet returned no transaction hash)"}. ${reconcileNote} No new request is possible until it is.`}
          </p>
          <div className="flex gap-2 flex-wrap">
            {offeredLoanId !== undefined && (
              <>
                <button className="btn btn-primary" disabled={isLoading} onClick={() => handleDisburseRequested(offeredLoanId)}>
                  {isLoading ? "Processing…" : "Disburse"}
                </button>
                <button className="btn btn-outline" disabled={isLoading} onClick={() => handleCancelRequested(offeredLoanId)}>
                  Cancel request
                </button>
              </>
            )}
            {mayDismiss && (
              <button className="btn btn-outline" disabled={isLoading} onClick={() => setIntent(null)}>
                Dismiss: no matching loan was found
              </button>
            )}
          </div>
        </div>
      )}

      {/* A requested loan on chain (this page, another tab or a direct call) that still needs its second transaction */}
      {decision.kind === "requested_on_chain" && (
        <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8 border border-warning">
          <h2 className="text-xl font-semibold mb-2">Loan requested, not yet disbursed</h2>
          <p className="text-sm text-gray-600 mb-4">
            {activePrincipal !== undefined ? formatUSDC(activePrincipal) : "A loan"} is reserved for you as loan #
            {decision.loanId.toString()} but has not been paid out. Disburse it to receive the funds, or cancel it to
            release the reservation. Nothing else can be requested until one of the two is done.
          </p>
          <div className="flex gap-2">
            <button className="btn btn-primary" disabled={isLoading} onClick={() => handleDisburseRequested(decision.loanId)}>
              {isLoading ? "Processing…" : "Disburse"}
            </button>
            <button className="btn btn-outline" disabled={isLoading} onClick={() => handleCancelRequested(decision.loanId)}>
              Cancel request
            </button>
          </div>
        </div>
      )}

      {decision.kind === "loading" && connectedAddress && (
        <div className="text-sm text-gray-500 mb-8">Loading your loans…</div>
      )}

      {/* Loan Request Form (shown when credit exists, the reads are loaded and nothing is open or unresolved) */}
      {decision.kind === "allow_new_request" && hasCredit && (
        <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
          <h2 className="text-xl font-semibold mb-4 flex items-center">
            <CalculatorIcon className="h-5 w-5 mr-2" />
            Loan Request
          </h2>

          <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
            {/* Amount */}
            <div className="bg-base-200 rounded-lg p-4">
              <label className="block text-sm font-medium mb-2">Amount (USDC)</label>
              <input
                type="number"
                value={loanAmount}
                onChange={e => setLoanAmount(e.target.value)}
                placeholder="0.00"
                step="0.01"
                min="0.01"
                className="input input-bordered w-full"
              />
              {isAmountTooHigh() && (
                <div className="text-xs text-error mt-2">
                  Amount exceeds your current eligibility ({formatUSDC(maxEligibleAmount)} max)
                </div>
              )}
            </div>

            {/* Repayment Period */}
            <div className="bg-base-200 rounded-lg p-4">
              <label className="block text-sm font-medium mb-2">Repayment Period</label>
              {RELAYER_ENABLED ? (
                <select
                  className="select select-bordered w-full"
                  value={repaymentPeriod}
                  onChange={e => setRepaymentPeriod(parseInt(e.target.value))}
                >
                  {[7, 14, 28, 56, 84, 182, 364].map(days => (
                    <option key={days} value={days}>{getPeriodLabel(days)}</option>
                  ))}
                </select>
              ) : (
                <>
                  <div className="input input-bordered w-full flex items-center bg-base-100">
                    {Math.round(effectivePeriodDays)} days (the pool&apos;s default term)
                  </div>
                  <p className="text-xs text-gray-500 mt-2">
                    With your own wallet the loan runs for the pool&apos;s default term; chosen periods need the relayed
                    version of this app. The estimate below is for that term.
                  </p>
                </>
              )}
            </div>
          </div>

          {/* Est. weekly payment preview */}
          {previewTermsData && loanAmount && (
            <div className="bg-base-200 rounded-lg p-3 mt-4 text-sm">
              <span className="text-gray-600">Est. weekly payment: </span>
              <span className="font-semibold">{(Number(previewTermsData[1]) / 1e6).toFixed(2)} USDC</span>
            </div>
          )}

          {/* Borrow CTA */}
          <div className="mt-6">
            <button
              className="btn btn-primary w-full md:w-auto"
              disabled={
                lendingPaused ||
                isLoading ||
                signingRef.current ||
                !loanAmount ||
                parseLoanAmount(loanAmount) === null ||
                isAmountTooHigh()
              }
              onClick={handleOneClickBorrow}
            >
              {isLoading ? "Processing…" : RELAYER_ENABLED ? "One-Click Borrow: sign once, get funds" : "Borrow (two wallet transactions)"}
            </button>
          </div>
        </div>
      )}

      {/* Active Loan & Repayment Section */}
      {loanIsActive && !loanIsRequested && (
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

            {/* Repayment Schedule */}
            <div className="bg-base-200 rounded-lg p-4">
              <h3 className="font-medium mb-3">Repayment Schedule</h3>
              <div className="space-y-2 text-sm">
                <div className="flex justify-between">
                  <span className="text-gray-600">Term:</span>
                  <span className="font-medium">{loanTerms ? `${Number(loanTerms[1]) / 86400} days` : "-"}</span>
                </div>
                <div className="flex justify-between">
                  <span className="text-gray-600">Due Date:</span>
                  <span className="font-medium">{dueAt !== undefined ? formatDate(dueAt) : "Not yet disbursed"}</span>
                </div>
                <div className="flex justify-between">
                  <span className="text-gray-600">Status:</span>
                  {daysOverdue > 0 ? (
                    <span className="font-medium text-error">Overdue by {daysOverdue} days</span>
                  ) : (
                    <span className="font-medium text-green-500">Current</span>
                  )}
                </div>
                {daysOverdue > 0 && defaultableAt !== undefined && (
                  <p className="text-xs text-error">
                    Repay before {formatDate(defaultableAt)}. After that the loan can be marked defaulted, your
                    backers pay for it, and you cannot borrow again.
                  </p>
                )}
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
                      if (!publicClient) throw new Error("Missing contracts");
                      // Read canonical outstanding rounded to cent (contract view)
                      const out = (await publicClient.readContract({
                        address: LENS_ADDRESS,
                        abi: LENS_ABI,
                        functionName: "getOutstandingRoundedToCent",
                        args: [activeLoanId as bigint],
                      })) as bigint;
                      const amountToRepay = out;

                      // Check USDC balance first
                      await checkUSDCBalance(amountToRepay);

                      if (!RELAYER_ENABLED) {
                        // Wallet-direct: approve the pool for the amount, then repay; two transactions, each required
                        // to have been sent and mined before the next step, by the same account on the same chain.
                        const signer = captureSigner("The repayment");
                        await writeUsdc("approve", [MICROCREDIT_ADDRESS, amountToRepay]);
                        assertSameSigner(signer);
                        requireHash(
                          await writeCreditAsync({ functionName: "repayLoan", args: [activeLoanId as bigint, amountToRepay] }),
                          "The repayment",
                        );
                        await refreshAfterMutation();
                        return;
                      }

                      if (!publicClient || !USDC_ADDRESS || !USDC_ABI || !usdcPermitDomain) throw new Error("Missing contracts");

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
                          spender: MICROCREDIT_ADDRESS,
                          value: amountToRepay,
                          nonce: usdcNonce,
                          deadline: permitDeadline,
                        } as const;
                        console.count("permit:sign");
                        signingRef.current = true;
                        const permitSig = await signTypedDataAsync({
                          domain: usdcPermitDomain,
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
                          contractAddress: MICROCREDIT_ADDRESS,
                          borrower: connectedAddress,
                          loanId: (activeLoanId as bigint).toString(),
                          amount: "0",
                          permit: permitPayload,
                        }),
                      });
                      if (!resp.ok) throw new Error(await relayerErrorMessage(resp));
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

                        if (!RELAYER_ENABLED) {
                          // Wallet-direct: approve the pool for the amount, then repay; two transactions, each required
                          // to have been sent and mined before the next step, by the same account on the same chain.
                          const signer = captureSigner("The repayment");
                          await writeUsdc("approve", [MICROCREDIT_ADDRESS, repayAmountBigInt]);
                          assertSameSigner(signer);
                          requireHash(
                            await writeCreditAsync({ functionName: "repayLoan", args: [activeLoanId as bigint, repayAmountBigInt] }),
                            "The repayment",
                          );
                          setRepayAmount("");
                          await refreshAfterMutation();
                          return;
                        }

                        if (!publicClient || !USDC_ADDRESS || !USDC_ABI || !usdcPermitDomain) throw new Error("Missing contracts");

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
                            spender: MICROCREDIT_ADDRESS,
                            value: repayAmountBigInt,
                            nonce: usdcNonce,
                            deadline: permitDeadline,
                          } as const;
                          console.count("permit:sign");
                          signingRef.current = true;
                          const permitSig = await signTypedDataAsync({
                            domain: usdcPermitDomain,
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
                            contractAddress: MICROCREDIT_ADDRESS,
                            borrower: connectedAddress,
                            loanId: (activeLoanId as bigint).toString(),
                            amount: repayAmountBigInt.toString(),
                            permit: permitPayload,
                          }),
                        });
                        if (!resp.ok) throw new Error(await relayerErrorMessage(resp));
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
      )}
    </div>
  </div>
);

};

export default BorrowPage;