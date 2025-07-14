"use client";

import { useState, useMemo, useEffect } from "react";
import type { NextPage } from "next";
import { useAccount } from "wagmi";
import { CogIcon, ShieldCheckIcon } from "@heroicons/react/24/outline";
import { Address, AddressInput } from "~~/components/scaffold-eth";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { formatPercent, formatUSDC } from "~~/utils/format";

const AdminPage: NextPage = () => {
  const { address: connectedAddress } = useAccount();
  const [userAddress, setUserAddress] = useState("");
  const [isLoading, setIsLoading] = useState(false);

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

  // Additional whitelisted admin addresses
  const ADDITIONAL_ADMINS = [
    "0x8b45296027564EF1e472EEa87B4D03BBF9DAD149".toLowerCase(),
    "0xffE03408f9789C0dd867c398C36A2511Bf346600".toLowerCase(),
  ];

  // Permissions
  const isOwner = connectedAddress && owner && connectedAddress.toLowerCase() === owner.toLowerCase();
  const isOracle = oracle && connectedAddress && connectedAddress.toLowerCase() === oracle.toLowerCase();
  const isWhitelisted = connectedAddress ? ADDITIONAL_ADMINS.includes(connectedAddress.toLowerCase()) : false;
  const hasAccess = isOwner || isOracle || isWhitelisted;

  // Credit-score lookup
  const [lookupAddress, setLookupAddress] = useState<string>("");
  const { data: lookupScore } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getPageRankScore",
    args: [lookupAddress as `0x${string}` | undefined],
  });

  // Lender lookup
  const [lenderLookup, setLenderLookup] = useState<string>("");
  const { data: lenderDeposit } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "lenderDeposits",
    args: [lenderLookup as `0x${string}` | undefined],
  });
  const { data: poolInfo } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getPoolInfo",
  });
  const availableFunds = poolInfo ? poolInfo[1] : undefined;
  const lenderCount = poolInfo ? poolInfo[3] : undefined;
  const [withdrawAmount, setWithdrawAmount] = useState("");
  const [withdrawLoading, setWithdrawLoading] = useState(false);

  const handleWithdraw = async () => {
    if (!withdrawAmount || !connectedAddress) return;
    setWithdrawLoading(true);
    try {
      await writeContractAsync({
        functionName: "withdrawFunds",
        args: [BigInt(Math.floor(parseFloat(withdrawAmount) * 1e6))],
      });
      setWithdrawAmount("");
    } catch (error) {
      console.error("Error withdrawing funds:", error);
    } finally {
      setWithdrawLoading(false);
    }
  };

  // Helper numbers
  const lenderDepositNumber = lenderDeposit !== undefined ? Number(lenderDeposit) : 0;
  const availableFundsNumber = availableFunds !== undefined ? Number(availableFunds) : 0;

  // Utilisation stats
  const { data: totalLent } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "totalLentOut",
  });
  const { data: utilCap } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "lendingUtilizationCap",
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
  const { data: borrowerList } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getBorrowers",
  });
  const { data: lenderList } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getLenders",
  });
  const { data: attesterList } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getAttesters",
  });

  /* --------------------------------------------------------------------------
   *  Helper components
   * -----------------------------------------------------------------------*/

  const LenderRow = ({ address, index }: { address: `0x${string}`; index: number }) => {
    const { data: deposit } = useScaffoldReadContract({
      contractName: "DecentralizedMicrocredit",
      functionName: "lenderDeposits",
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
    const PAGE_SIZE = 3;
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

  // ──────────── ATTESTATIONS TABLE ────────────
  const AttestationRows = ({ borrower }: { borrower: `0x${string}` }) => {
    const { data: attests } = useScaffoldReadContract({
      contractName: "DecentralizedMicrocredit",
      functionName: "getBorrowerAttestations",
      args: [borrower],
    });

    if (!attests) return null;
    const list = attests as readonly any[];
    return (
      <>
        {list.map((a, i) => {
          const attesterAddr = (a.attester ?? a[0]) as `0x${string}`;
          const weightVal = (a.weight ?? a[1]) as bigint;
          return (
            <tr key={`${borrower}-${attesterAddr}-${i}`} className="hover text-sm">
              <td>
                <Address address={attesterAddr} />
              </td>
              <td>
                <Address address={borrower} />
              </td>
              <td>{(Number(weightVal) / 1000).toFixed(1)}%</td>
            </tr>
          );
        })}
      </>
    );
  };

  const AttestationsTable = ({ borrowers }: { borrowers?: readonly `0x${string}`[] }) => {
    if (!borrowers || borrowers.length === 0) return null;
    return (
      <div>
        <h3 className="font-medium mb-2">Attestations</h3>
        <div className="overflow-x-auto max-h-96">
          <table className="table w-full">
            <thead>
              <tr>
                <th>Attester</th>
                <th>Attestee</th>
                <th>Strength</th>
              </tr>
            </thead>
            <tbody>
              {borrowers.map(b => (
                <AttestationRows key={b} borrower={b as `0x${string}`} />
              ))}
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
  if (!hasAccess) {
    return (
      <div className="flex items-center justify-center min-h-screen">
        <div className="text-center">
          <ShieldCheckIcon className="h-16 w-16 mx-auto text-red-500 mb-4" />
          <h1 className="text-2xl font-bold text-red-500 mb-2">Access Denied</h1>
          <p className="text-gray-600 mb-4">
            You need to be the contract owner, oracle, or whitelisted to access this page.
          </p>
          <div className="space-y-2 text-sm text-gray-500">
            <div>
              Current Oracle: {oracle ? <Address address={oracle as `0x${string}`} /> : "Loading..."}
            </div>
            <div>
              Contract Owner: {owner ? <Address address={owner as `0x${string}`} /> : "Loading..."}
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
          <div className="flex items-center justify-center mb-8">
            <CogIcon className="h-8 w-8 mr-3" />
            <h1 className="text-3xl font-bold">Admin Panel</h1>
          </div>

          {/* Credit Score Lookup */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Credit Score Lookup</h2>
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mb-4">
              <div>
                <label className="block text-sm font-medium mb-2">Address</label>
                <AddressInput value={lookupAddress} onChange={setLookupAddress} placeholder="0x..." />
              </div>
              <div className="flex items-end text-lg font-bold">
                {lookupScore ? `${(Number(lookupScore) / 1000).toFixed(2)}%` : "-"}
              </div>
            </div>
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

          {/* Lender Management */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Lender Management</h2>
            <div className="mb-4">
              <label className="block text-sm font-medium mb-2">Lender Address Lookup</label>
              <AddressInput value={lenderLookup} onChange={setLenderLookup} placeholder="0x..." />
              <div className="mt-2 text-sm">
                {lenderDeposit !== undefined && lenderDepositNumber > 0 ? (
                  <span>Deposit Balance: {(lenderDepositNumber / 1e6).toLocaleString()} USDC</span>
                ) : (
                  <span>No deposit found for this address.</span>
                )}
              </div>
            </div>
            <div className="mb-4">
              <span className="text-sm">
                Total Lenders: {lenderCount !== undefined ? lenderCount.toString() : "Loading..."}
              </span>
            </div>
            {connectedAddress &&
              lenderLookup.toLowerCase() === connectedAddress.toLowerCase() &&
              lenderDepositNumber > 0 && (
                <div className="mt-4">
                  <label className="block text-sm font-medium mb-2">Withdraw Amount (USDC)</label>
                  <input
                    type="number"
                    value={withdrawAmount}
                    onChange={e => setWithdrawAmount(e.target.value)}
                    min="0.000001"
                    max={Math.min(lenderDepositNumber / 1e6, availableFundsNumber / 1e6)}
                    step="0.000001"
                    className="w-full p-2 border border-gray-300 rounded focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                    placeholder="Enter amount to withdraw"
                  />
                  <button
                    onClick={handleWithdraw}
                    disabled={
                      withdrawLoading ||
                      !withdrawAmount ||
                      Number(withdrawAmount) <= 0 ||
                      Number(withdrawAmount) > lenderDepositNumber / 1e6 ||
                      Number(withdrawAmount) > availableFundsNumber / 1e6
                    }
                    className="w-full bg-blue-500 hover:bg-blue-600 disabled:bg-gray-400 text-white font-bold py-2 px-4 rounded transition-colors mt-2"
                  >
                    {withdrawLoading ? "Withdrawing..." : "Withdraw"}
                  </button>
                </div>
              )}
          </div>

          {/* Overview Stats */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Platform Overview</h2>
            <div className="grid grid-cols-2 md:grid-cols-4 gap-6 text-center">
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
                <div className="text-2xl font-bold text-orange-500">{attesterList ? attesterList.length : "-"}</div>
                <div className="text-sm text-gray-600">Attesters</div>
              </div>
            </div>
          </div>

          {/* Detailed Data */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Detailed Data</h2>
            <div className="space-y-8">
              {/* 🔑 Casts added below fix TS2322 */}
              <LenderTable lenders={lenderList as readonly `0x${string}`[] | undefined} />
              <AttestationsTable borrowers={borrowerList as readonly `0x${string}`[] | undefined} />
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
                    <span>Oracle: {oracle ? "Set" : "Not Set"}</span>
                  </div>
                  <div className="flex items-center space-x-2">
                    <div className="w-2 h-2 bg-green-500 rounded-full"></div>
                    <span>Reputation Engine: Active</span>
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
                      Role: {isOwner ? "Owner" : isOracle ? "Oracle" : isWhitelisted ? "Whitelisted" : "None"}
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
        </div>
      </div>
    </>
  );
};

export default AdminPage;
