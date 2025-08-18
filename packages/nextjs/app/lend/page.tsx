"use client";

import { useState, useEffect, useMemo } from "react";
// Attestation flow moved to /attest; no need for search params here
import type { NextPage } from "next";
import { useAccount, useSignTypedData } from "wagmi";
import { toast } from "react-hot-toast";
import { formatUSDC, getCreditScoreColor } from "~~/utils/format";
import { BanknotesIcon, PlusIcon, EyeIcon } from "@heroicons/react/24/outline";
import { Address } from "~~/components/scaffold-eth";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import HowItWorks from "~~/components/HowItWorks";
// removed parseEther import because USDC uses 6 decimals
// import { AddressInput } from "~~/components/scaffold-eth";
import deployedContracts from "~~/contracts/deployedContracts";
import { createPublicClient, http } from "viem";
import { localhost } from "viem/chains";
import { MICRO_DOMAIN, TYPES, USDC_PERMIT_DOMAIN, splitSignature, roundDownToCent } from "../../types/eip712";

const LendPage: NextPage = () => {
  const { address: connectedAddress } = useAccount();
  // Default deposit amount set to 1000 USDC for convenience; adjust or remove as needed.
  const [depositAmount, setDepositAmount] = useState("1000");
  const [selectedLoanId, setSelectedLoanId] = useState<number | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  // Attestation state removed; see /attest page
  const [usdcBalance, setUsdcBalance] = useState<bigint>(0n);
  // Allowance no longer needed in permit-only flow
  const [withdrawAmount, setWithdrawAmount] = useState("");
  const [withdrawLoading, setWithdrawLoading] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [mintLoading, setMintLoading] = useState(false);

  // Helper function to safely parse deposit amount to BigInt (snap to cent)
  const parseDepositAmount = (amount: string): bigint | null => {
    if (!amount || amount.trim() === "") return null;
    const parsed = parseFloat(amount);
    if (isNaN(parsed) || parsed <= 0) return null;
    const micros = BigInt(Math.floor(parsed * 1e6));
    return roundDownToCent(micros);
  };

  // Helper function to safely parse withdraw amount to BigInt (snap to cent)
  const parseWithdrawAmount = (amount: string): bigint | null => {
    if (!amount || amount.trim() === "") return null;
    const parsed = parseFloat(amount);
    if (isNaN(parsed) || parsed <= 0) return null;
    const micros = BigInt(Math.floor(parsed * 1e6));
    return roundDownToCent(micros);
  };

  // Attestation cache removed

  // Contract hooks
  const { writeContractAsync } = useScaffoldWriteContract({
    contractName: "DecentralizedMicrocredit",
  });

  // USDC contract hooks
  const { data: usdcAddress } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "usdc",
  });

  // Resolve DecentralizedMicrocredit & USDC contract data from deployments
  const CONTRACT_ADDRESS = deployedContracts[31337]?.DecentralizedMicrocredit?.address as `0x${string}`;
  const CONTRACT_ABI = deployedContracts[31337]?.DecentralizedMicrocredit?.abi as any;
  const USDC_ADDRESS_FROM_DEPLOY = deployedContracts[31337]?.MockUSDC?.address as `0x${string}` | undefined;
  const USDC_ABI = deployedContracts[31337]?.MockUSDC?.abi as any;

  const { writeContractAsync: writeUSDCAsync } = useScaffoldWriteContract({
    contractName: "MockUSDC",
  });

  // viem public client
  const CHAIN_ID = 31337;
  const RPC_URL = "http://localhost:8545";
  const publicClient = useMemo(
    () => createPublicClient({ chain: { ...localhost, id: CHAIN_ID }, transport: http(RPC_URL) }),
    []
  );

  // EIP-712 signer
  const { signTypedDataAsync } = useSignTypedData();

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

  // Removed allowance reads for permit-only deposits

  // Update state when data changes
  useEffect(() => {
    if (usdcBalanceData) setUsdcBalance(usdcBalanceData);
  }, [usdcBalanceData]);

  // Attestation prefill and handlers removed

  const handleDeposit = async () => {
    if (!depositAmount || !connectedAddress || !usdcAddress) return;
    
    const amountInt = parseDepositAmount(depositAmount);
    if (!amountInt) {
      setErrorMessage("Please enter a valid deposit amount greater than 0.");
      return;
    }
    
    setIsLoading(true);
    try {
      if (!CONTRACT_ADDRESS || !CONTRACT_ABI) throw new Error("Contract not available");
      const lender = connectedAddress as `0x${string}`;
      const receiver = connectedAddress as `0x${string}`;

      // 1) Build & sign ERC-2612 Permit for USDC (required)
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
      let permitPayload: { value: string; deadline: string; v: number; r: `0x${string}`; s: `0x${string}` } | undefined;
      try {
        const usdcAddr = (usdcAddress || USDC_ADDRESS_FROM_DEPLOY) as `0x${string}` | undefined;
        if (!usdcAddr || !USDC_ABI) throw new Error("Missing USDC config");

        const permitNonce = (await publicClient.readContract({
          address: usdcAddr,
          abi: USDC_ABI,
          functionName: "nonces",
          args: [lender],
        })) as bigint;

        // Try to read token name; fallback to USD Coin
        let tokenName = "USD Coin";
        try {
          tokenName = (await publicClient.readContract({
            address: usdcAddr,
            abi: USDC_ABI,
            functionName: "name",
            args: [],
          })) as string;
        } catch {}

        const permitMsg = {
          owner: lender,
          spender: CONTRACT_ADDRESS,
          value: amountInt,
          nonce: permitNonce,
          deadline,
        } as const;

        const sigPermit = await signTypedDataAsync({
          domain: USDC_PERMIT_DOMAIN(31337, usdcAddr, tokenName) as any,
          types: { Permit: TYPES.Permit } as any,
          primaryType: "Permit",
          message: permitMsg as any,
        });
        const { v, r, s } = splitSignature(sigPermit);
        permitPayload = { value: amountInt.toString(), deadline: deadline.toString(), v, r, s };
      } catch (permitErr) {
        console.error("Permit signing failed", permitErr);
        throw new Error("Permit signature was rejected or failed. Please try again.");
      }

      // 2) Call relayer API with permit-only payload
      const resp = await fetch("/api/meta/deposit", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          chainId: 31337,
          contractAddress: CONTRACT_ADDRESS,
          lender,
          permit: permitPayload,
        }),
      });

      if (!resp.ok) {
        const text = await resp.text();
        throw new Error(text);
      }
      const j = await resp.json();
      console.log("Deposit meta result:", j);

      // Refresh state
      await Promise.all([refetchPoolInfo(), refetchLenderDeposit(), refetchUsdcBalance()]);

      setDepositAmount("");
      setErrorMessage(null);
      toast.success("Deposit submitted via relayer", { position: "top-center" });
    } catch (error: any) {
      console.error("Error depositing funds (meta):", error);
      setErrorMessage(`Deposit failed: ${error?.message || "Unknown error"}`);
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
      if (!CONTRACT_ADDRESS || !CONTRACT_ABI) throw new Error("Contract not available");
      const lender = connectedAddress as `0x${string}`;
      const to = connectedAddress as `0x${string}`;

      const metaNonce = (await publicClient.readContract({
        address: CONTRACT_ADDRESS,
        abi: CONTRACT_ABI,
        functionName: "nonces",
        args: [lender],
      })) as bigint;
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);

      const rq = { lender, amount: amountInt, to, nonce: metaNonce, deadline } as const;
      const sig = await signTypedDataAsync({
        domain: MICRO_DOMAIN(31337, CONTRACT_ADDRESS) as any,
        types: { RequestWithdrawal: TYPES.RequestWithdrawal } as any,
        primaryType: "RequestWithdrawal",
        message: rq as any,
      });

      const resp = await fetch("/api/meta/request-withdrawal", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          chainId: 31337,
          contractAddress: CONTRACT_ADDRESS,
          req: {
            lender,
            amount: amountInt.toString(),
            to,
            nonce: metaNonce.toString(),
            deadline: deadline.toString(),
          },
          signature: sig,
        }),
      });
      if (!resp.ok) throw new Error(await resp.text());
      const j = await resp.json();
      console.log("Withdrawal request meta result:", j);

      await Promise.all([refetchPoolInfo(), refetchLenderDeposit(), refetchUsdcBalance()]);
      setWithdrawAmount("");
      setErrorMessage(null);
      const filled = j?.amountFilledNow ? Number(BigInt(j.amountFilledNow)) / 1e6 : 0;
      if (filled > 0) toast.success(`Filled immediately: ${filled.toFixed(2)} USDC`, { position: "top-center" });
      if (j?.queueId) toast.success(`Queued with id ${j.queueId}`, { position: "top-center" });
    } catch (error: any) {
      console.error("Error withdrawing funds (meta):", error);
      setErrorMessage(`Withdrawal failed: ${error?.message || "Unknown error"}`);
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
      // allowance removed in permit-only flow
      
      // Force refetch all data
      await Promise.all([refetchPoolInfo(), refetchLenderDeposit(), refetchUsdcBalance()]);
      
      console.log("🔍 After refetch - Lender deposit:", lenderDeposit);
      console.log("🔍 After refetch - Pool info:", poolInfo);
      console.log("🔍 After refetch - USDC balance:", usdcBalance);
      // console.log("🔍 After refetch - USDC allowance:", usdcAllowance);
      
      // Check if user has any USDC
      if (usdcBalance === 0n) {
        console.log("🔍 User has no USDC balance. They need to mint some first.");
        setErrorMessage("You have no USDC balance. Please use the 'Mint 1000 USDC' button to get some test tokens.");
      } else {
        console.log("🔍 User has USDC balance:", formatUSDC(usdcBalance));
      }
      
      // Permit-only flow, no allowance needed
      
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
          // no allowance in permit-only flow
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

  // Attestation submit removed

  // imported helpers handle color & formatting


  return (
    <>
      <div className="flex items-center flex-col grow pt-10">
        <div className="px-5 w-full max-w-6xl">
          <div className="flex items-center justify-center mb-8">
            <BanknotesIcon className="h-8 w-8 mr-3" />
            <h1 className="text-3xl font-bold">Lend Funds</h1>
          </div>

          {/* Attestation link context removed; see /attest */}

          

          {/* Pool grid (centered) */}
          <div className="grid grid-cols-1 gap-8 mb-8 justify-center">

          {/* Your Pool Position */}
          {connectedAddress && (
          <div className="bg-base-100 rounded-lg p-6 shadow-lg w-full max-w-3xl mx-auto">
            <div className="flex justify-between items-center mb-4">
              <h2 className="text-xl font-semibold">Your Pool Position</h2>
              <div className="flex gap-2">
                
                



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
                  (() => {
                    const parsedAmount = parseDepositAmount(depositAmount);
                    if (!parsedAmount) return true;
                    return Number(parsedAmount) / 1e6 > Number(usdcBalance) / 1e6;
                  })()
                }
                className="bg-blue-500 hover:bg-blue-600 disabled:bg-gray-400 text-white font-bold py-3 px-6 rounded-lg transition-colors"
              >
                {isLoading ? "Processing..." : "Deposit"}
              </button>
            </div>

            {/* Add a warning message below the deposit input/button if the user does not have enough balance */}
            {(() => {
              const parsedAmount = parseDepositAmount(depositAmount);
              if (!parsedAmount) return null;
              if (Number(parsedAmount) / 1e6 > Number(usdcBalance) / 1e6) {
                return <div className="text-red-500 text-sm mt-1">Insufficient USDC balance.</div>;
              }
              return null;
            })()}

            {/* Caption: one approval, no gas */}
            <p className="text-xs text-gray-500 mt-2">One approval, no gas. We’ll ask you to approve this deposit; our relayer handles the transaction.</p>

            <p className="text-xs text-gray-500 mt-3">*Interest displayed is a simplified projection based on current pool APR.</p>
            

            
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

          {/* Attestations section removed; moved to /attest */}

          </div> {/* end grid */}

          {/* Pool Overview moved to Admin page */}
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