"use client";

import { useState, useMemo, useEffect } from "react";
import type { NextPage } from "next";
import { useAccount, useBlockNumber, useReadContracts, useWriteContract } from "wagmi";
import { CogIcon, ShieldCheckIcon } from "@heroicons/react/24/outline";
import { Address, AddressInput } from "~~/components/scaffold-eth";
import { useScaffoldReadContract, useScaffoldWriteContract, useTransactor } from "~~/hooks/scaffold-eth";
import { formatPercent, formatUSDC } from "~~/utils/format";
import { createPublicClient, formatUnits, http, isAddress, parseUnits, zeroAddress } from "viem";
import { localhost } from "viem/chains";
import Link from "next/link";
import { useIsAdmin } from "~~/hooks/useIsAdmin";
import { useUsdcWrite } from "~~/hooks/useUsdc";
import {
  ANVIL_RPC_URL,
  CHAIN_ID,
  MICROCREDIT_ABI,
  MICROCREDIT_ADDRESS,
  SCORE_PROVIDER_ABI,
  USDC_ADDRESS,
} from "~~/utils/microcredit";

const publicClient = createPublicClient({
  chain: { ...localhost, id: CHAIN_ID },
  transport: http(ANVIL_RPC_URL),
});

/** Parses a decimal string into fixed-point units with `decimals` places; null when invalid. */
const parseFixed = (value: string, decimals: number): bigint | null => {
  const trimmed = value.trim();
  if (!new RegExp(`^\\d+(\\.\\d{1,${decimals}})?$`).test(trimmed)) return null;
  return parseUnits(trimmed, decimals);
};

/** Basis points as a percentage, e.g. 1000n -> "10.00%". */
const bpsToPercent = (bps?: bigint) => (bps !== undefined ? formatPercent(Number(bps) / 100) : "-");

/*
 * Writes below go through scaffold's transactor, which shows the revert reason with getParsedError
 * (plain-language text from utils/contractErrors.ts for DecentralizedMicrocredit errors), so the
 * handlers only reset their own state.
 */

/**
 * Emergency pause: stops new loans and disbursements, while repayments, defaults and withdrawals go
 * on. The guardian or the owner can pause; only the owner can unpause or change the guardian.
 */
const EmergencyPausePanel = ({ isOwner }: { isOwner: boolean }) => {
  const { address: connectedAddress } = useAccount();
  const [guardianInput, setGuardianInput] = useState("");
  const [busy, setBusy] = useState<"pause" | "unpause" | "guardian" | null>(null);

  const { data: paused } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "paused",
  });
  const { data: guardian } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "guardian",
  });
  const { writeContractAsync } = useScaffoldWriteContract({ contractName: "DecentralizedMicrocredit" });

  const hasGuardian = !!guardian && guardian !== zeroAddress;
  const isGuardian = hasGuardian && !!connectedAddress && connectedAddress.toLowerCase() === guardian.toLowerCase();
  const newGuardian = isAddress(guardianInput) ? guardianInput : null;

  const pause = async () => {
    setBusy("pause");
    try {
      await writeContractAsync({ functionName: "pause" });
    } catch (error) {
      console.error("pause failed:", error);
    } finally {
      setBusy(null);
    }
  };

  const unpause = async () => {
    setBusy("unpause");
    try {
      await writeContractAsync({ functionName: "unpause" });
    } catch (error) {
      console.error("unpause failed:", error);
    } finally {
      setBusy(null);
    }
  };

  const saveGuardian = async () => {
    if (!newGuardian) return;
    setBusy("guardian");
    try {
      await writeContractAsync({ functionName: "setGuardian", args: [newGuardian] });
      setGuardianInput("");
    } catch (error) {
      console.error("setGuardian failed:", error);
    } finally {
      setBusy(null);
    }
  };

  return (
    <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
      <h2 className="text-xl font-semibold mb-1">Emergency Pause</h2>
      <p className="text-sm text-gray-600 mb-4">
        Pausing stops new loans and disbursements. Repayments, defaults and withdrawals still work.
      </p>
      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        <div className={`p-4 rounded-lg ${paused ? "bg-red-50" : "bg-green-50"}`}>
          <h3 className={`font-medium mb-2 ${paused ? "text-red-800" : "text-green-800"}`}>New Lending</h3>
          <div className={`text-2xl font-bold ${paused ? "text-red-600" : "text-green-600"}`}>
            {paused === undefined ? "-" : paused ? "Paused" : "Open"}
          </div>
          <p className={`text-sm mt-1 ${paused ? "text-red-600" : "text-green-600"}`}>
            {paused ? "Only the owner can unpause." : "The guardian or the owner can pause at once."}
          </p>
        </div>
        <div className="bg-blue-50 p-4 rounded-lg">
          <h3 className="font-medium text-blue-800 mb-2">Guardian</h3>
          {hasGuardian ? (
            <Address address={guardian} />
          ) : (
            <div className="text-2xl font-bold text-blue-600">{guardian === undefined ? "-" : "None"}</div>
          )}
          <p className="text-sm text-blue-600 mt-1">Can pause, but cannot unpause.</p>
        </div>
      </div>
      {(isOwner || isGuardian) && (
        <div className="flex flex-wrap gap-2 mt-6">
          <button className="btn btn-error" disabled={paused !== false || busy !== null} onClick={pause}>
            {busy === "pause" ? "Pausing..." : "Pause new lending"}
          </button>
          {isOwner && (
            <button className="btn btn-primary" disabled={paused !== true || busy !== null} onClick={unpause}>
              {busy === "unpause" ? "Unpausing..." : "Unpause"}
            </button>
          )}
        </div>
      )}
      {isOwner ? (
        <div className="mt-6 max-w-md">
          <label className="block text-sm font-medium mb-2">New guardian</label>
          <div className="flex gap-2">
            <div className="flex-1 min-w-0">
              <AddressInput value={guardianInput} onChange={setGuardianInput} placeholder="0x..." />
            </div>
            <button className="btn btn-primary" disabled={!newGuardian || busy !== null} onClick={saveGuardian}>
              {busy === "guardian" ? "Saving..." : "Set guardian"}
            </button>
          </div>
          <p className="text-xs text-gray-500 mt-1">Set the zero address to remove the guardian.</p>
        </div>
      ) : (
        !isGuardian && (
          <p className="text-sm text-gray-500 mt-4">Only the guardian or the owner can pause. Only the owner can unpause.</p>
        )
      )}
    </div>
  );
};

/**
 * First-loss reserve: a share of repaid interest, plus capital anyone adds, that pays uncovered
 * default losses before lenders.
 */
const FirstLossReservePanel = ({ isOwner }: { isOwner: boolean }) => {
  const [shareInput, setShareInput] = useState("");
  const [releaseInput, setReleaseInput] = useState("");
  const [fundInput, setFundInput] = useState("");
  const [busy, setBusy] = useState<"share" | "release" | "fund" | null>(null);

  const { data: reserveBps } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "reserveBps",
  });
  const { data: maxReserveBps } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "MAX_RESERVE_BPS",
  });
  const { data: reserve } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "firstLossReserve",
  });
  const { writeContractAsync } = useScaffoldWriteContract({ contractName: "DecentralizedMicrocredit" });
  const writeUsdc = useUsdcWrite();

  const newBps = parseFixed(shareInput, 2); // a percentage with two decimals is a number of basis points
  const shareTooHigh = newBps !== null && maxReserveBps !== undefined && newBps > maxReserveBps;
  const releaseAmount = parseFixed(releaseInput, 6);
  const releaseTooHigh = releaseAmount !== null && reserve !== undefined && releaseAmount > reserve;
  const fundAmount = parseFixed(fundInput, 6);

  const setShare = async () => {
    if (newBps === null) return;
    setBusy("share");
    try {
      await writeContractAsync({ functionName: "setReserveBps", args: [newBps] });
      setShareInput("");
    } catch (error) {
      console.error("setReserveBps failed:", error);
    } finally {
      setBusy(null);
    }
  };

  const release = async () => {
    if (!releaseAmount) return;
    setBusy("release");
    try {
      await writeContractAsync({ functionName: "releaseReserve", args: [releaseAmount] });
      setReleaseInput("");
    } catch (error) {
      console.error("releaseReserve failed:", error);
    } finally {
      setBusy(null);
    }
  };

  // Anyone can add first-loss capital: approve the USDC, then move it into the reserve.
  const fund = async () => {
    if (!fundAmount) return;
    setBusy("fund");
    try {
      await writeUsdc("approve", [MICROCREDIT_ADDRESS, fundAmount]);
      await writeContractAsync({ functionName: "fundReserve", args: [fundAmount] });
      setFundInput("");
    } catch (error) {
      console.error("fundReserve failed:", error);
    } finally {
      setBusy(null);
    }
  };

  return (
    <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
      <h2 className="text-xl font-semibold mb-4">First-Loss Reserve</h2>
      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        <div className="bg-blue-50 p-4 rounded-lg">
          <h3 className="font-medium text-blue-800 mb-2">Reserve Share</h3>
          <div className="text-2xl font-bold text-blue-600">{bpsToPercent(reserveBps)}</div>
          <p className="text-sm text-blue-600 mt-1">Of every interest payment (max {bpsToPercent(maxReserveBps)})</p>
        </div>
        <div className="bg-green-50 p-4 rounded-lg">
          <h3 className="font-medium text-green-800 mb-2">Reserve Balance</h3>
          <div className="text-2xl font-bold text-green-600">{reserve !== undefined ? formatUSDC(reserve) : "-"}</div>
          <p className="text-sm text-green-600 mt-1">
            Pays default losses that slashed stake does not cover, before they reach lenders
          </p>
        </div>
      </div>
      <div className="mt-6">
        <label htmlFor="fundReserve" className="block text-sm font-medium mb-2">
          Add first-loss capital (USDC)
        </label>
        <div className="flex gap-2 max-w-md">
          <input
            id="fundReserve"
            type="text"
            inputMode="decimal"
            placeholder="0.00"
            value={fundInput}
            onChange={e => setFundInput(e.target.value)}
            className="input input-bordered flex-1 min-w-0"
          />
          <button className="btn btn-primary" disabled={!fundAmount || busy !== null} onClick={fund}>
            {busy === "fund" ? "Adding..." : "Add to reserve"}
          </button>
        </div>
        <p className="text-xs text-gray-500 mt-1">
          Anyone can add. It is not a deposit: it earns nothing and cannot be withdrawn. Two transactions: approve
          USDC, then add.
        </p>
      </div>
      {isOwner ? (
        <div className="grid grid-cols-1 md:grid-cols-2 gap-6 mt-6">
          <div>
            <label htmlFor="reserveShare" className="block text-sm font-medium mb-2">
              New reserve share (%)
            </label>
            <div className="flex gap-2">
              <input
                id="reserveShare"
                type="text"
                inputMode="decimal"
                placeholder={reserveBps !== undefined ? (Number(reserveBps) / 100).toString() : "0"}
                value={shareInput}
                onChange={e => setShareInput(e.target.value)}
                className="input input-bordered flex-1 min-w-0"
              />
              <button
                className="btn btn-primary"
                disabled={newBps === null || shareTooHigh || busy !== null}
                onClick={setShare}
              >
                {busy === "share" ? "Saving..." : "Set share"}
              </button>
            </div>
            {shareTooHigh && <p className="text-xs text-red-500 mt-1">The maximum is {bpsToPercent(maxReserveBps)}.</p>}
          </div>
          <div>
            <label htmlFor="releaseAmount" className="block text-sm font-medium mb-2">
              Release to lenders (USDC)
            </label>
            <div className="flex gap-2">
              <input
                id="releaseAmount"
                type="text"
                inputMode="decimal"
                placeholder="0.00"
                value={releaseInput}
                onChange={e => setReleaseInput(e.target.value)}
                className="input input-bordered flex-1 min-w-0"
              />
              <button
                type="button"
                className="btn btn-outline"
                disabled={!reserve}
                onClick={() => reserve !== undefined && setReleaseInput(formatUnits(reserve, 6))}
              >
                Max
              </button>
              <button
                className="btn btn-primary"
                disabled={!releaseAmount || releaseTooHigh || busy !== null}
                onClick={release}
              >
                {busy === "release" ? "Releasing..." : "Release"}
              </button>
            </div>
            {releaseTooHigh ? (
              <p className="text-xs text-red-500 mt-1">That is more than the reserve holds.</p>
            ) : (
              <p className="text-xs text-gray-500 mt-1">Moves USDC from the reserve into the pool, raising the share price.</p>
            )}
          </div>
        </div>
      ) : (
        <p className="text-sm text-gray-500 mt-4">
          Only the contract owner can change the reserve share or release the reserve.
        </p>
      )}
    </div>
  );
};

/**
 * The credit oracle's issuance budget. OracleScoreProvider counts scores in units of 1e6 = one full
 * line of maxLoanAmount; this panel shows them in USDC at the current max loan. The budget caps
 * totalHeld (budget held per account, the highest line since it was last unused), not totalScore.
 * The provider is whatever DecentralizedMicrocredit.scoreProvider() points at.
 */
const IssuanceBudgetPanel = () => {
  const { address: connectedAddress } = useAccount();
  const [budgetInput, setBudgetInput] = useState("");
  const [perReportInput, setPerReportInput] = useState("");
  const [saving, setSaving] = useState(false);

  const { data: provider } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "scoreProvider",
  });
  const { data: maxLoanAmount } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "maxLoanAmount",
  });
  const hasProvider = !!provider && provider !== zeroAddress;
  const providerContract = { address: provider as `0x${string}`, abi: SCORE_PROVIDER_ABI } as const;
  const { data: limits, refetch } = useReadContracts({
    contracts: [
      { ...providerContract, functionName: "totalScore" },
      { ...providerContract, functionName: "maxTotalScore" },
      { ...providerContract, functionName: "maxIncreasePerReport" },
      { ...providerContract, functionName: "owner" },
      { ...providerContract, functionName: "totalHeld" },
    ],
    query: { enabled: hasProvider },
  });
  // Oracle reports and releaseBudget move these totals, so refresh on every block as the scaffold read hooks do.
  const { data: blockNumber } = useBlockNumber({ watch: true });
  useEffect(() => {
    if (hasProvider) refetch();
  }, [blockNumber, hasProvider, refetch]);

  const totalScore = limits?.[0]?.result;
  const maxTotalScore = limits?.[1]?.result;
  const maxIncreasePerReport = limits?.[2]?.result;
  const providerOwner = limits?.[3]?.result;
  const totalHeld = limits?.[4]?.result;
  const reportsBudget =
    totalScore !== undefined &&
    totalHeld !== undefined &&
    maxTotalScore !== undefined &&
    maxIncreasePerReport !== undefined;
  const isProviderOwner =
    !!connectedAddress && !!providerOwner && connectedAddress.toLowerCase() === providerOwner.toLowerCase();

  const toUsdc = (score: bigint) => (maxLoanAmount !== undefined ? (score * maxLoanAmount) / 1_000_000n : undefined);
  const lines = (score: bigint) => (Number(score) / 1e6).toFixed(2);
  const usedPct =
    reportsBudget && maxTotalScore > 0n ? Math.min(100, (Number(totalHeld) / Number(maxTotalScore)) * 100) : 0;

  const budgetUsdc = parseFixed(budgetInput, 6);
  const perReportUsdc = parseFixed(perReportInput, 6);
  const canSave = budgetUsdc !== null && perReportUsdc !== null && !!maxLoanAmount && hasProvider && !saving;

  const { writeContractAsync } = useWriteContract();
  const writeTx = useTransactor();
  const saveLimits = async () => {
    if (budgetUsdc === null || perReportUsdc === null || !maxLoanAmount || !hasProvider) return;
    // USDC at the current max loan, back to score units.
    const toScore = (usdc: bigint) => (usdc * 1_000_000n) / maxLoanAmount;
    setSaving(true);
    try {
      await writeTx(() =>
        writeContractAsync({
          address: provider,
          abi: SCORE_PROVIDER_ABI,
          functionName: "setIssuanceLimits",
          args: [toScore(budgetUsdc), toScore(perReportUsdc)],
        }),
      );
      setBudgetInput("");
      setPerReportInput("");
      await refetch();
    } catch (error) {
      console.error("setIssuanceLimits failed:", error);
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
      <h2 className="text-xl font-semibold mb-1">Oracle Issuance Budget</h2>
      <p className="text-sm text-gray-600 mb-4">
        The most credit the oracle can issue in total, and in one report. Overrides set by the owner are not counted.
      </p>
      {!hasProvider ? (
        <p className="text-sm text-gray-500">No score provider is set.</p>
      ) : !reportsBudget ? (
        <p className="text-sm text-gray-500">The score provider does not report an issuance budget.</p>
      ) : (
        <>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
            <div className="bg-purple-50 p-4 rounded-lg">
              <h3 className="font-medium text-purple-800 mb-2">Budget Held</h3>
              <div className="text-2xl font-bold text-purple-600">
                {formatUSDC(toUsdc(totalHeld))} <span className="text-base font-normal">of {formatUSDC(toUsdc(maxTotalScore))}</span>
              </div>
              <progress className="progress progress-primary w-full mt-2" value={usedPct} max={100} />
              <p className="text-sm text-purple-600 mt-1">
                {lines(totalHeld)} of {lines(maxTotalScore)} full lines of {formatUSDC(maxLoanAmount)}
              </p>
              <p className="text-sm text-purple-600 mt-1">
                Current lines: {formatUSDC(toUsdc(totalScore))} ({lines(totalScore)} full lines)
              </p>
              <p className="text-xs text-gray-500 mt-1">
                A lowered line keeps its budget until the account&apos;s line is unused. Then anyone can call
                releaseBudget to free it.
              </p>
            </div>
            <div className="bg-orange-50 p-4 rounded-lg">
              <h3 className="font-medium text-orange-800 mb-2">Per Report</h3>
              <div className="text-2xl font-bold text-orange-600">{formatUSDC(toUsdc(maxIncreasePerReport))}</div>
              <p className="text-sm text-orange-600 mt-1">
                Most one report may add ({lines(maxIncreasePerReport)} full lines)
              </p>
            </div>
          </div>
          {isProviderOwner ? (
            <div className="mt-6">
              <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                <div>
                  <label htmlFor="issuanceBudget" className="block text-sm font-medium mb-2">
                    Budget (USDC)
                  </label>
                  <input
                    id="issuanceBudget"
                    type="text"
                    inputMode="decimal"
                    placeholder={toUsdc(maxTotalScore) !== undefined ? formatUnits(toUsdc(maxTotalScore)!, 6) : ""}
                    value={budgetInput}
                    onChange={e => setBudgetInput(e.target.value)}
                    className="input input-bordered w-full"
                  />
                </div>
                <div>
                  <label htmlFor="issuancePerReport" className="block text-sm font-medium mb-2">
                    Most one report may add (USDC)
                  </label>
                  <input
                    id="issuancePerReport"
                    type="text"
                    inputMode="decimal"
                    placeholder={
                      toUsdc(maxIncreasePerReport) !== undefined ? formatUnits(toUsdc(maxIncreasePerReport)!, 6) : ""
                    }
                    value={perReportInput}
                    onChange={e => setPerReportInput(e.target.value)}
                    className="input input-bordered w-full"
                  />
                </div>
              </div>
              <div className="flex items-center gap-4 mt-4">
                <button className="btn btn-primary" disabled={!canSave} onClick={saveLimits}>
                  {saving ? "Saving..." : "Set issuance limits"}
                </button>
                <p className="text-xs text-gray-500">
                  Stored in score units, so the USDC amounts follow the max loan. A budget below what is held blocks any
                  report that raises a score until held budget is back under it.
                </p>
              </div>
            </div>
          ) : (
            <div className="text-sm text-gray-500 mt-4 flex flex-wrap items-center gap-1">
              <span>Only the score provider&apos;s owner</span>
              {providerOwner && <Address address={providerOwner} />}
              <span>can change these.</span>
            </div>
          )}
        </>
      )}
    </div>
  );
};

const AdminPage: NextPage = () => {
  const { address: connectedAddress } = useAccount();
  const { admin, loading } = useIsAdmin();
  const [userAddress, setUserAddress] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const [gasPrice, setGasPrice] = useState<bigint | null>(null);
  const [baseFee, setBaseFee] = useState<bigint | null>(null);

  // Fetch gas fees from the network
  const fetchGasFees = async () => {
    try {
      const [gasPriceResult, latestBlock] = await Promise.all([
        publicClient.getGasPrice(),
        publicClient.getBlock({ blockTag: 'latest' })
      ]);
      
      setGasPrice(gasPriceResult);
      setBaseFee(latestBlock.baseFeePerGas || 0n);
      
      console.log("🔍 Gas Price:", gasPriceResult.toString(), "wei");
      console.log("🔍 Base Fee:", (latestBlock.baseFeePerGas || 0n).toString(), "wei");
    } catch (error) {
      console.error("Error fetching gas fees:", error);
    }
  };

  // Set gas price to zero via RPC
  const setZeroGasPrice = async () => {
    try {
      console.log("🔧 Attempting to set gas price to zero...");
      
      // Try multiple methods to set gas price to zero
      const methods = [
        "anvil_setNextBlockBaseFeePerGas",
        "anvil_setGasPrice", 
        "anvil_setNextBlockGasPrice"
      ];

      for (const method of methods) {
        try {
          console.log(`🔧 Trying method: ${method}`);
          
          const response = await fetch(ANVIL_RPC_URL, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              jsonrpc: "2.0",
              id: 1,
              method: method,
              params: ["0x0"]
            })
          });

          if (response.ok) {
            const result = await response.json();
            console.log(`✅ ${method} result:`, result);
          }
        } catch (error) {
          console.log(`⚠️ ${method} failed:`, error);
        }
      }

      // Wait a moment then refresh gas fees
      setTimeout(fetchGasFees, 1000);
    } catch (error) {
      console.error("Error setting gas price to zero:", error);
    }
  };

  // Fetch gas fees on mount (scripts/start-anvil.sh already starts the chain with zero gas)
  useEffect(() => {
    fetchGasFees();
    // Refresh gas fees every 30 seconds
    const interval = setInterval(fetchGasFees, 30000);
    return () => clearInterval(interval);
  }, []);

  // Read contract data
  const { data: oracle } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "oracle",
  });

  const { data: owner } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "owner",
  });

  // Write contract functions
  const { writeContractAsync } = useScaffoldWriteContract({
    contractName: "DecentralizedMicrocredit",
  });
  
  // Centralized permissions
  const hasAccess = !!admin;
  const isOwner = !!connectedAddress && !!owner && connectedAddress.toLowerCase() === owner.toLowerCase();

  const { data: scoreProvider } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "scoreProvider",
  });

  // Pool info for overview stats
  const { data: poolInfo, refetch: refetchPoolInfo } = useScaffoldReadContract({
    contractName: "MicrocreditLens",
    functionName: "getPoolInfo",
  });
  const availableFunds = poolInfo ? poolInfo[1] : undefined;
  const lenderCount = poolInfo ? poolInfo[3] : undefined;




  // Helper numbers
  const availableFundsNumber = availableFunds !== undefined ? Number(availableFunds) : 0;

  // Utilisation stats
  const { data: totalLent, refetch: refetchTotalLent } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "totalLentOut",
  });
  const { data: utilCap, refetch: refetchUtilCap } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "lendingUtilizationCap",
  });

  // Interest rate parameters
  const { data: effrRate } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "effrRate",
  });
  const { data: riskPremium } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "riskPremium",
  });
  const { data: loanRate } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getLoanRate",
  });
  const { data: fundingPoolAPY } = useScaffoldReadContract({
    contractName: "MicrocreditLens",
    functionName: "getFundingPoolAPY",
  });

  const utilisationPct =
    availableFundsNumber > 0
      ? (((Number(totalLent ?? 0) + Number(availableFundsNumber)) / 1e6) / availableFundsNumber) * 100
      : 0;
  const capPct = utilCap ? Number(utilCap) / 100 : 0;

  // Enumeration hooks
  const { data: allLoanIds } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getAllLoanIds",
  });
  // Everyone who has been backed, and everyone who has backed someone.
  const { data: borrowerList } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getBackedBorrowers",
  });
  const { data: lenderList } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getLenders",
  });
  
  const { data: backerList } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getBackers",
  });

  /* --------------------------------------------------------------------------
   *  Helper components
   * -----------------------------------------------------------------------*/

  const LenderRow = ({ address, index }: { address: `0x${string}`; index: number }) => {
    const { data: deposit } = useScaffoldReadContract({
      contractName: "DecentralizedMicrocredit",
      functionName: "lenderBalance",
      args: [address],
    });

    const depositAmt: bigint | undefined = typeof deposit === "bigint" ? deposit : undefined;

    return (
      <tr className="hover">
        <th>{index}</th>
        <td>
          <Address address={address} />
        </td>
        <td>{formatUSDC(depositAmt)}</td>
      </tr>
    );
  };

  const LenderTable = ({ lenders }: { lenders?: readonly `0x${string}`[] }) => {
    const PAGE_SIZE = 10;
    const [filter, setFilter] = useState("");
    const [page, setPage] = useState(0);

    const filtered = useMemo(
      () => (lenders ?? []).filter(l => l.toLowerCase().includes(filter.toLowerCase())),
      [lenders, filter],
    );

    useEffect(() => setPage(0), [filter]);

    const pageCount = Math.ceil(filtered.length / PAGE_SIZE);
    const pageItems = filtered.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE);

    if (!lenders || lenders.length === 0) return null;
    return (
      <div className="space-y-2">
        <h3 className="font-medium mb-2">Lenders</h3>
        <input
          type="text"
          placeholder="Filter by address"
          value={filter}
          onChange={e => setFilter(e.target.value)}
          className="input input-bordered w-full max-w-sm mb-2"
        />
        <div className="overflow-x-auto">
          <table className="table w-full">
            <thead>
              <tr>
                <th>#</th>
                <th>Address</th>
                <th>Deposit</th>
              </tr>
            </thead>
            <tbody>
              {pageItems.map((l, idx) => (
                <LenderRow key={l} address={l} index={page * PAGE_SIZE + idx + 1} />
              ))}
            </tbody>
          </table>
        </div>
        {pageCount > 1 && (
          <div className="flex justify-end space-x-2 mt-2">
            <button className="btn btn-sm" onClick={() => setPage(p => Math.max(p - 1, 0))} disabled={page === 0}>
              Prev
            </button>
            <span className="text-sm self-center">
              Page {page + 1} / {pageCount}
            </span>
            <button
              className="btn btn-sm"
              onClick={() => setPage(p => Math.min(p + 1, pageCount - 1))}
              disabled={page === pageCount - 1}
            >
              Next
            </button>
          </div>
        )}
      </div>
    );
  };

  // ──────────── BORROWER LOAN AMOUNTS COMPONENT ────────────
  const BorrowerLoanAmounts = ({ loanIds }: { loanIds: readonly bigint[] }) => {
    const [totalAmount, setTotalAmount] = useState<bigint>(0n);
    const [isLoading, setIsLoading] = useState(true);

    useEffect(() => {
      const fetchLoanAmounts = async () => {
        if (loanIds.length === 0) {
          setTotalAmount(0n);
          setIsLoading(false);
          return;
        }

        let total = 0n;
        for (const loanId of loanIds) {
          try {
            const loan = await publicClient.readContract({
              address: MICROCREDIT_ADDRESS as `0x${string}`,
              abi: MICROCREDIT_ABI,
              functionName: "getLoan",
              args: [loanId],
            });
            
            if (loan && loan[4]) { // loan[4] is isActive
              total += loan[0]; // loan[0] is principal
            }
          } catch (error) {
            console.error(`Failed to fetch loan ${loanId}:`, error);
          }
        }
        
        setTotalAmount(total);
        setIsLoading(false);
      };

      fetchLoanAmounts();
    }, [loanIds]);

    if (isLoading) {
      return <span className="text-gray-500">Loading...</span>;
    }

    return (
      <div className="text-sm">
        <div className="text-gray-600">
          {formatUSDC(totalAmount)}
        </div>
      </div>
    );
  };

  // ──────────── BORROWER MAX LOAN AMOUNT COMPONENT ────────────
  const BorrowerMaxLoanAmount = ({ creditScore }: { creditScore: bigint | undefined }) => {
    const { data: maxLoanAmount } = useScaffoldReadContract({
      contractName: "DecentralizedMicrocredit",
      functionName: "maxLoanAmount",
    });

    const maxAllowedAmount = useMemo(() => {
      if (!creditScore || !maxLoanAmount) return 0n;
      
      // Calculate max allowed amount based on credit score
      // Formula: (maxLoanAmount / SCALE) * creditScore
      // where SCALE = 1e6 and creditScore is in the same scale
      return (BigInt(maxLoanAmount) * creditScore) / BigInt(1e6);
    }, [creditScore, maxLoanAmount]);

    if (!creditScore || creditScore === 0n) {
      return <span className="text-gray-500">No credit</span>;
    }

    return (
      <div className="text-sm">
        <div className="text-green-600 font-medium">
          {formatUSDC(maxAllowedAmount)}
        </div>
        <div className="text-gray-600 text-xs">
          Max eligible
        </div>
      </div>
    );
  };

  // ──────────── BORROWERS TABLE ────────────
  const BorrowerRow = ({ address, index }: { address: `0x${string}`; index: number }) => {
    const { data: creditScore } = useScaffoldReadContract({
      contractName: "DecentralizedMicrocredit",
      functionName: "getCreditScore",
      args: [address],
    });

    const { data: borrowLimit } = useScaffoldReadContract({
      contractName: "DecentralizedMicrocredit",
      functionName: "getBorrowLimit",
      args: [address],
    });

    const { data: kycVerified } = useScaffoldReadContract({
      contractName: "DecentralizedMicrocredit",
      functionName: "isKYCVerified",
      args: [address],
    });

    // Get borrower's loan IDs
    const { data: borrowerLoanIds } = useScaffoldReadContract({
      contractName: "DecentralizedMicrocredit",
      functionName: "getBorrowerLoanIds",
      args: [address],
    });

    // Calculate total loan amount from all active loans
    const totalLoanAmount = useMemo(() => {
      if (!borrowerLoanIds || borrowerLoanIds.length === 0) return 0n;
      
      // For now, we'll show the count of loans
      // In a future implementation, we could fetch individual loan details
      // to show the actual total amount borrowed
      return 0n; // Placeholder for total amount calculation
    }, [borrowerLoanIds]);

    const getCreditScoreColor = (score: bigint | undefined) => {
      if (!score) return "text-gray-500";
      const percent = Number(score) / 1e4;
      if (percent < 30) return "text-red-500";
      if (percent < 50) return "text-orange-500";
      if (percent < 70) return "text-yellow-500";
      if (percent < 90) return "text-blue-500";
      return "text-green-500";
    };

    return (
      <tr className="hover">
        <th>{index}</th>
        <td>
          <Address address={address} />
        </td>
        <td className={getCreditScoreColor(creditScore)}>
          {creditScore ? `${(Number(creditScore) / 1e4).toFixed(1)}%` : "-"}
        </td>
        <td>{borrowLimit ? formatUSDC(borrowLimit[0]) : "-"}</td>
        <td>
          {borrowerLoanIds && borrowerLoanIds.length > 0 ? (
            <BorrowerLoanAmounts loanIds={borrowerLoanIds} />
          ) : (
            <span className="text-gray-500">No loans</span>
          )}
        </td>
        <td>
          <BorrowerMaxLoanAmount creditScore={creditScore} />
        </td>
        <td>
          {kycVerified ? (
            <span className="badge badge-success badge-sm">Verified</span>
          ) : (
            <span className="badge badge-warning badge-sm">Pending</span>
          )}
        </td>
      </tr>
    );
  };

  const BorrowerTable = ({ borrowers }: { borrowers?: readonly `0x${string}`[] }) => {
    const PAGE_SIZE = 10;
    const [filter, setFilter] = useState("");
    const [page, setPage] = useState(0);

    const filtered = useMemo(
      () => (borrowers ?? []).filter(b => b.toLowerCase().includes(filter.toLowerCase())),
      [borrowers, filter],
    );

    useEffect(() => setPage(0), [filter]);

    const pageCount = Math.ceil(filtered.length / PAGE_SIZE);
    const pageItems = filtered.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE);

    if (!borrowers || borrowers.length === 0) return null;
    return (
      <div className="space-y-2">
        <h3 className="font-medium mb-2">Borrowers</h3>
        <input
          type="text"
          placeholder="Filter by address"
          value={filter}
          onChange={e => setFilter(e.target.value)}
          className="input input-bordered w-full max-w-sm mb-2"
        />
        <div className="overflow-x-auto">
          <table className="table w-full">
            <thead>
              <tr>
                <th>#</th>
                <th>Address</th>
                <th>Credit Score</th>
                <th>Credit Limit</th>
                <th>Loans</th>
                <th>Max Loan</th>
                <th>KYC Status</th>
              </tr>
            </thead>
            <tbody>
              {pageItems.map((b, idx) => (
                <BorrowerRow key={b} address={b} index={page * PAGE_SIZE + idx + 1} />
              ))}
            </tbody>
          </table>
        </div>
        {pageCount > 1 && (
          <div className="flex justify-end space-x-2 mt-2">
            <button className="btn btn-sm" onClick={() => setPage(p => Math.max(p - 1, 0))} disabled={page === 0}>
              Prev
            </button>
            <span className="text-sm self-center">
              Page {page + 1} / {pageCount}
            </span>
            <button
              className="btn btn-sm"
              onClick={() => setPage(p => Math.min(p + 1, pageCount - 1))}
              disabled={page === pageCount - 1}
            >
              Next
            </button>
          </div>
        )}
      </div>
    );
  };

  // ──────────── BACKINGS TABLE ────────────
  const BackingsTable = ({ borrowers }: { borrowers?: readonly `0x${string}`[] }) => {
    const [filter, setFilter] = useState("");
    const [allBackings, setAllBackings] = useState<
      Array<{ borrower: `0x${string}`; backer: `0x${string}`; secured: bigint; unsecured: bigint }>
    >([]);
    const [isLoading, setIsLoading] = useState(true);

    useEffect(() => {
      const fetchAllBackings = async () => {
        const rows: typeof allBackings = [];
        for (const borrower of borrowers ?? []) {
          try {
            const backings = (await publicClient.readContract({
              address: MICROCREDIT_ADDRESS as `0x${string}`,
              abi: MICROCREDIT_ABI,
              functionName: "getBackings",
              args: [borrower],
            })) as readonly { backer: `0x${string}`; secured: bigint; unsecured: bigint }[];
            for (const { backer, secured, unsecured } of backings) {
              if (secured + unsecured > 0n) rows.push({ borrower, backer, secured, unsecured });
            }
          } catch (error) {
            console.error(`Failed to fetch backings for ${borrower}:`, error);
          }
        }
        setAllBackings(rows);
        setIsLoading(false);
      };
      fetchAllBackings();
    }, [borrowers]);

    const filteredBackings = useMemo(() => {
      if (!filter) return allBackings;
      const lowerFilter = filter.toLowerCase();
      return allBackings.filter(
        row => row.borrower.toLowerCase().includes(lowerFilter) || row.backer.toLowerCase().includes(lowerFilter),
      );
    }, [allBackings, filter]);

    if (!borrowers || borrowers.length === 0) return null;

    return (
      <div>
        <h3 className="font-medium mb-2">Backings</h3>
        <div className="mb-4">
          <input
            type="text"
            placeholder="Filter by borrower or backer address"
            value={filter}
            onChange={e => setFilter(e.target.value)}
            className="input input-bordered w-full max-w-md"
          />
        </div>
        <div className="overflow-x-auto max-h-96">
          <table className="table w-full">
            <thead>
              <tr>
                <th>Borrower</th>
                <th>Backer</th>
                <th>Secured (stake)</th>
                <th>Unsecured (credit)</th>
              </tr>
            </thead>
            <tbody>
              {isLoading ? (
                <tr>
                  <td colSpan={4} className="text-center text-gray-500 py-4">
                    Loading backings...
                  </td>
                </tr>
              ) : filteredBackings.length === 0 ? (
                <tr>
                  <td colSpan={4} className="text-center text-gray-500 py-4">
                    {filter ? "No backings match your filter" : "No backings found"}
                  </td>
                </tr>
              ) : (
                filteredBackings.map(row => (
                  <tr key={`${row.borrower}-${row.backer}`} className="hover text-sm">
                    <td>
                      <Address address={row.borrower} />
                    </td>
                    <td>
                      <Address address={row.backer} />
                    </td>
                    <td>{formatUSDC(row.secured)}</td>
                    <td>{formatUSDC(row.unsecured)}</td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>
    );
  };

  // ──────────── LOANS TABLE ────────────
  const LoanRow = ({ loanId, index }: { loanId: bigint; index: number }) => {
    const { data: loan } = useScaffoldReadContract({
      contractName: "DecentralizedMicrocredit",
      functionName: "getLoan",
      args: [loanId],
    });

    if (!loan) return null;
    const [principal, outstanding, borrower] = loan as [bigint, bigint, `0x${string}`, bigint, boolean];

    return (
      <tr className="hover text-sm">
        <th>{index}</th>
        <td>{loanId.toString()}</td>
        <td>
          <Address address={borrower} />
        </td>
        <td>{formatUSDC(principal)}</td>
        <td>{formatUSDC(outstanding)}</td>
      </tr>
    );
  };

  const LoanTable = ({ loanIds }: { loanIds?: readonly bigint[] }) => {
    if (!loanIds || loanIds.length === 0) return null;
    return (
      <div>
        <h3 className="font-medium mb-2">Loans</h3>
        <div className="overflow-x-auto max-h-96">
          <table className="table w-full">
            <thead>
              <tr>
                <th>#</th>
                <th>ID</th>
                <th>Borrower</th>
                <th>Principal</th>
                <th>Outstanding</th>
              </tr>
            </thead>
            <tbody>
              {loanIds.map((id, idx) => (
                <LoanRow key={id.toString()} loanId={id} index={idx + 1} />
              ))}
            </tbody>
          </table>
        </div>
      </div>
    );
  };

  // ────────────────────────────────────────────────────────────────────────────
  //  RENDER
  // ────────────────────────────────────────────────────────────────────────────
  if (loading) {
    return (
      <div className="flex items-center justify-center min-h-screen">
        <div className="text-center text-gray-600">Checking admin access…</div>
      </div>
    );
  }

  if (!hasAccess) {
    return (
      <div className="flex items-center justify-center min-h-screen">
        <div className="text-center">
          <ShieldCheckIcon className="h-16 w-16 mx-auto text-red-500 mb-4" />
          <h1 className="text-2xl font-bold text-red-500 mb-2">Access Denied</h1>
          <p className="text-gray-600 mb-4">
            You need to be the contract owner, guardian, oracle, or whitelisted to access this page.
          </p>
          <div className="space-y-2 text-sm text-gray-500">
            <div>
              Current Oracle: {oracle ? <Address address={oracle as `0x${string}`} /> : "Loading..."}
            </div>
            <div>
              Contract Owner: {owner ? <Address address={owner as `0x${string}`} /> : "Loading..."}
            </div>
            <div>
              USDC Contract: {USDC_ADDRESS ? <Address address={USDC_ADDRESS as `0x${string}`} /> : "Loading..."}
              {USDC_ADDRESS && <span className="text-xs text-gray-400 ml-2">({USDC_ADDRESS})</span>}
            </div>
            <div>Your Address: {connectedAddress ? <Address address={connectedAddress} /> : "Not connected"}</div>
          </div>
        </div>
      </div>
    );
  }

  return (
    <>
      <div className="flex items-center flex-col grow pt-10">
        <div className="px-5 w-full max-w-6xl">
          <h1 className="text-3xl font-bold mb-6">🛠️ Admin Panel</h1>

          {/* Overview cards */}
          <div className="grid grid-cols-1 md:grid-cols-4 gap-6 mb-8">
            <div className="bg-base-100 p-6 rounded-lg shadow text-center">
              <div className="text-2xl font-bold text-green-500">
                {poolInfo ? formatUSDC(poolInfo[0]) : "Loading…"}
              </div>
              <div className="text-sm text-gray-600">Total Deposits</div>
            </div>
            <div className="bg-base-100 p-6 rounded-lg shadow text-center">
              <div className="text-2xl font-bold text-blue-500">
                {availableFunds !== undefined ? formatUSDC(availableFunds) : "Loading…"}
              </div>
              <div className="text-sm text-gray-600">Available Funds</div>
            </div>
            <div className="bg-base-100 p-6 rounded-lg shadow text-center">
              <div className="text-2xl font-bold text-orange-500">
                {lenderCount !== undefined ? lenderCount.toString() : "Loading…"}
              </div>
              <div className="text-sm text-gray-600">Active Lenders</div>
            </div>
            <div className="bg-base-100 p-6 rounded-lg shadow text-center">
              <div className="text-2xl font-bold text-purple-500">
                {gasPrice !== null ? gasPrice.toString() : "Loading…"}
              </div>
              <div className="text-sm text-gray-600">Gas Price (wei)</div>
              <div className="text-xs text-gray-500 mt-1">
                Base Fee: {baseFee !== null ? baseFee.toString() : "Loading…"} wei
              </div>
              <div className="text-xs text-green-600 mt-1">
                {gasPrice === 0n ? "✅ FREE" : "💰 PAID"}
              </div>
            </div>
          </div>

          {/* Navigation Links */}
          <div className="flex justify-center mb-6">
            <Link 
              href="/populate-test-data" 
              className="btn btn-primary btn-sm"
            >
              🛠️ Populate Test Data
            </Link>
          </div>

          <EmergencyPausePanel isOwner={isOwner} />

          {/* Gas Fee Information */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">⛽ Network Gas Fees</h2>
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
              <div className="text-center">
                <div className="text-lg font-semibold text-purple-600">
                  {gasPrice !== null ? gasPrice.toString() : "Loading…"}
                </div>
                <div className="text-sm text-gray-600">Gas Price (wei)</div>
                <div className="text-xs text-gray-500">
                  {gasPrice !== null ? `${(Number(gasPrice) / 1e9).toFixed(9)} Gwei` : ""}
                </div>
              </div>
              <div className="text-center">
                <div className="text-lg font-semibold text-blue-600">
                  {baseFee !== null ? baseFee.toString() : "Loading…"}
                </div>
                <div className="text-sm text-gray-600">Base Fee (wei)</div>
                <div className="text-xs text-gray-500">
                  {baseFee !== null ? `${(Number(baseFee) / 1e9).toFixed(9)} Gwei` : ""}
                </div>
              </div>
              <div className="text-center">
                <div className={`text-lg font-semibold ${gasPrice === 0n ? 'text-green-600' : 'text-red-600'}`}>
                  {gasPrice === 0n ? "FREE" : "PAID"}
                </div>
                <div className="text-sm text-gray-600">Transaction Cost</div>
                <div className="text-xs text-gray-500">
                  {gasPrice === 0n ? "No gas fees" : "Gas fees apply"}
                </div>
              </div>
            </div>
            <div className="mt-4 text-sm text-gray-600">
              <p><strong>Network Status:</strong> {gasPrice === 0n ? "✅ Completely free transactions" : "⚠️ Gas fees are being charged"}</p>
              <p><strong>Configuration:</strong> Anvil local network with gas_price=0, base_fee=0</p>
              {gasPrice !== 0n && (
                <div className="mt-2">
                  <button
                    onClick={setZeroGasPrice}
                    className="btn btn-sm btn-warning"
                    title="Force set gas price to zero"
                  >
                    🔧 Force Zero Gas
                  </button>
                  <span className="ml-2 text-xs text-gray-500">
                    Click if gas price is not zero despite configuration
                  </span>
                </div>
              )}
            </div>
          </div>




          {/* Pool Utilization Widget */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <div className="flex justify-between items-center mb-4">
              <h2 className="text-xl font-semibold">Pool Utilization</h2>
              <button
                onClick={async () => {
                  await Promise.all([
                    refetchPoolInfo(),
                    refetchTotalLent(),
                    refetchUtilCap()
                  ]);
                }}
                className="btn btn-sm btn-outline"
                title="Refresh pool data"
              >
                🔄 Refresh
              </button>
            </div>
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
              <div className="bg-green-50 p-4 rounded-lg">
                <h3 className="font-medium text-green-800 mb-2">Total Pool</h3>
                <div className="text-2xl font-bold text-green-600">
                  {poolInfo ? formatUSDC(poolInfo[0]) : "Loading..."}
                </div>
                <p className="text-sm text-green-600 mt-1">Total deposits</p>
              </div>
              <div className="bg-blue-50 p-4 rounded-lg">
                <h3 className="font-medium text-blue-800 mb-2">Amount Lent Out</h3>
                <div className="text-2xl font-bold text-blue-600">
                  {totalLent ? formatUSDC(totalLent) : "Loading..."}
                </div>
                <p className="text-sm text-blue-600 mt-1">Currently active loans</p>
              </div>
              <div className="bg-orange-50 p-4 rounded-lg">
                <h3 className="font-medium text-orange-800 mb-2">Available Funds</h3>
                <div className="text-2xl font-bold text-orange-600">
                  {poolInfo ? formatUSDC(poolInfo[1]) : "Loading..."}
                </div>
                <p className="text-sm text-orange-600 mt-1">Liquid for lending/withdrawal</p>
              </div>
              <div className="bg-purple-50 p-4 rounded-lg">
                <h3 className="font-medium text-purple-800 mb-2">Utilization</h3>
                <div className="text-2xl font-bold text-purple-600">
                  {poolInfo && totalLent ? `${((Number(totalLent) / Number(poolInfo[0])) * 100).toFixed(1)}%` : "Loading..."}
                </div>
                <p className="text-sm text-purple-600 mt-1">
                  Cap: {utilCap ? `${(Number(utilCap) / 100).toFixed(0)}%` : "Loading..."}
                </p>
              </div>
            </div>
            
            {/* Utilization Progress Bar */}
            {poolInfo && totalLent && utilCap && (
              <div className="mt-6">
                <div className="flex justify-between text-sm text-gray-600 mb-2">
                  <span>Current Utilization</span>
                  <span>{((Number(totalLent) / Number(poolInfo[0])) * 100).toFixed(1)}% / {(Number(utilCap) / 100).toFixed(0)}%</span>
                </div>
                <div className="w-full bg-gray-200 rounded-full h-3">
                  <div 
                    className={`h-3 rounded-full transition-all duration-300 ${
                      (Number(totalLent) / Number(poolInfo[0])) * 100 > (Number(utilCap) / 100) * 0.9 
                        ? 'bg-red-500' 
                        : (Number(totalLent) / Number(poolInfo[0])) * 100 > (Number(utilCap) / 100) * 0.7 
                        ? 'bg-yellow-500' 
                        : 'bg-green-500'
                    }`}
                    style={{ 
                      width: `${Math.min((Number(totalLent) / Number(poolInfo[0])) * 100, 100)}%` 
                    }}
                  ></div>
                </div>
                <div className="mt-2 text-xs text-gray-500">
                  {poolInfo[2] ? `Reserved: ${formatUSDC(poolInfo[2])}` : ''}
                </div>
              </div>
            )}
          </div>

          {/* Overview Stats */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Platform Overview</h2>
            <div className="grid grid-cols-2 md:grid-cols-5 gap-6 text-center">
              <div>
                <div className="text-2xl font-bold text-blue-500">{allLoanIds ? allLoanIds.length : "-"}</div>
                <div className="text-sm text-gray-600">Total Loans</div>
              </div>
              <div>
                <div className="text-2xl font-bold text-green-500">{borrowerList ? borrowerList.length : "-"}</div>
                <div className="text-sm text-gray-600">Borrowers</div>
              </div>
              <div>
                <div className="text-2xl font-bold text-purple-500">{lenderList ? lenderList.length : "-"}</div>
                <div className="text-sm text-gray-600">Lenders</div>
              </div>
              <div>
                <div className="text-2xl font-bold text-orange-500">{backerList ? backerList.length : "-"}</div>
                <div className="text-sm text-gray-600">Backers</div>
              </div>
            </div>
          </div>

          {/* Interest Rate Configuration */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Interest Rate Configuration</h2>
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
              <div className="bg-blue-50 p-4 rounded-lg">
                <h3 className="font-medium text-blue-800 mb-2">Effective Federal Funds Rate (EFFR)</h3>
                <div className="text-2xl font-bold text-blue-600">
                  {effrRate !== undefined ? (Number(effrRate) / 100).toFixed(2) : "-"}%
                </div>
                <p className="text-sm text-blue-600 mt-1">Base rate for all loans</p>
              </div>
              <div className="bg-orange-50 p-4 rounded-lg">
                <h3 className="font-medium text-orange-800 mb-2">Risk Premium</h3>
                <div className="text-2xl font-bold text-orange-600">
                  {riskPremium !== undefined ? (Number(riskPremium) / 100).toFixed(2) : "-"}%
                </div>
                <p className="text-sm text-orange-600 mt-1">Platform risk adjustment</p>
              </div>
              <div className="bg-green-50 p-4 rounded-lg">
                <h3 className="font-medium text-green-800 mb-2">Loan Rate (APR)</h3>
                <div className="text-2xl font-bold text-green-600">
                  {loanRate !== undefined ? (Number(loanRate) / 100).toFixed(2) : "-"}%
                </div>
                <p className="text-sm text-green-600 mt-1">EFFR + Risk Premium</p>
              </div>
              <div className="bg-purple-50 p-4 rounded-lg">
                <h3 className="font-medium text-purple-800 mb-2">Funding Pool APY</h3>
                <div className="text-2xl font-bold text-purple-600">
                  {fundingPoolAPY !== undefined ? (Number(fundingPoolAPY) / 100).toFixed(2) : "-"}%
                </div>
                <p className="text-sm text-purple-600 mt-1">Projected lender yield, net of fee and reserve</p>
              </div>
            </div>
            <div className="mt-4 p-3 bg-gray-100 rounded-md">
              <p className="text-sm text-gray-700">
                <strong>Note:</strong> EFFR should be updated to reflect current market conditions (currently 4.33%). 
                Risk premium is set to 5% for platform sustainability.
              </p>
            </div>
          </div>

          <FirstLossReservePanel isOwner={isOwner} />

          <IssuanceBudgetPanel />

          {/* Detailed Data */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Detailed Data</h2>
            <div className="space-y-8">
              {/* 🔑 Casts added below fix TS2322 */}
              <LenderTable lenders={lenderList as readonly `0x${string}`[] | undefined} />
              <BorrowerTable borrowers={borrowerList as readonly `0x${string}`[] | undefined} />
              <BackingsTable borrowers={borrowerList as readonly `0x${string}`[] | undefined} />
              <LoanTable loanIds={allLoanIds} />
            </div>
          </div>

          {/* System Actions */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">System Actions</h2>
            
            <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
              <div>
                <h3 className="font-medium mb-2">System Health</h3>
                <div className="space-y-2 text-sm">
                  <div className="flex items-center space-x-2">
                    <div className="w-2 h-2 bg-green-500 rounded-full"></div>
                    <span>Contract: Active</span>
                  </div>
                  <div className="flex items-center space-x-2">
                    <div className="w-2 h-2 bg-green-500 rounded-full"></div>
                    <span>Oracle: {oracle ? 'Set' : 'Not Set'}</span>
                  </div>
                  <div className="flex items-center space-x-2">
                    <div className="w-2 h-2 bg-green-500 rounded-full"></div>
                    <span>Score Provider: {scoreProvider && scoreProvider !== zeroAddress ? "Set" : "Not Set"}</span>
                  </div>
                  <div className="flex items-center space-x-2">
                    <div
                      className={`w-2 h-2 rounded-full ${
                        utilisationPct < capPct * 0.9 ? "bg-green-500" : "bg-yellow-500"
                      }`}
                    ></div>
                    <span>
                      Pool Utilisation: {utilisationPct.toFixed(2)}% / {capPct.toFixed(0)}%
                    </span>
                  </div>
                  <div className="flex items-center space-x-2">
                    <div
                      className={`w-2 h-2 rounded-full ${
                        utilisationPct < capPct * 0.9 ? "bg-green-500" : "bg-yellow-500"
                      }`}
                    ></div>
                    <span>Borrower Count: {borrowerList ? borrowerList.length : "-"}</span>
                  </div>
                  <div className="flex items-center space-x-2">
                    <div
                      className={`w-2 h-2 rounded-full ${
                        utilisationPct < capPct * 0.9 ? "bg-green-500" : "bg-yellow-500"
                      }`}
                    ></div>
                    <span>Lender Count: {lenderList ? lenderList.length : "-"}</span>
                  </div>
                  <div className="flex items-center space-x-2">
                    <div
                      className={`w-2 h-2 rounded-full ${
                        utilisationPct < capPct * 0.9 ? "bg-green-500" : "bg-yellow-500"
                      }`}
                    ></div>
                    <span>Backer Count: {backerList ? backerList.length : "-"}</span>
                  </div>
                </div>
              </div>
              <div>
                <h3 className="font-medium mb-2">Admin Status</h3>
                <div className="space-y-2 text-sm">
                  <div className="flex items-center space-x-2">
                    <div className="w-2 h-2 bg-green-500 rounded-full"></div>
                    <span>Access: {hasAccess ? "Granted" : "Denied"}</span>
                  </div>
                  <div className="flex items-center space-x-2">
                    <div className="w-2 h-2 bg-green-500 rounded-full"></div>
                    <span>
                      {(() => {
                        const me = connectedAddress?.toLowerCase();
                        const isOwnerDisplay = me && owner && me === owner.toLowerCase();
                        const isOracleDisplay = me && oracle && me === oracle.toLowerCase();
                        const role = isOwnerDisplay ? "Owner" : isOracleDisplay ? "Oracle" : hasAccess ? "Whitelisted" : "None";
                        return <>Role: {role}</>;
                      })()}
                    </span>
                  </div>
                </div>
              </div>
            </div>
            {utilisationPct > capPct * 0.9 && (
              <div className="alert alert-warning mt-4">
                Warning: pool is above 90% of its utilisation cap. Consider adding liquidity or pausing new loans to ensure
                withdrawals can be honoured.
              </div>
            )}
          </div>

          {/* Oracle Management */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Oracle Management</h2>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
              <div>
                <h3 className="font-medium mb-2">Current Oracle</h3>
                {oracle ? <Address address={oracle as `0x${string}`} /> : <div className="text-gray-500">Loading...</div>}
              </div>
              <div>
                <h3 className="font-medium mb-2">Contract Owner</h3>
                {owner ? <Address address={owner as `0x${string}`} /> : <div className="text-gray-500">Loading...</div>}
              </div>
            </div>
          </div>

          {/* Instructions */}
          <div className="bg-base-300 rounded-lg p-6">
            <h2 className="text-xl font-semibold mb-4">Admin Functions</h2>
            <div className="space-y-4">
              <div>
                <h3 className="font-medium">Credit Score Management</h3>
                <p className="text-sm text-gray-600">Update credit scores for users. Scores should be between 0-100 %.</p>
              </div>
              <div>
                <h3 className="font-medium">Oracle Setup</h3>
                <p className="text-sm text-gray-600">
                  Use the{" "}
                  <a href="/oracle-setup" className="text-blue-500 underline">
                    Oracle Setup page
                  </a>{" "}
                  to manage oracle permissions.
                </p>
              </div>
              <div>
                <h3 className="font-medium">Debug Interface</h3>
                <p className="text-sm text-gray-600">
                  Use the{" "}
                  <a href="/debug" className="text-blue-500 underline">
                    Debug page
                  </a>{" "}
                  to test contract functions and view contract state.
                </p>
              </div>
            </div>
          </div>

          {/* Site Map */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Site Map</h2>
            <ul className="list-disc ml-5 space-y-2 text-blue-600">
              <li><Link href="/">Home</Link></li>
              <li><Link href="/lend">Lender Portal</Link></li>
              <li><Link href="/borrower">Borrower Portal</Link></li>
              <li><Link href="/scores">Credit Scores</Link></li>
              <li><Link href="/admin">Admin Panel</Link></li>
              <li><Link href="/populate-test-data">Populate Test Data</Link></li>
              <li><Link href="/debug">Debug Contract</Link></li>
              <li><Link href="/oracle-setup">Oracle Setup</Link></li>
            </ul>
          </div>
        </div>
      </div>
    </>
  );
};

export default AdminPage;