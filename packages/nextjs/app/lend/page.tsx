"use client";

import { useState, useEffect } from "react";
import type { NextPage } from "next";
import { useAccount } from "wagmi";
import { formatUSDC, getCreditScoreColor } from "~~/utils/format";
import { BanknotesIcon, PlusIcon, EyeIcon, HandThumbUpIcon } from "@heroicons/react/24/outline";
import { Address } from "~~/components/scaffold-eth";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import HowItWorks from "~~/components/HowItWorks";
// removed parseEther import because USDC uses 6 decimals
import { AddressInput } from "~~/components/scaffold-eth";

const LendPage: NextPage = () => {
  const { address: connectedAddress } = useAccount();
  const [depositAmount, setDepositAmount] = useState("");
  const [selectedLoanId, setSelectedLoanId] = useState<number | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [attestBorrower, setAttestBorrower] = useState("");
  const [attestWeight, setAttestWeight] = useState<number>(50);
  const [attestLoading, setAttestLoading] = useState(false);
  // Track attestations made by the connected lender (session-level + localStorage cache)
  const [attestations, setAttestations] = useState<{ borrower: `0x${string}`; weight: number }[]>([]);
  const [filterText, setFilterText] = useState("");
  const [showForm, setShowForm] = useState(false);

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

  // ────── Lender-specific data ──────
  const { data: lenderDeposit } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "lenderDeposits",
    args: [connectedAddress as `0x${string}` | undefined],
  });

  const { data: poolApyBp } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getFundingPoolAPY" as any,
  });
  const poolRatePercent = poolApyBp !== undefined ? (Number(poolApyBp) / 100).toFixed(2) : undefined;

  const interestEarned = lenderDeposit !== undefined && poolApyBp !== undefined
    ? (BigInt(lenderDeposit) * BigInt(Number(poolApyBp)) / BigInt(10000))
    : undefined; // simplistic yearly projection

  const totalBalance = lenderDeposit !== undefined && interestEarned !== undefined
    ? lenderDeposit + interestEarned
    : undefined;

  // Remove placeholder arrays and fetch on-chain data
  const { data: poolInfo } = useScaffoldReadContract({
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

  const handleDeposit = async () => {
    if (!depositAmount || !connectedAddress) return;
    
    setIsLoading(true);
    try {
      // Convert USDC (6-decimals) string amount to integer with 6 decimals
      const amountInt = BigInt(Math.floor(parseFloat(depositAmount) * 1e6));
      await writeContractAsync({
        functionName: "depositFunds",
        args: [amountInt],
      });
      setDepositAmount("");
    } catch (error) {
      console.error("Error depositing funds:", error);
    } finally {
      setIsLoading(false);
    }
  };

  const handleFundLoan = async (loanId: number) => {
    // TODO: Implement fund loan functionality when contract is updated
  };

  const handleClaimYield = async () => {
    // TODO: Implement claim yield functionality when contract is updated
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
            <h2 className="text-xl font-semibold mb-4">Your Pool Position</h2>
            <div className="grid grid-cols-1 md:grid-cols-4 gap-4 text-center">
              <div>
                <div className="text-2xl font-bold text-blue-500">
                  {lenderDeposit !== undefined ? formatUSDC(lenderDeposit) : "-"}
                </div>
                <div className="text-sm text-gray-600">Your Deposits</div>
              </div>
              <div>
                <div className="text-2xl font-bold text-green-500">
                  {interestEarned !== undefined ? formatUSDC(interestEarned) : "-"}
                </div>
                <div className="text-sm text-gray-600">Interest Earned*</div>
              </div>
              <div>
                <div className="text-2xl font-bold text-purple-500">
                  {poolRatePercent !== undefined ? poolRatePercent + "%" : "-"}
                </div>
                <div className="text-sm text-gray-600">Pool Rate (APR)</div>
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
            <div className="flex flex-col md:flex-row gap-4">
              <input
                type="number"
                value={depositAmount}
                onChange={(e) => setDepositAmount(e.target.value)}
                placeholder="Enter amount in USDC"
                className="flex-1 p-3 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                min="1"
              />
              <button
                onClick={handleDeposit}
                disabled={!depositAmount || !connectedAddress || isLoading}
                className="bg-blue-500 hover:bg-blue-600 disabled:bg-gray-400 text-white font-bold py-3 px-6 rounded-lg transition-colors"
              >
                {isLoading ? "Depositing..." : "Deposit"}
              </button>
            </div>

            <p className="text-xs text-gray-500 mt-3">*Interest displayed is a simplified projection based on current pool APR.</p>
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

          {/* Pool Overview */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Lending Pool Overview</h2>
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
              <div className="text-center">
                <div className="text-2xl font-bold text-green-500">
                  {totalDeposits !== undefined ? formatUSDC(totalDeposits) : "Loading..."}
                </div>
                <div className="text-sm text-gray-600">Total Deposits</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold text-blue-500">
                  {availableFunds !== undefined ? formatUSDC(availableFunds) : "Loading..."}
                </div>
                <div className="text-sm text-gray-600">Available Funds</div>
              </div>
              <div className="text-center">
                <div className="text-2xl font-bold text-orange-500">
                  {lenderCount !== undefined ? lenderCount.toString() : "Loading..."}
                </div>
                <div className="text-sm text-gray-600">Active Lenders</div>
              </div>
            </div>
          </div>

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