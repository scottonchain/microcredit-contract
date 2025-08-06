"use client";

import { useState, useMemo, useEffect } from "react";
import type { NextPage } from "next";
import { useAccount } from "wagmi";
import { CogIcon, ShieldCheckIcon } from "@heroicons/react/24/outline";
import { Address, AddressInput } from "~~/components/scaffold-eth";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { formatPercent, formatUSDC } from "~~/utils/format";
import { createPublicClient, http } from "viem";
import { localhost } from "viem/chains";
import deployedContracts from "~~/contracts/deployedContracts";
import Link from "next/link";

// Constants for contract interaction
const CHAIN_ID = 31337; // Localhost chain ID
const RPC_URL = "http://localhost:8545";

// Read deployed addresses from the contracts file
const deployedContractsData = deployedContracts[31337];
const CONTRACT_ADDRESS = deployedContractsData?.DecentralizedMicrocredit?.address;
const USDC_ADDRESS = deployedContractsData?.MockUSDC?.address;

const publicClient = createPublicClient({
  chain: { ...localhost, id: CHAIN_ID },
  transport: http(RPC_URL),
});

const AdminPage: NextPage = () => {
  const { address: connectedAddress } = useAccount();
  const [userAddress, setUserAddress] = useState("");
  const [isLoading, setIsLoading] = useState(false);

  // Debug logging for contract addresses
  console.log("Debug - deployedContractsData:", deployedContractsData);
  console.log("Debug - USDC_ADDRESS:", USDC_ADDRESS);
  console.log("Debug - CONTRACT_ADDRESS:", CONTRACT_ADDRESS);

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
  
  // PageRank computation state
  const [pageRankLoading, setPageRankLoading] = useState(false);
  const [pageRankResult, setPageRankResult] = useState<string>("");

  // Additional whitelisted admin addresses
  const ADDITIONAL_ADMINS = [
    "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf".toLowerCase(), // Anvil deployer
    "0xef4b3cbca9f0a6b4b80e57a12a19e7ef1124f754", // Dummy admin
    "0xE51a60126dF85801D4C76bDAf58D6F9E81Cc26cA".toLowerCase(), // Added per request
    "0xd8FFc0B6bfAAB3828C0D92AeD3412186eBfFA5FC".toLowerCase(), // Added per request
    "0xd7c5a101eE877daAB1a3731cDcF316066dDccf92".toLowerCase(), // Added per request
  ];

  // Permissions
  const isOwner = connectedAddress && owner && connectedAddress.toLowerCase() === owner.toLowerCase();
  const isOracle = oracle && connectedAddress && connectedAddress.toLowerCase() === oracle.toLowerCase();
  const isWhitelisted = connectedAddress ? ADDITIONAL_ADMINS.includes(connectedAddress.toLowerCase()) : false;
  const hasAccess = isOwner || isOracle || isWhitelisted;

  // Pool info for overview stats
  const { data: poolInfo, refetch: refetchPoolInfo } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getPoolInfo",
  });
  const availableFunds = poolInfo ? poolInfo[1] : undefined;
  const lenderCount = poolInfo ? poolInfo[3] : undefined;

  const handleComputePageRank = async () => {
    setPageRankLoading(true);
    setPageRankResult("");
    try {
      console.log("🔄 Starting PageRank computation process...");
      setPageRankResult("🔄 Starting PageRank computation process...");
      
      // Log current state before clearing
      console.log("📊 Current PageRank nodes:", pageRankData?.[0]?.length || 0);
      console.log("📊 Current PageRank scores:", pageRankData?.[1]?.length || 0);
      
      // Skip clearing PageRank state to avoid gas issues
      console.log("⚠️ Skipping PageRank state clearing (gas optimization)...");
      setPageRankResult("⚠️ Skipping PageRank state clearing (gas optimization)...");
      console.log("✅ Proceeding directly to PageRank computation");
      setPageRankResult("✅ Proceeding directly to PageRank computation...");
      
      // Then compute PageRank with detailed logging
      console.log("🚀 Starting PageRank computation...");
      setPageRankResult("🚀 Starting PageRank computation (this may take a while)...");
      
      const result = await writeContractAsync({
        functionName: "computePageRank",
      });
      
      console.log("✅ PageRank computation completed successfully!");
      console.log("📈 Iterations completed:", result);
      setPageRankResult(`✅ PageRank computed successfully! Iterations: ${result}`);
      
    } catch (error) {
      console.error("❌ Error computing PageRank:", error);
      
      // Check if it's a gas limit error
      const errorMessage = (error as Error).message;
      if (errorMessage.includes("gas") || errorMessage.includes("Gas") || errorMessage.includes("out of gas")) {
        setPageRankResult(`❌ Gas Limit Error: ${errorMessage}. Try reducing the number of nodes or increasing gas limit.`);
      } else if (errorMessage.includes("execution reverted")) {
        setPageRankResult(`❌ Execution Reverted: ${errorMessage}. Check contract state and try again.`);
      } else {
        setPageRankResult(`❌ Error: ${errorMessage}`);
      }
    } finally {
      setPageRankLoading(false);
    }
  };

  const handleClearPageRank = async () => {
    setPageRankLoading(true);
    setPageRankResult("");
    try {
      console.log("🧹 Attempting to clear PageRank state...");
      setPageRankResult("🧹 Attempting to clear PageRank state...");
      
      await writeContractAsync({
        functionName: "clearPageRankState",
      });
      
      console.log("✅ PageRank state cleared successfully!");
      setPageRankResult("✅ PageRank state cleared successfully!");
    } catch (error) {
      console.error("❌ Error clearing PageRank:", error);
      const errorMessage = (error as Error).message;
      
      if (errorMessage.includes("OutOfGas")) {
        setPageRankResult("❌ Gas Limit Error: Too many nodes to clear. Try computing PageRank directly without clearing.");
      } else {
        setPageRankResult(`❌ Error: ${errorMessage}`);
      }
    } finally {
      setPageRankLoading(false);
    }
  };



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
    contractName: "DecentralizedMicrocredit",
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
  const { data: pageRankData } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getAllPageRankScores",
  });
  

  
  // Extract borrowers from PageRank nodes (addresses that have received attestations)
  const borrowerList = pageRankData ? pageRankData[0] : undefined;
  const { data: lenderList } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getLenders",
  });
  
  // Calculate total attestations by summing up attestations for all borrowers
  const totalAttestations = useMemo(() => {
    if (!borrowerList) return 0;
    // This is a rough estimate - in a real implementation, you'd want to fetch all attestations
    // For now, we'll assume each borrower has attestations from each lender
    return borrowerList.length * (lenderList?.length || 0);
  }, [borrowerList, lenderList]);
  
  // Check if PageRank has been computed (any non-zero scores)
  const hasPageRankScores = useMemo(() => {
    if (!pageRankData || !pageRankData[1]) return false;
    return pageRankData[1].some(score => score > 0n);
  }, [pageRankData]);
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
              address: CONTRACT_ADDRESS as `0x${string}`,
              abi: deployedContractsData.DecentralizedMicrocredit.abi,
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

    const { data: pageRankScore } = useScaffoldReadContract({
      contractName: "DecentralizedMicrocredit",
      functionName: "getPageRankScore",
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
        <td>
          {pageRankScore ? `${(Number(pageRankScore) / 1000).toFixed(2)}%` : "-"}
        </td>
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
                <th>PageRank</th>
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

  // ──────────── ATTESTATIONS TABLE ────────────
  const AttestationsTable = ({ borrowers }: { borrowers?: readonly `0x${string}`[] }) => {
    const [filter, setFilter] = useState("");
    const [allAttestations, setAllAttestations] = useState<Array<{
      borrower: `0x${string}`;
      attester: `0x${string}`;
      weight: bigint;
    }>>([]);
    const [isLoading, setIsLoading] = useState(true);

    // Fetch all attestations when component mounts
    useEffect(() => {
      const fetchAllAttestations = async () => {
        if (!borrowers || borrowers.length === 0) {
          setAllAttestations([]);
          setIsLoading(false);
          return;
        }

        const attestations: Array<{
          borrower: `0x${string}`;
          attester: `0x${string}`;
          weight: bigint;
        }> = [];

        // Fetch attestations for each borrower
        for (const borrower of borrowers) {
          try {
            console.log(`Fetching attestations for borrower: ${borrower}`);
            const attests = await publicClient.readContract({
              address: CONTRACT_ADDRESS as `0x${string}`,
              abi: deployedContractsData.DecentralizedMicrocredit.abi,
              functionName: "getBorrowerAttestations",
              args: [borrower],
            });

            console.log(`Attestations for ${borrower}:`, attests);
            
            if (attests && Array.isArray(attests)) {
              const list = attests as readonly any[];
              list.forEach((a) => {
                const attesterAddr = (a.attester ?? a[0]) as `0x${string}`;
                const weightVal = (a.weight ?? a[1]) as bigint;
                attestations.push({
                  borrower,
                  attester: attesterAddr,
                  weight: weightVal,
                });
              });
            }
          } catch (error) {
            console.error(`Failed to fetch attestations for borrower ${borrower}:`, error);
            // Continue with other borrowers even if one fails
          }
        }

        setAllAttestations(attestations);
        setIsLoading(false);
      };

      fetchAllAttestations();
    }, [borrowers]);

    // Filter attestations based on search text
    const filteredAttestations = useMemo(() => {
      if (!filter) return allAttestations;
      
      const lowerFilter = filter.toLowerCase();
      return allAttestations.filter(att => 
        att.borrower.toLowerCase().includes(lowerFilter) ||
        att.attester.toLowerCase().includes(lowerFilter)
      );
    }, [allAttestations, filter]);

    if (!borrowers || borrowers.length === 0) return null;

    return (
      <div>
        <h3 className="font-medium mb-2">Attestations</h3>
        <div className="mb-4">
          <input
            type="text"
            placeholder="Filter by borrower or attester address"
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
                <th>Attester</th>
                <th>Strength</th>
              </tr>
            </thead>
            <tbody>
              {isLoading ? (
                <tr>
                  <td colSpan={3} className="text-center text-gray-500 py-4">
                    Loading attestations...
                  </td>
                </tr>
              ) : filteredAttestations.length === 0 ? (
                <tr>
                  <td colSpan={3} className="text-center text-gray-500 py-4">
                    {filter ? 'No attestations match your filter' : 'No attestations found'}
                  </td>
                </tr>
              ) : (
                filteredAttestations.map((att, index) => (
                  <tr key={`${att.borrower}-${att.attester}-${index}`} className="hover text-sm">
                    <td>
                      <Address address={att.borrower} />
                    </td>
                    <td>
                      <Address address={att.attester} />
                    </td>
                    <td>{(Number(att.weight) / 10000).toFixed(1)}%</td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
        {filteredAttestations.length > 0 && (
          <div className="mt-2 text-sm text-gray-600">
            Showing {filteredAttestations.length} of {allAttestations.length} attestations
            {filter && ` (filtered by "${filter}")`}
          </div>
        )}
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
          <div className="grid grid-cols-1 md:grid-cols-3 gap-6 mb-8">
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
          </div>

          {/* Navigation Links */}
          <div className="flex justify-center mb-6">
            <Link 
              href="/populate_test_data" 
              className="btn btn-primary btn-sm"
            >
              🛠️ Populate Test Data
            </Link>

          </div>

          {/* PageRank Computation - Moved to top */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">PageRank Computation</h2>
            <p className="text-sm text-gray-600 mb-4">
              Compute PageRank scores for all users. This is required for credit scores to work properly.
            </p>
            <div className="text-sm mb-4">
              <span className={`inline-flex items-center px-2 py-1 rounded-full text-xs font-medium ${
                hasPageRankScores ? 'bg-green-100 text-green-800' : 'bg-red-100 text-red-800'
              }`}>
                PageRank Status: {hasPageRankScores ? 'Computed' : 'Not Computed'}
              </span>
              {pageRankData && (
                <span className="ml-2 text-gray-600">
                  ({pageRankData[0]?.length || 0} nodes)
                </span>
              )}
            </div>
            <button
              onClick={handleComputePageRank}
              disabled={pageRankLoading}
              className="bg-blue-500 hover:bg-blue-600 disabled:bg-gray-400 text-white font-bold py-2 px-4 rounded transition-colors"
            >
              {pageRankLoading ? "Computing PageRank..." : "Compute PageRank"}
            </button>
            {pageRankResult && (
              <div className="mt-2 text-sm">
                <span className={pageRankResult.includes("Error") ? "text-red-500" : "text-green-500"}>
                  {pageRankResult}
                </span>
              </div>
            )}
            <div className="mt-2 text-sm text-gray-600">
              <p>💡 <strong>Debug Info:</strong> Open browser console (F12) to see detailed logs during PageRank computation.</p>
              <p>⚠️ <strong>Gas Optimization:</strong> PageRank computation now skips clearing to avoid gas limits.</p>
              <p>🔧 <strong>Current State:</strong> {pageRankData?.[0]?.length || 0} nodes, {pageRankData?.[1]?.filter(score => score > 0n).length || 0} with scores</p>
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
                <div className="text-2xl font-bold text-orange-500">{attesterList ? attesterList.length : "-"}</div>
                <div className="text-sm text-gray-600">Attesters</div>
              </div>
              <div>
                <div className="text-2xl font-bold text-red-500">{totalAttestations}</div>
                <div className="text-sm text-gray-600">Attestations</div>
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
                <p className="text-sm text-purple-600 mt-1">Projected lender yield</p>
              </div>
            </div>
            <div className="mt-4 p-3 bg-gray-100 rounded-md">
              <p className="text-sm text-gray-700">
                <strong>Note:</strong> EFFR should be updated to reflect current market conditions (currently 4.33%). 
                Risk premium is set to 5% for platform sustainability.
              </p>
            </div>
          </div>

          {/* Detailed Data */}
          <div className="bg-base-100 rounded-lg p-6 shadow-lg mb-8">
            <h2 className="text-xl font-semibold mb-4">Detailed Data</h2>
            <div className="space-y-8">
              {/* 🔑 Casts added below fix TS2322 */}
              <LenderTable lenders={lenderList as readonly `0x${string}`[] | undefined} />
              <BorrowerTable borrowers={borrowerList as readonly `0x${string}`[] | undefined} />
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
                    <span>Oracle: {oracle ? 'Set' : 'Not Set'}</span>
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
                    <span>Attester Count: {attesterList ? attesterList.length : "-"}</span>
                  </div>
                  <div className="flex items-center space-x-2">
                    <div
                      className={`w-2 h-2 rounded-full ${
                        utilisationPct < capPct * 0.9 ? "bg-green-500" : "bg-yellow-500"
                      }`}
                    ></div>
                    <span>Attestation Count: {totalAttestations}</span>
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
              <li><Link href="/borrow">Borrower Portal</Link></li>
              <li><Link href="/scores">Credit Scores</Link></li>
              <li><Link href="/admin">Admin Panel</Link></li>
              <li><Link href="/populate_test_data">Populate Test Data</Link></li>

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