"use client";

import { useState, useEffect } from "react";
import type { NextPage } from "next";
import { useAccount } from "wagmi";
import { formatUSDC, formatUSDCAllowance, getCreditScoreColor } from "~~/utils/format";
import { BanknotesIcon, PlusIcon, EyeIcon, HandThumbUpIcon } from "@heroicons/react/24/outline";
import { Address } from "~~/components/scaffold-eth";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import HowItWorks from "~~/components/HowItWorks";
// removed parseEther import because USDC uses 6 decimals
import { AddressInput } from "~~/components/scaffold-eth";
import deployedContracts from "~~/contracts/deployedContracts";

const LendPage: NextPage = () => {
  const { address: connectedAddress } = useAccount();
  // Default deposit amount set to 1000 USDC for convenience; adjust or remove as needed.
  const [depositAmount, setDepositAmount] = useState("1000");
  const [selectedLoanId, setSelectedLoanId] = useState<number | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [attestBorrower, setAttestBorrower] = useState("");
  const [attestWeight, setAttestWeight] = useState<number>(50);
  const [attestLoading, setAttestLoading] = useState(false);
  // Track attestations made by the connected lender (session-level + localStorage cache)
  const [attestations, setAttestations] = useState<{ borrower: `0x${string}`; weight: number }[]>([]);
  const [filterText, setFilterText] = useState("");
  const [showForm, setShowForm] = useState(false);
  const [usdcBalance, setUsdcBalance] = useState<bigint>(0n);
  const [usdcAllowance, setUsdcAllowance] = useState<bigint>(0n);
  const [approvalLoading, setApprovalLoading] = useState(false);
  const [withdrawAmount, setWithdrawAmount] = useState("");
  const [withdrawLoading, setWithdrawLoading] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [mintLoading, setMintLoading] = useState(false);

  // Helper function to safely parse deposit amount to BigInt
  const parseDepositAmount = (amount: string): bigint | null => {
    if (!amount || amount.trim() === "") return null;
    const parsed = parseFloat(amount);
    if (isNaN(parsed) || parsed <= 0) return null;
    return BigInt(Math.floor(parsed * 1e6));
  };

  // Helper function to safely parse withdraw amount to BigInt
  const parseWithdrawAmount = (amount: string): bigint | null => {
    if (!amount || amount.trim() === "") return null;
    const parsed = parseFloat(amount);
    if (isNaN(parsed) || parsed <= 0) return null;
    return BigInt(Math.floor(parsed * 1e6));
  };

  // Load cached attestations from localStorage when wallet connects
  useEffect(() => {
    if (!connectedAddress) return;
    const key = `attestations_${connectedAddress}`;
    const stored = window.localStorage.getItem(key);
    if (stored) {
      try {
        setAttestations(JSON.parse(stored));
      } catch {
        // ignore parse errors
      }
    }
  }, [connectedAddress]);

  // Persist whenever attestations change
  useEffect(() => {
    if (!connectedAddress) return;
    const key = `attestations_${connectedAddress}`;
    window.localStorage.setItem(key, JSON.stringify(attestations));
  }, [attestations, connectedAddress]);

  const filteredAttestations = attestations.filter(a =>
    a.borrower.toLowerCase().includes(filterText.toLowerCase())
  );

  // Contract hooks
  const { writeContractAsync } = useScaffoldWriteContract({
    contractName: "DecentralizedMicrocredit",
  });

  // USDC contract hooks
  const { data: usdcAddress } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "usdc",
  });

  // Resolve DecentralizedMicrocredit contract address from deployments
  const CONTRACT_ADDRESS = deployedContracts[31337]?.DecentralizedMicrocredit?.address as `0x${string}`;

  const { writeContractAsync: writeUSDCAsync } = useScaffoldWriteContract({
    contractName: "MockUSDC",
  });

  // ────── Lender-specific data ──────
  const { data: lenderDeposit, refetch: refetchLenderDeposit } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "lenderDeposits",
    args: [connectedAddress as `0x${string}` | undefined],
  });

  const { data: poolApyBp } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getFundingPoolAPY" as any,
  });
  
  const { data: loanRateBp } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getLoanRate",
  });
  
  const poolRatePercent = poolApyBp !== undefined ? (Number(poolApyBp) / 100).toFixed(2) : undefined;
  const loanRatePercent = loanRateBp !== undefined ? (Number(loanRateBp) / 100).toFixed(2) : undefined;

  /**
   * Interest should accrue only when borrowers make repayments.  Until the
   * smart-contract exposes an on-chain "lenderInterest" value we keep this at
   * 0 so the UI doesn’t over-promise returns immediately after a deposit.
   */
  const interestEarned: bigint | undefined = 0n;

  const totalBalance = lenderDeposit !== undefined ? lenderDeposit : undefined;

  // Remove placeholder arrays and fetch on-chain data
  const { data: poolInfo, refetch: refetchPoolInfo } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getPoolInfo",
  });

  // poolInfo returns [_totalDeposits, _availableFunds, _lenderCount]
  const totalDeposits = poolInfo ? poolInfo[0] : undefined;
  const availableFunds = poolInfo ? poolInfo[1] : undefined;
  const lenderCount = poolInfo ? poolInfo[3] : undefined;
  // TODO: replace these with real data once contract supports them
  const lenderInfo: bigint[] | undefined = undefined;
  const availableLoans: bigint[] = [];

  // Read USDC balance and allowance
  const { data: usdcBalanceData, refetch: refetchUsdcBalance } = useScaffoldReadContract({
    contractName: "MockUSDC",
    functionName: "balanceOf",
    args: [connectedAddress as `0x${string}` | undefined],
  });

  const { data: usdcAllowanceData, refetch: refetchUsdcAllowance } = useScaffoldReadContract({
    contractName: "MockUSDC",
    functionName: "allowance",
    args: [connectedAddress as `0x${string}` | undefined, CONTRACT_ADDRESS],
  });

  // Update state when data changes
  useEffect(() => {
    if (usdcBalanceData) setUsdcBalance(usdcBalanceData);
    if (usdcAllowanceData) setUsdcAllowance(usdcAllowanceData);
  }, [usdcBalanceData, usdcAllowanceData]);

  const handleDeposit = async () => {
    if (!depositAmount || !connectedAddress || !usdcAddress) return;
    
    const amountInt = parseDepositAmount(depositAmount);
    if (!amountInt) {
      setErrorMessage("Please enter a valid deposit amount greater than 0.");
      return;
    }
    
    setIsLoading(true);
    try {
      
      // Check if approval is needed
      if (usdcAllowance < amountInt) {
        setApprovalLoading(true);
        try {
          console.log("🔍 Approval needed. Current allowance:", formatUSDC(usdcAllowance), "Required:", formatUSDC(amountInt));
          
          // First, try to approve the exact amount needed
          const approvalTx = await writeUSDCAsync({
            functionName: "approve",
            args: [CONTRACT_ADDRESS, amountInt],
          });
          
          console.log("🔍 Approval transaction sent, waiting for confirmation...");
          
          // Wait for the transaction to be mined
          if (approvalTx) {
            console.log("🔍 Waiting for approval transaction to be mined...");
            // Add a small delay to allow the transaction to be mined
            await new Promise(resolve => setTimeout(resolve, 2000));
          }
          
          // Refetch allowance after approval
          await refetchUsdcAllowance();
          
          // Double-check that approval was successful
          const newAllowance = await refetchUsdcAllowance();
          console.log("🔍 New allowance after approval:", formatUSDC(usdcAllowance));
          
          // If approval still failed, try with a larger amount
          if (usdcAllowance < amountInt) {
            console.log("🔍 Approval may have failed, trying with larger amount...");
            await writeUSDCAsync({
              functionName: "approve",
              args: [CONTRACT_ADDRESS, amountInt * 2n], // Approve double the amount
            });
            
            // Wait again
            await new Promise(resolve => setTimeout(resolve, 2000));
            await refetchUsdcAllowance();
          }
          
        } catch (approvalError: any) {
          console.error("🔍 Approval failed:", approvalError);
          setErrorMessage(`Approval failed: ${approvalError?.message || "Unknown error"}`);
          return;
        } finally {
          setApprovalLoading(false);
        }
      }
      
      // Final check before deposit
      if (usdcAllowance < amountInt) {
        setErrorMessage("Approval is still insufficient. Please try approving again or refresh the page.");
        return;
      }
      
      await writeContractAsync({
        functionName: "depositFunds",
        args: [amountInt],
      });
      
      // Refetch all relevant data after successful deposit
      await Promise.all([
        refetchPoolInfo(),
        refetchLenderDeposit(),
        refetchUsdcBalance(),
        refetchUsdcAllowance()
      ]);

      /* -------------------------------------------------------------
         DEMO ONLY: trigger PageRank recomputation automatically
         after every successful deposit so lenders immediately see
         updated pool APR & credit-score effects in the UI.

         This adds extra gas cost and should NOT be enabled in
         production.  Simply delete the block (or wrap with a flag)
         to revert to manual PageRank runs from the Admin panel.
      --------------------------------------------------------------*/
      try {
        console.log("🔄 Auto-computing PageRank after deposit (demo mode)…");
        await writeContractAsync({ functionName: "computePageRank" });
        console.log("✅ PageRank recomputed");
      } catch (prErr) {
        console.warn("⚠️ Auto PageRank failed (safe to ignore in demo):", prErr);
      }
      
      setDepositAmount("");
      setErrorMessage(null);
    } catch (error: any) {
      console.error("Error depositing funds:", error);
      
      // Provide more specific error messages based on common failure cases
      if (error?.message?.includes("0xfb8f41b2")) {
        // This is likely an ERC20 transfer failure - check balance and allowance
        const balance = Number(usdcBalance) / 1e6;
        const allowance = Number(usdcAllowance) / 1e6;
        const requested = Number(amountInt) / 1e6;
        
        setErrorMessage(`USDC transfer failed (Error: 0xfb8f41b2).\n\nDebug info:\n- Your USDC Balance: ${balance.toFixed(2)} USDC\n- Contract Allowance: ${allowance.toFixed(2)} USDC\n- Requested Amount: ${requested.toFixed(2)} USDC\n\nPlease check:\n1. You have sufficient USDC balance (${balance.toFixed(2)} >= ${requested.toFixed(2)})\n2. You have approved the contract to spend your USDC (${allowance.toFixed(2)} >= ${requested.toFixed(2)})\n3. The amount is valid`);
      } else if (error?.message?.includes("insufficient balance") || error?.message?.includes("ERC20: transfer amount exceeds balance")) {
        setErrorMessage("Insufficient USDC balance. Please check your wallet balance.");
      } else if (error?.message?.includes("ERC20: transfer amount exceeds allowance")) {
        setErrorMessage("Insufficient allowance. Please approve the contract to spend your USDC first.");
      } else if (error?.message?.includes("Amount > 0")) {
        setErrorMessage("Please enter a valid deposit amount greater than 0.");
      } else {
        setErrorMessage(`Deposit failed: ${error?.message || "Unknown error"}`);
      }
    } finally {
      setIsLoading(false);
    }
  };

  const handleFundLoan = async (loanId: number) => {
    // TODO: Implement fund loan functionality when contract is updated
  };

  const handleWithdraw = async () => {
    if (!withdrawAmount || !connectedAddress) return;
    
    const amountInt = parseWithdrawAmount(withdrawAmount);
    if (!amountInt) {
      setErrorMessage("Please enter a valid withdrawal amount greater than 0.");
      return;
    }
    
    setWithdrawLoading(true);
    try {
      await writeContractAsync({
        functionName: "withdrawFunds",
        args: [amountInt],
      });
      
      // Refetch all relevant data after successful withdrawal
      await Promise.all([
        refetchPoolInfo(),
        refetchLenderDeposit(),
        refetchUsdcBalance(),
        refetchUsdcAllowance()
      ]);
      
      setWithdrawAmount("");
      setErrorMessage(null);
    } catch (error: any) {
      console.error("Error withdrawing funds:", error);
      
      // Provide more specific error messages based on common failure cases
      if (error?.message?.includes("Insufficient balance")) {
        setErrorMessage("Insufficient deposited balance. You can only withdraw what you have deposited.");
      } else if (error?.message?.includes("Insufficient liquidity")) {
        setErrorMessage("Insufficient liquidity in the pool. Some funds may be reserved for loans.");
      } else if (error?.message?.includes("Amount > 0")) {
        setErrorMessage("Please enter a valid withdrawal amount greater than 0.");
      } else if (error?.message?.includes("Transfer failed")) {
        setErrorMessage("USDC transfer failed. Please try again.");
      } else {
        setErrorMessage(`Withdrawal failed: ${error?.message || "Unknown error"}`);
      }
    } finally {
      setWithdrawLoading(false);
    }
  };

  const handleClaimYield = async () => {
    // TODO: Implement claim yield functionality when contract is updated
  };

  const handleDebugDeposit = async () => {
    if (!connectedAddress) return;
    
    try {
      console.log("🔍 Debugging deposit for address:", connectedAddress);
      console.log("🔍 Lender deposit from contract:", lenderDeposit);
      console.log("🔍 Pool info:", poolInfo);
      console.log("🔍 USDC balance:", usdcBalance);
      console.log("🔍 USDC allowance:", usdcAllowance);
      
      // Force refetch all data
      await Promise.all([
        refetchPoolInfo(),
        refetchLenderDeposit(),
        refetchUsdcBalance(),
        refetchUsdcAllowance()
      ]);
      
      console.log("🔍 After refetch - Lender deposit:", lenderDeposit);
      console.log("🔍 After refetch - Pool info:", poolInfo);
      console.log("🔍 After refetch - USDC balance:", usdcBalance);
      console.log("🔍 After refetch - USDC allowance:", usdcAllowance);
      
      // Check if user has any USDC
      if (usdcBalance === 0n) {
        console.log("🔍 User has no USDC balance. They need to mint some first.");
        setErrorMessage("You have no USDC balance. Please use the 'Mint 1000 USDC' button to get some test tokens.");
      } else {
        console.log("🔍 User has USDC balance:", formatUSDC(usdcBalance));
      }
      
      // Check allowance
      if (usdcAllowance === 0n) {
        console.log("🔍 User has no allowance. They need to approve USDC spending.");
        setErrorMessage("You haven't approved the contract to spend your USDC. Please use the 'Approve Unlimited' button.");
      } else {
        console.log("🔍 User has allowance:", formatUSDC(usdcAllowance));
      }
      
    } catch (error) {
      console.error("Debug error:", error);
    }
  };

  const handleMintUSDC = async () => {
    if (!connectedAddress) return;
    
    setMintLoading(true);
    try {
      const mintAmount = BigInt(1000 * 1e6); // Mint 1000 USDC
      console.log("🔍 Minting", formatUSDC(mintAmount), "to", connectedAddress);
      
      await writeUSDCAsync({
        functionName: "mint",
        args: [connectedAddress, mintAmount],
      });
      
      // Refetch balance after minting
      await refetchUsdcBalance();
      setErrorMessage(null);
      
      // Auto-approve after minting for convenience
      if (CONTRACT_ADDRESS) {
        console.log("🔍 Auto-approving USDC spending for DecentralizedMicrocredit...");
        try {
          const maxAmount = BigInt("115792089237316195423570985008687907853269984665640564039457584007913129639935");
          await writeUSDCAsync({
            functionName: "approve",
            args: [CONTRACT_ADDRESS, maxAmount],
          });
          await refetchUsdcAllowance();
          console.log("🔍 Auto-approval successful");
        } catch (approvalError) {
          console.log("🔍 Auto-approval failed, user can approve manually:", approvalError);
        }
      }
      
    } catch (error: any) {
      console.error("Mint error:", error);
      setErrorMessage(`Mint failed: ${error?.message || "Unknown error"}`);
    } finally {
      setMintLoading(false);
    }
  };

  const handleAttestation = async () => {
    if (!attestBorrower || !connectedAddress) return;
    try {
      setAttestLoading(true);
      await writeContractAsync({
        functionName: "recordAttestation",
        args: [attestBorrower as `0x${string}`, BigInt(attestWeight * 10000)],
      });
      // Update local list (replace existing weight if borrower already attested)
      setAttestations(prev => {
        const existingIdx = prev.findIndex(a => a.borrower.toLowerCase() === attestBorrower.toLowerCase());
        const weightNum = attestWeight;
        if (existingIdx >= 0) {
          const copy = [...prev];
          copy[existingIdx] = { borrower: attestBorrower as `0x${string}`, weight: weightNum };
          return copy;
        }
        return [...prev, { borrower: attestBorrower as `0x${string}`, weight: weightNum }];
      });
      setAttestBorrower("");
      setAttestWeight(50);
      setShowForm(false);
    } catch (err) {
      console.error("Attestation error", err);
    } finally {
      setAttestLoading(false);
    }
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

          {/* Lender-specific stats will be added once contract exposes them */}

          {/* Pool & Attestations grid */}
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-8 mb-8">

          {/* Your Pool Position */}
          {connectedAddress && (
          <div className="bg-base-100 rounded-lg p-6 shadow-lg w-full">
            <div className="flex justify-between items-center mb-4">
              <h2 className="text-xl font-semibold">Your Pool Position</h2>
              <div className="flex gap-2">
                <button
                  onClick={async () => {
                    await Promise.all([
                      refetchPoolInfo(),
                      refetchLenderDeposit(),
                      refetchUsdcBalance(),
                      refetchUsdcAllowance()
                    ]);
                  }}
                  className="btn btn-sm btn-outline"
                  title="Refresh your position data"
                >
                  🔄 Refresh
                </button>
                <button
                  onClick={handleDebugDeposit}
                  className="btn btn-sm btn-outline btn-warning"
                  title="Debug deposit data"
                >
                  🔍 Debug
                </button>
              </div>
            </div>
            
            {/* Debug panel hidden for cleaner demo; restore if needed */}
            {false && (
              <div className="mb-4 p-3 bg-yellow-50 border border-yellow-200 rounded-lg">
                {/* original debug info here */}
              </div>
            )}
            <div className="grid grid-cols-1 md:grid-cols-5 gap-4 text-center">
              <div>
                <div className="text-2xl font-bold text-blue-500">
                  {lenderDeposit !== undefined ? formatUSDC(lenderDeposit) : "-"}
                </div>
                <div className="text-sm text-gray-600">Your Deposits</div>
              </div>
              <div>
                <div className="text-2xl font-bold text-green-500">
                  <span className="font-medium">{interestEarned !== undefined ? formatUSDC(interestEarned) : "-"}</span>
                </div>
                <div className="text-sm text-gray-600">Interest Earned*</div>
              </div>
              <div>
                <div className="text-2xl font-bold text-purple-500">
                  {loanRatePercent !== undefined ? loanRatePercent + "%" : "-"}
                </div>
                <div className="text-sm text-gray-600">Loan Rate (APR)</div>
              </div>
              <div>
                <div className="text-2xl font-bold text-indigo-500">
                  {poolRatePercent !== undefined ? poolRatePercent + "%" : "-"}
                </div>
                <div className="text-sm text-gray-600">Funding Pool APY</div>
              </div>
              <div>
                <div className="text-2xl font-bold text-orange-500">
                  {totalBalance !== undefined ? formatUSDC(totalBalance) : "-"}
                </div>
                <div className="text-sm text-gray-600">Total (Deposits + Interest)</div>
              </div>
            </div>

            {/* Deposit Funds */}
            <div className="divider my-6"></div>
            <h3 className="text-lg font-semibold mb-3 flex items-center">
              <PlusIcon className="h-5 w-5 mr-2" />
              {lenderDeposit !== undefined && BigInt(lenderDeposit) > 0n ? "Deposit More Funds" : "Deposit Funds"}
            </h3>
            
            {/* Error Message */}
            {errorMessage && (
              <div className="mb-4 p-3 bg-red-50 border border-red-200 rounded-lg">
                <div className="text-sm text-red-800">
                  <div className="flex justify-between items-start">
                    <span className="font-medium">Error:</span>
                    <button 
                      onClick={() => setErrorMessage(null)}
                      className="text-red-600 hover:text-red-800"
                    >
                      ✕
                    </button>
                  </div>
                  <div className="mt-1 whitespace-pre-line">{errorMessage}</div>
                </div>
              </div>
            )}
            
            {/* USDC Balance Info */}
            <div className="mb-4 p-3 bg-blue-50 rounded-lg">
              <div className="text-sm text-blue-800">
                <div className="flex justify-between">
                  <span>USDC Balance:</span>
                  <span className="font-medium">{formatUSDC(usdcBalance)}</span>
                </div>
                <div className="flex justify-between mt-1">
                  <span>Current Allowance:</span>
                  <span className="font-medium">{formatUSDCAllowance(usdcAllowance)}</span>
                </div>
                {(() => {
                  const parsedAmount = parseDepositAmount(depositAmount);
                  return depositAmount && parsedAmount ? (
                    <div className="flex justify-between mt-1">
                      <span>Required Approval:</span>
                      <span className="font-medium">{formatUSDC(parsedAmount)}</span>
                    </div>
                  ) : null;
                })()}
                <div className="flex justify-between mt-2 pt-2 border-t border-blue-200">
                  <span>Need USDC for testing?</span>
                  <button
                    onClick={handleMintUSDC}
                    disabled={mintLoading}
                    className="text-blue-600 hover:text-blue-800 font-medium disabled:text-blue-400"
                  >
                    {mintLoading ? "Minting..." : "Mint 1000 USDC"}
                  </button>
                </div>
              </div>
            </div>
            
            {/* USDC Approval Section */}
            {(() => {
              const parsedAmount = parseDepositAmount(depositAmount);
              return depositAmount && parsedAmount;
            })() && (
              <div className="mb-4 p-3 bg-yellow-50 border border-yellow-200 rounded-lg">
                <div className="text-sm text-yellow-800">
                  <div className="flex justify-between items-center">
                    <span className="font-medium">USDC Approval Required</span>
                    <div>
                      {(() => {
                        const parsedAmount = parseDepositAmount(depositAmount);
                        const isApproved = parsedAmount !== null && (usdcAllowance >= parsedAmount || usdcAllowance >= BigInt(2) ** BigInt(256) - BigInt(1));
                        return (
                          <button
                            onClick={async () => {
                              if (isApproved) return;
                              if (!usdcAddress || !depositAmount) return;
                              const amountInt = parseDepositAmount(depositAmount);
                              if (!amountInt) return;
                              setApprovalLoading(true);
                              try {
                                await writeUSDCAsync({
                                  functionName: "approve",
                                  args: [CONTRACT_ADDRESS, amountInt],
                                });
                                await new Promise(r => setTimeout(r, 3000));
                                await refetchUsdcAllowance();
                              } finally {
                                setApprovalLoading(false);
                              }
                            }}
                            disabled={approvalLoading || !depositAmount || parseDepositAmount(depositAmount) === null || isApproved}
                            className={`${isApproved ? "bg-green-500" : "bg-yellow-500 hover:bg-yellow-600"} text-white font-medium py-2 px-4 rounded transition-colors disabled:bg-green-500`}
                          >
                            {isApproved ? "Approved" : approvalLoading ? "Approving..." : "Approve"}
                          </button>
                        );
                      })()}
                    </div>
                  </div>
                  <div className="mt-2 text-xs">
                    {(() => {
                      const parsedAmount = parseDepositAmount(depositAmount);
                      return parsedAmount === null ? undefined : usdcAllowance < parsedAmount;
                    })()}
                    {usdcAllowance > 0n && (
                      <div className="mt-1">
                        <button
                          onClick={async () => {
                            if (!usdcAddress) return;
                            setApprovalLoading(true);
                            try {
                              await writeUSDCAsync({
                                functionName: "approve",
                                args: [CONTRACT_ADDRESS, 0n],
                              });
                              await new Promise(resolve => setTimeout(resolve, 2000));
                              await refetchUsdcAllowance();
                              setErrorMessage(null);
                            } catch (error: any) {
                              console.error("Revoke approval failed:", error);
                              setErrorMessage(`Revoke approval failed: ${error?.message || "Unknown error"}`);
                            } finally {
                              setApprovalLoading(false);
                            }
                          }}
                          disabled={approvalLoading || !usdcAddress}
                          className="text-red-600 hover:text-red-800 text-xs underline"
                        >
                          Revoke Approval
                        </button>
                      </div>
                    )}
                  </div>
                </div>
              </div>
            )}
            
            <div className="flex flex-col md:flex-row gap-4">
              <input
                type="number"
                value={depositAmount}
                onChange={(e) => setDepositAmount(e.target.value)}
                placeholder="Enter amount in USDC"
                className="flex-1 p-3 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                min="1"
                max={Number(usdcBalance) / 1e6}
              />
              <button
                onClick={handleDeposit}
                disabled={
                  !depositAmount || 
                  !connectedAddress || 
                  isLoading || 
                  approvalLoading || 
                  (() => {
                    const parsedAmount = parseDepositAmount(depositAmount);
                    if (!parsedAmount) return true;
                    return Number(parsedAmount) / 1e6 > Number(usdcBalance) / 1e6 || usdcAllowance < parsedAmount;
                  })()
                }
                className={`font-bold py-3 px-6 rounded-lg transition-colors ${
                  (() => {
                    const parsedAmount = parseDepositAmount(depositAmount);
                    return !!parsedAmount && usdcAllowance < parsedAmount;
                  })() && depositAmount
                    ? "bg-gray-400 cursor-not-allowed"
                    : "bg-blue-500 hover:bg-blue-600 disabled:bg-gray-400 text-white"
                }`}
                title={
                  (() => {
                    const parsedAmount = parseDepositAmount(depositAmount);
                    return !!parsedAmount && usdcAllowance < parsedAmount;
                  })() && depositAmount
                    ? "Please approve USDC spending first"
                    : undefined
                }
              >
                {approvalLoading ? "Approving..." : isLoading ? "Depositing..." : "Deposit"}
              </button>
            </div>

            <p className="text-xs text-gray-500 mt-3">*Interest displayed is a simplified projection based on current pool APR.</p>
            
            {/* Helpful guidance */}
            {(() => {
              const parsedAmount = parseDepositAmount(depositAmount);
              return depositAmount && parsedAmount && usdcAllowance < parsedAmount;
            })() && (
              <div className="mt-3 p-2 bg-blue-50 border border-blue-200 rounded text-xs text-blue-800">
                💡 <strong>Tip:</strong> You need to approve USDC spending before depositing. Use the &ldquo;Approve Unlimited&rdquo; button above for convenience, or &ldquo;Approve Exact&rdquo; for the specific amount.
              </div>
            )}
            
            {/* Withdraw Funds */}
            {lenderDeposit !== undefined && BigInt(lenderDeposit) > 0n && (
              <>
                <div className="divider my-6"></div>
                <h3 className="text-lg font-semibold mb-3 flex items-center">
                  <BanknotesIcon className="h-5 w-5 mr-2" />
                  Withdraw Funds
                </h3>
                <div className="flex flex-col md:flex-row gap-4">
                  <input
                    type="number"
                    value={withdrawAmount}
                    onChange={(e) => setWithdrawAmount(e.target.value)}
                    placeholder="Enter amount to withdraw"
                    className="flex-1 p-3 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                    min="1"
                    max={Number(lenderDeposit) / 1e6}
                  />
                  <button
                    onClick={handleWithdraw}
                    disabled={(() => {
                      if (!withdrawAmount || !connectedAddress || withdrawLoading) return true;
                      const parsedAmount = parseWithdrawAmount(withdrawAmount);
                      if (!parsedAmount) return true;
                      return Number(parsedAmount) / 1e6 > Number(lenderDeposit) / 1e6;
                    })()}
                    className="bg-red-500 hover:bg-red-600 disabled:bg-gray-400 text-white font-bold py-3 px-6 rounded-lg transition-colors"
                  >
                    {withdrawLoading ? "Withdrawing..." : "Withdraw"}
                  </button>
                </div>
              </>
            )}
          </div>
          )}

          {/* My Attestations */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg w-full">
            <h2 className="text-xl font-semibold mb-6 flex items-center">
              <HandThumbUpIcon className="h-6 w-6 mr-2" />
              Your Attestations
            </h2>

            {/* Filter & New Attestation Form */}
            <div className="mb-6 grid grid-cols-1 md:grid-cols-3 gap-4">
              {/* Filter borrowers */}
              <input
                type="text"
                className="input input-bordered w-full md:col-span-2"
                placeholder="Filter by borrower address..."
                value={filterText}
                onChange={e => setFilterText(e.target.value)}
              />

              {/* New attestation button toggles form visibility on small screens */}
              <button
                className="btn btn-primary w-full"
                onClick={() => setShowForm(prev => !prev)}
              >
                {showForm ? "Close" : "New Attestation"}
              </button>
            </div>

            {/* New Attestation Inline Form */}
            {showForm && (
            <div className="space-y-4 mb-8">
              <div>
                <label className="block text-sm font-medium mb-2">Borrower Address</label>
                <AddressInput value={attestBorrower} onChange={setAttestBorrower} placeholder="0x..." />
              </div>
              <div>
                <label className="block text-sm font-medium mb-2">Confidence Level: {attestWeight}%</label>
                <input type="range" min="1" max="100" value={attestWeight} onChange={e=>setAttestWeight(Number(e.target.value))} className="w-full" />
              </div>
              <button onClick={handleAttestation} disabled={!attestBorrower || attestLoading} className="btn btn-primary w-full">
                {attestLoading ? "Submitting..." : "Submit Attestation"}
              </button>
            </div>
            )}

            {/* Attestations Table */}
            <div className="overflow-x-auto">
              <table className="table w-full text-sm">
                <thead>
                  <tr>
                    <th className="px-2 py-3 text-left">Borrower</th>
                    <th className="px-2 py-3 text-left">Weight</th>
                  </tr>
                </thead>
                <tbody>
                  {filteredAttestations.length === 0 && (
                    <tr className="bg-base-200">
                      <td colSpan={2} className="text-center py-6 text-gray-500 italic">No attestations yet</td>
                    </tr>
                  )}
                  {filteredAttestations.map(({ borrower, weight }) => (
                    <tr key={borrower} className="hover:bg-base-200">
                      <td className="px-2 py-2 font-mono break-all"><Address address={borrower as `0x${string}`} /></td>
                      <td className="px-2 py-2">{weight}%</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>

          </div> {/* end grid */}

          {/* Pool Overview moved to Admin page */}

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