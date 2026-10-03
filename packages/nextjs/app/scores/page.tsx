"use client";

import { useState } from "react";
import type { NextPage } from "next";
import { useAccount } from "wagmi";
import { ChartBarIcon } from "@heroicons/react/24/outline";
import { Address, AddressInput } from "~~/components/scaffold-eth";
import { useScaffoldReadContract } from "~~/hooks/scaffold-eth";
import { formatUSDC } from "~~/utils/format";

/**
 * An account's own (granted) credit and total limit including backing received. Own credit is the
 * issued line (score x max loan) plus dues (the share of interest paid into the first-loss reserve), less defaults
 * charged to it as a backer; 0 after a default of its own.
 */
const CreditFigures = ({ account }: { account?: string }) => {
  const who = account as `0x${string}` | undefined;
  const { data: granted } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "grantedCredit",
    args: [who],
  });
  const { data: borrowLimit } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getBorrowLimit",
    args: [who],
  });
  const { data: score } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getCreditScore",
    args: [who],
  });
  const { data: maxLoanAmount } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "maxLoanAmount",
  });
  const { data: duesPaid } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "duesPaid",
    args: [who],
  });
  const { data: creditLoss } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "creditLoss",
    args: [who],
  });
  const { data: defaults } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "defaultedLoans",
    args: [who],
  });
  const issuedLine =
    score !== undefined && maxLoanAmount !== undefined ? (maxLoanAmount * score) / 1_000_000n : undefined;
  return (
    <>
      <div className="text-center">
        <div className="text-2xl font-bold text-blue-500">{granted !== undefined ? formatUSDC(granted) : "-"}</div>
        <div className="text-sm text-gray-600">Own Credit</div>
        <div className="text-xs text-gray-500 mt-2 space-y-0.5">
          <div>Issued line: {issuedLine !== undefined ? formatUSDC(issuedLine) : "-"}</div>
          <div>Earned from interest paid into the reserve: {duesPaid !== undefined ? formatUSDC(duesPaid) : "-"}</div>
          {creditLoss !== undefined && creditLoss > 0n && (
            <div>Charged for defaults of people backed: {formatUSDC(creditLoss)}</div>
          )}
          {defaults !== undefined && defaults > 0n && (
            <div className="text-red-500">Defaulted on a loan: own credit is 0</div>
          )}
        </div>
      </div>
      <div className="text-center">
        <div className="text-2xl font-bold text-green-500">
          {borrowLimit !== undefined ? formatUSDC(borrowLimit[0]) : "-"}
        </div>
        <div className="text-sm text-gray-600">Credit Limit (own + backing)</div>
      </div>
    </>
  );
};

/** Who backs `account`, and with how much stake and credit. */
const BackersList = ({ account }: { account: string }) => {
  const { data: backings } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getBackings",
    args: [account as `0x${string}`],
  });
  const active = (backings ?? []).filter(b => b.secured + b.unsecured > 0n);
  if (active.length === 0) return <div className="text-center text-gray-500 py-4">No one backs this address yet</div>;
  return (
    <>
      {active.map(b => (
        <div key={b.backer} className="flex items-center justify-between bg-base-200 rounded p-2">
          <Address address={b.backer} />
          <span className="text-sm">
            {formatUSDC(b.secured + b.unsecured)}
            {b.secured > 0n ? ` (${formatUSDC(b.secured)} staked)` : ""}
          </span>
        </div>
      ))}
    </>
  );
};

const ScoresPage: NextPage = () => {
  const { address: connectedAddress } = useAccount();
  const [searchAddress, setSearchAddress] = useState("");
  const [selectedAddress, setSelectedAddress] = useState<string | null>(null);

  // Fetch credit score for connected user (respects admin overrides)
  const { data: userCreditScore } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getCreditScore",
    args: [connectedAddress],
  });

  // Credit score for searched address
  const { data: searchedCreditScore } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getCreditScore",
    args: [selectedAddress as `0x${string}` | undefined],
  });

  const toPercent = (score: bigint | undefined) => Number(score ?? 0) / 10000; // SCALE=1e6 => /10000 -> percent

  const getCreditScoreColor = (score: number) => {
    if (score < 30) return "text-red-500";
    if (score < 50) return "text-orange-500";
    if (score < 70) return "text-yellow-500";
    if (score < 90) return "text-blue-500";
    return "text-green-500";
  };

  const getCreditScoreLabel = (score: number) => {
    if (score < 30) return "Poor";
    if (score < 50) return "Fair";
    if (score < 70) return "Good";
    if (score < 90) return "Very Good";
    return "Excellent";
  };

  const getCreditScoreDescription = (score: number) => {
    if (score < 30) return "Limited credit history or poor repayment record";
    if (score < 50) return "Some credit history but room for improvement";
    if (score < 70) return "Good credit standing with reliable repayment history";
    if (score < 90) return "Very good credit with excellent repayment record";
    return "Exceptional credit with outstanding repayment history";
  };

  const handleSearch = () => {
    if (searchAddress) {
      setSelectedAddress(searchAddress);
    }
  };

  return (
    <>
      <div className="flex items-center flex-col grow pt-10">
        <div className="px-5 w-full max-w-6xl">
          <div className="flex items-center justify-center mb-8">
            <ChartBarIcon className="h-8 w-8 mr-3" />
            <h1 className="text-3xl font-bold">Credit Scores</h1>
          </div>

          {/* Search Section */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Search Credit Scores</h2>
            <div className="flex gap-4">
              <div className="flex-1">
                <AddressInput
                  value={searchAddress}
                  onChange={setSearchAddress}
                  placeholder="Enter address to search"
                />
              </div>
              <button
                onClick={handleSearch}
                disabled={!searchAddress}
                className="bg-blue-500 hover:bg-blue-600 disabled:bg-gray-400 text-white font-bold py-3 px-6 rounded-lg transition-colors"
              >
                Search
              </button>
            </div>
          </div>

          {/* Your Credit Score */}
          {connectedAddress && (
            <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
              <h2 className="text-xl font-semibold mb-4">Your Credit Profile</h2>
              <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
                <div className="text-center">
                  <div className={`text-5xl font-bold ${getCreditScoreColor(toPercent(userCreditScore))}`}>
                    {toPercent(userCreditScore).toFixed(2)}%
                  </div>
                  <div className="text-sm text-gray-600">Credit Score</div>
                  <div className="text-lg font-medium mt-1">
                    {getCreditScoreLabel(toPercent(userCreditScore))}
                  </div>
                </div>
                <CreditFigures account={connectedAddress} />
              </div>
              
              <div className="mt-6">
                <h3 className="font-medium mb-2">Score Description</h3>
                <p className="text-gray-600">
                  {getCreditScoreDescription(toPercent(userCreditScore))}
                </p>
              </div>
            </div>
          )}

          {/* Searched Address Credit Score */}
          {selectedAddress && (
            <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
              <h2 className="text-xl font-semibold mb-4">Credit Score for Address</h2>
              <div className="mb-4">
                <Address address={selectedAddress as `0x${string}`} />
              </div>
              
              <div className="grid grid-cols-1 md:grid-cols-3 gap-6 mb-6">
                <div className="text-center">
                  <div className={`text-5xl font-bold ${getCreditScoreColor(toPercent(searchedCreditScore))}`}>
                    {toPercent(searchedCreditScore).toFixed(2)}%
                  </div>
                  <div className="text-sm text-gray-600">Credit Score</div>
                  <div className="text-lg font-medium mt-1">
                    {getCreditScoreLabel(toPercent(searchedCreditScore))}
                  </div>
                </div>
                <CreditFigures account={selectedAddress ?? undefined} />
              </div>

              <div>
                <h3 className="font-medium mb-3">Backers</h3>
                <div className="space-y-2">
                  <BackersList account={selectedAddress} />
                </div>
              </div>
            </div>
          )}

          {/* Credit Score Ranges */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Credit Score Ranges</h2>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
              <div>
                <h3 className="font-medium mb-3">Score Categories</h3>
                <div className="space-y-3">
                  <div className="flex items-center justify-between p-3 bg-green-50 rounded">
                    <div>
                      <div className="font-medium text-green-800">Excellent (90-100%)</div>
                      <div className="text-sm text-green-600">A line of 90 to 100% of the maximum loan</div>
                    </div>
                    <div className="text-2xl font-bold text-green-500">90-100%</div>
                  </div>
                  <div className="flex items-center justify-between p-3 bg-blue-50 rounded">
                    <div>
                      <div className="font-medium text-blue-800">Very Good (70-89%)</div>
                      <div className="text-sm text-blue-600">A line of 70 to 89% of the maximum loan</div>
                    </div>
                    <div className="text-2xl font-bold text-blue-500">70-89%</div>
                  </div>
                  <div className="flex items-center justify-between p-3 bg-yellow-50 rounded">
                    <div>
                      <div className="font-medium text-yellow-800">Good (50-69%)</div>
                      <div className="text-sm text-yellow-600">A line of 50 to 69% of the maximum loan</div>
                    </div>
                    <div className="text-2xl font-bold text-yellow-500">50-69%</div>
                  </div>
                  <div className="flex items-center justify-between p-3 bg-orange-50 rounded">
                    <div>
                      <div className="font-medium text-orange-800">Fair (30-49%)</div>
                      <div className="text-sm text-orange-600">A line of 30 to 49% of the maximum loan</div>
                    </div>
                    <div className="text-2xl font-bold text-orange-500">30-49%</div>
                  </div>
                  <div className="flex items-center justify-between p-3 bg-red-50 rounded">
                    <div>
                      <div className="font-medium text-red-800">Poor (0-29%)</div>
                      <div className="text-sm text-red-600">A line of up to 29% of the maximum loan</div>
                    </div>
                    <div className="text-2xl font-bold text-red-500">0-29%</div>
                  </div>
                </div>
              </div>
              
              <div>
                <h3 className="font-medium mb-3">How Credit Works</h3>
                <div className="space-y-4">
                  <div className="flex items-start space-x-3">
                    <div className="bg-blue-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                      1
                    </div>
                    <div>
                      <h4 className="font-medium">Your Own Credit</h4>
                      <p className="text-gray-600">Your issued line (your score, set by an institution or the credit oracle, times the maximum loan) plus the share of your interest that went into the first-loss reserve</p>
                    </div>
                  </div>
                  <div className="flex items-start space-x-3">
                    <div className="bg-blue-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                      2
                    </div>
                    <div>
                      <h4 className="font-medium">Backing</h4>
                      <p className="text-gray-600">People with credit can back you from their own: their limit falls by exactly what yours gains</p>
                    </div>
                  </div>
                  <div className="flex items-start space-x-3">
                    <div className="bg-blue-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                      3
                    </div>
                    <div>
                      <h4 className="font-medium">Stake</h4>
                      <p className="text-gray-600">Anyone can stake USDC to back someone with money instead of credit</p>
                    </div>
                  </div>
                  <div className="flex items-start space-x-3">
                    <div className="bg-blue-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                      4
                    </div>
                    <div>
                      <h4 className="font-medium">Defaults</h4>
                      <p className="text-gray-600">Backers pay first: staked USDC is slashed and committed credit is lost, and the borrower cannot borrow again</p>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>

          {/* Tips for Improving Credit Score */}
          <div className="bg-base-300 rounded-lg p-6">
            <h2 className="text-xl font-semibold mb-4">Growing Your Credit</h2>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
              <div className="space-y-4">
                <div className="flex items-start space-x-3">
                  <div className="bg-green-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                    1
                  </div>
                  <div>
                    <h3 className="font-medium">Ask to Be Backed</h3>
                    <p className="text-gray-600">Share your backing link with people who know you and have credit</p>
                  </div>
                </div>
                <div className="flex items-start space-x-3">
                  <div className="bg-green-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                    2
                  </div>
                  <div>
                    <h3 className="font-medium">Repay Loans on Time</h3>
                    <p className="text-gray-600">The reserve share of the interest you pay adds to your own credit, and institutions look at your repayment history when setting your line</p>
                  </div>
                </div>
              </div>
              <div className="space-y-4">
                <div className="flex items-start space-x-3">
                  <div className="bg-green-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                    3
                  </div>
                  <div>
                    <h3 className="font-medium">Keep Your Backers Whole</h3>
                    <p className="text-gray-600">Your backers stand behind you; repaying protects their credit and stake</p>
                  </div>
                </div>
                <div className="flex items-start space-x-3">
                  <div className="bg-green-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-sm font-bold mt-0.5">
                    4
                  </div>
                  <div>
                    <h3 className="font-medium">Back Carefully</h3>
                    <p className="text-gray-600">Back only people you trust: a default costs you the credit or stake you committed</p>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </>
  );
};

export default ScoresPage; 