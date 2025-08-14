"use client";

import type { NextPage } from "next";
import { useEffect, useState } from "react";
import { useAccount, useSignTypedData } from "wagmi";
import { useScaffoldReadContract } from "~~/hooks/scaffold-eth";
import { formatUSDC, getCreditScoreColor } from "~~/utils/format";
import { CreditCardIcon, CalculatorIcon, InformationCircleIcon, DocumentDuplicateIcon, CurrencyDollarIcon } from "@heroicons/react/24/outline";
import Link from "next/link";
import QRCodeDisplay from "~~/components/QRCodeDisplay";
import { useDisplayName } from "~~/components/scaffold-eth/DisplayNameContext";
import { createPublicClient, http } from "viem";
import { localhost } from "viem/chains";
import deployedContracts from "~~/contracts/deployedContracts";

// Borrow wizard content extracted from /app/borrow/page.tsx
const BorrowContent: NextPage = () => {
  const { address: connectedAddress } = useAccount();
  const [loanAmount, setLoanAmount] = useState("");
  const [repaymentPeriod, setRepaymentPeriod] = useState(7);
  const [isLoading, setIsLoading] = useState(false);
  const [lastLoanId, setLastLoanId] = useState<string | null>(null);
  const { signTypedDataAsync } = useSignTypedData();

  // Chain/config (mirror repay page; update as needed for Base)
  const CHAIN_ID = 31337;
  const RPC_URL = "http://localhost:8545";
  const publicClient = createPublicClient({
    chain: { ...localhost, id: CHAIN_ID },
    transport: http(RPC_URL),
  });
  const MICRO = (deployedContracts as any)[CHAIN_ID]?.DecentralizedMicrocredit;
  const MICRO_ADDRESS = MICRO?.address as `0x${string}` | undefined;
  const MICRO_ABI = MICRO?.abi as any;

  const { data: creditScore } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getCreditScore",
    args: [connectedAddress],
  });

  const { data: poolInfo } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getPoolInfo",
  });

  const { data: loanRateBp } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getLoanRate",
  });

  const { displayName } = useDisplayName();
  const displayNameResolved = displayName ?? connectedAddress;

  // EIP-712 Domains and Types
  const MICRO_DOMAIN = {
    name: "DecentralizedMicrocredit",
    version: "1",
    chainId: CHAIN_ID,
    verifyingContract: MICRO_ADDRESS,
  } as const;

  const LOAN_REQUEST_TYPES = {
    LoanRequest: [
      { name: "borrower", type: "address" },
      { name: "amount", type: "uint256" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" },
    ],
  } as const;

  const DISBURSE_REQUEST_TYPES = {
    DisburseRequest: [
      { name: "borrower", type: "address" },
      { name: "loanId", type: "uint256" },
      { name: "to", type: "address" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" },
    ],
  } as const;

  const nowPlus = (sec: number) => BigInt(Math.floor(Date.now() / 1000) + sec);

  const requestAndMaybeDisburse = async () => {
    try {
      if (!connectedAddress || !MICRO_ADDRESS || !MICRO_ABI) throw new Error("Contracts not ready");
      setIsLoading(true);

      // 1) Sign LoanRequest
      const nonce1 = (await publicClient.readContract({ address: MICRO_ADDRESS, abi: MICRO_ABI, functionName: "nonces", args: [connectedAddress] })) as bigint;
      const deadline1 = nowPlus(3600);
      const reqMsg = { borrower: connectedAddress as `0x${string}`, amount: BigInt(Math.floor(parseFloat(loanAmount || "0") * 1e6)), nonce: nonce1, deadline: deadline1 } as const;

      const loanSig = await signTypedDataAsync({ domain: MICRO_DOMAIN as any, types: LOAN_REQUEST_TYPES as any, primaryType: "LoanRequest", message: reqMsg as any });

      // 2) Relay request-loan
      const reqRes = await fetch("/api/meta/request-loan", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ chainId: CHAIN_ID, contractAddress: MICRO_ADDRESS, req: { ...reqMsg, amount: reqMsg.amount.toString(), nonce: reqMsg.nonce.toString(), deadline: reqMsg.deadline.toString() }, signature: loanSig }),
      });
      const reqJson = await reqRes.json();
      if (!reqRes.ok) throw new Error(reqJson.error || "request-loan failed");

      const loanIdStr: string | null = reqJson.loanId ?? null;
      setLastLoanId(loanIdStr);

      // If we got a loanId, automatically disburse to borrower for smoother UX
      if (loanIdStr) {
        const loanId = BigInt(loanIdStr);
        const nonce2 = (await publicClient.readContract({ address: MICRO_ADDRESS, abi: MICRO_ABI, functionName: "nonces", args: [connectedAddress] })) as bigint;
        const deadline2 = nowPlus(3600);
        const disMsg = { borrower: connectedAddress as `0x${string}`, loanId, to: connectedAddress as `0x${string}`, nonce: nonce2, deadline: deadline2 } as const;
        const disSig = await signTypedDataAsync({ domain: MICRO_DOMAIN as any, types: DISBURSE_REQUEST_TYPES as any, primaryType: "DisburseRequest", message: disMsg as any });

        const disRes = await fetch("/api/meta/disburse-loan", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ chainId: CHAIN_ID, contractAddress: MICRO_ADDRESS, req: { ...disMsg, loanId: disMsg.loanId.toString(), nonce: disMsg.nonce.toString(), deadline: disMsg.deadline.toString() }, signature: disSig }),
        });
        const disJson = await disRes.json();
        if (!disRes.ok) throw new Error(disJson.error || "disburse-loan failed");
      }
    } catch (e) {
      console.error("[BorrowContent] meta borrow error:", e);
      alert((e as any)?.message || String(e));
    } finally {
      setIsLoading(false);
    }
  };

  const aprPercent = loanRateBp ? (Number(loanRateBp) / 100).toFixed(2) : undefined;

  return (
    <div className="flex items-center flex-col grow pt-10">
      <div className="px-5 w-full max-w-6xl">
        <div className="flex items-center justify-center mb-8">
          <CreditCardIcon className="h-8 w-8 mr-3" />
          <h1 className="text-3xl font-bold">Borrower Dashboard</h1>
        </div>

        {/* Stats */}
        <div className="grid grid-cols-1 md:grid-cols-3 gap-6 mb-8">
          <div className="bg-base-100 rounded-lg p-6 shadow-lg">
            <h3 className="font-semibold mb-2">Your Credit Score</h3>
            {(() => {
              const scoreNum = creditScore ? Number(creditScore) / 10000 : 0;
              return (
                <div className={`text-3xl font-bold ${getCreditScoreColor(scoreNum)}`}>
                  {creditScore ? `${scoreNum}%` : "—"}
                </div>
              );
            })()}
            <p className="text-sm text-gray-500 mt-1">Higher scores unlock better terms.</p>
          </div>
          <div className="bg-base-100 rounded-lg p-6 shadow-lg">
            <h3 className="font-semibold mb-2">Current APR</h3>
            <div className="text-3xl font-bold text-blue-600">{aprPercent ?? "—"}%</div>
            <p className="text-sm text-gray-500 mt-1">Annual percentage rate for new loans.</p>
          </div>
          <div className="bg-base-100 rounded-lg p-6 shadow-lg">
            <h3 className="font-semibold mb-2">Pool Liquidity</h3>
            <div className="text-3xl font-bold text-green-600">
              {poolInfo ? formatUSDC((poolInfo as any).poolBalance as bigint) : "—"}
            </div>
            <p className="text-sm text-gray-500 mt-1">Available USDC for disbursements.</p>
          </div>
        </div>

        {/* Borrow Wizard (skeleton UI, meta-tx flow handled elsewhere) */}
        <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-10">
          <div className="flex items-center mb-4">
            <CalculatorIcon className="h-6 w-6 mr-2" />
            <h2 className="text-xl font-semibold">Request a Loan</h2>
          </div>

          <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
            <div>
              <label className="block text-sm text-gray-600 mb-1">Amount (USDC)</label>
              <input
                type="number"
                min="0"
                step="0.01"
                value={loanAmount}
                onChange={e => setLoanAmount(e.target.value)}
                className="w-full p-2 border border-gray-300 rounded-lg"
                placeholder="100.00"
              />
            </div>
            <div>
              <label className="block text-sm text-gray-600 mb-1">Repayment Period (days)</label>
              <input
                type="number"
                min="1"
                step="1"
                value={repaymentPeriod}
                onChange={e => setRepaymentPeriod(parseInt(e.target.value || "0", 10))}
                className="w-full p-2 border border-gray-300 rounded-lg"
                placeholder="7"
              />
            </div>
            <div className="flex items-end">
              <button
                onClick={requestAndMaybeDisburse}
                disabled={isLoading || !loanAmount}
                className="w-full bg-blue-600 hover:bg-blue-700 disabled:bg-gray-400 text-white font-semibold py-2 px-4 rounded-lg"
              >
                {isLoading ? "Submitting..." : "Request (Gasless)"}
              </button>
            </div>
          </div>

          <div className="flex items-start mt-6 text-sm text-gray-600">
            <InformationCircleIcon className="h-5 w-5 mr-2 mt-0.5" />
            <p>
              Requests are gasless. You will sign EIP-712 messages and our relayer will submit them on-chain. No ETH required.
            </p>
          </div>
          {lastLoanId && (
            <div className="mt-4 text-sm text-gray-700">
              Last loan requested: <span className="font-mono">#{lastLoanId}</span>
            </div>
          )}
        </div>

        {/* Helpful Links */}
        <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div className="bg-base-100 rounded-lg p-6 shadow-lg">
            <div className="flex items-center mb-4">
              <DocumentDuplicateIcon className="h-6 w-6 mr-2" />
              <h3 className="text-lg font-semibold">Debug / QR</h3>
            </div>
            <QRCodeDisplay value={`https://app.local/borrower/${displayNameResolved ?? "me"}`} />
          </div>
          <div className="bg-base-100 rounded-lg p-6 shadow-lg">
            <div className="flex items-center mb-4">
              <CurrencyDollarIcon className="h-6 w-6 mr-2" />
              <h3 className="text-lg font-semibold">Repay Loans</h3>
            </div>
            <p className="text-sm text-gray-600 mb-3">Already have a loan? Repay it here.</p>
            <Link href="/borrower#repay" className="inline-flex items-center px-4 py-2 bg-red-500 hover:bg-red-600 text-white rounded-lg">
              Open Repayment
            </Link>
          </div>
        </div>
      </div>
    </div>
  );
};

export default BorrowContent;
