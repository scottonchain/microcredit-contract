"use client";

import { useState } from "react";
import { useAccount } from "wagmi";
import {
  createPublicClient,
  http,
  createWalletClient,
  parseUnits,
  toHex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { localhost } from "viem/chains";
import { useScaffoldReadContract } from "~~/hooks/scaffold-eth";
import Link from "next/link";
import { useIsAdmin } from "~~/hooks/useIsAdmin";
import { ANVIL_RPC_URL, CHAIN_ID, MICROCREDIT_ABI, MICROCREDIT_ADDRESS, USDC_ABI, USDC_ADDRESS } from "~~/utils/microcredit";

export default function PopulatePage() {
  const { address: connectedAddress } = useAccount();
  const { admin, loading } = useIsAdmin();
  const hasAccess = !!admin;
  const [status, setStatus] = useState("");
  const [progress, setProgress] = useState(0);
  const [totalSteps, setTotalSteps] = useState(0);
  const [currentStep, setCurrentStep] = useState(0);
  const [numLenders, setNumLenders] = useState(3);
  const [numBorrowers, setNumBorrowers] = useState(25);
  const [includeLenderAttestations, setIncludeLenderAttestations] = useState(true);
  const [attestationProbability, setAttestationProbability] = useState(75); // 75% chance = 25% chance of not backing
  const [nextLoanId, setNextLoanId] = useState(1); // Track the next loan ID to use

  // Seeded random number generator
  const seededRandom = (seed: number) => {
    const x = Math.sin(seed) * 10000;
    return x - Math.floor(x);
  };


  // Use scaffold-eth hooks to read contract data
  const { data: owner } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "owner",
  });

  const { data: oracle } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "oracle",
  });


  async function populate() {
    console.log("Starting populate function");
    console.log("MICROCREDIT_ADDRESS:", MICROCREDIT_ADDRESS);
    console.log("USDC_ADDRESS:", USDC_ADDRESS);

    // TODO: REMOVE THIS
    const FUND_TARGETS = [
    ];
    const publicClient = createPublicClient({ 
      chain: { ...localhost, id: CHAIN_ID }, 
      transport: http(ANVIL_RPC_URL) 
    });

    // Ensure the minter account (private key 0x01...) has enough ETH to pay gas for subsequent mint calls
    const MINTER_PK = toHex(1, { size: 32 }) as `0x${string}`;
    const minterAccount = privateKeyToAccount(MINTER_PK);
    await fetch(ANVIL_RPC_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "anvil_setBalance",
        params: [minterAccount.address, toHex(10n * 10n ** 18n)], // 10 ETH buffer
      }),
    });

    // ─── Create & fund a dummy account for helper transactions ───
    const ADMIN_PK = toHex(0x5000, { size: 32 }) as `0x${string}`; // deterministic but unused key
    const adminAccount = privateKeyToAccount(ADMIN_PK);
    await fetch(ANVIL_RPC_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "anvil_setBalance",
        params: [adminAccount.address, toHex(20n * 10n ** 18n)], // 20 ETH for gas
      }),
    });
    
    if (!MICROCREDIT_ADDRESS || !USDC_ADDRESS) {
      setStatus("❌ Contracts not deployed");
      return;
    }

    setStatus("⏳ Starting population...");
    setProgress(0);
    setCurrentStep(0);
    setTotalSteps(5); // Deposits, Credit lines + backing, (no ranking step), Borrower gas, Loans (request + disburse)

    // Verify contract is deployed by trying to read a simple function
    try {
      console.log("Verifying contract deployment...");
      const owner = await publicClient.readContract({
        address: MICROCREDIT_ADDRESS as `0x${string}`,
        abi: MICROCREDIT_ABI,
        functionName: "owner",
      });
      console.log("Contract owner:", owner);
    } catch (error) {
      console.error("Contract verification failed:", error);
      setStatus("❌ Contract not properly deployed or accessible");
      return;
    }
    const lenders: ReturnType<typeof privateKeyToAccount>[] = [];
    const borrowers: ReturnType<typeof privateKeyToAccount>[] = [];

    for (let i = 0; i < numLenders; i++) {
      const pk = toHex(i + 1, { size: 32 });
      lenders.push(privateKeyToAccount(pk as `0x${string}`));
    }
    for (let j = 0; j < numBorrowers; j++) {
      const pk = toHex(10 + j + 1, { size: 32 });
      borrowers.push(privateKeyToAccount(pk as `0x${string}`));
    }

    // Calculate total deposit amount needed
    const totalDepositNeeded = 400 * numLenders; // $400 * number of lenders
    
    // Generate random deposit amounts that sum to the total
    const generateRandomDeposits = () => {
      const deposits: bigint[] = [];
      let remainingAmount = totalDepositNeeded;
      
      // Ensure one lender gets close to $100
      //const specialLenderIndex = Math.floor(seededRandom(123) * numLenders);
      const specialAmount = 100 + (seededRandom(456) * 20 - 10); // $90-110 range
      const specialDeposit = parseUnits(specialAmount.toFixed(2), 6);
      deposits[0] = specialDeposit;
      remainingAmount -= specialAmount;
      
      // Distribute remaining amount randomly among other lenders
      const remainingLenders = numLenders - 1;
      for (let i = 1; i < numLenders; i++) {
        
        if (i === numLenders - 1) {
          // Last lender gets the remaining amount
          const lastDeposit = parseUnits(remainingAmount.toFixed(2), 6);
          deposits[i] = lastDeposit;
        } else {
          // Random amount between $50 and remaining amount per remaining lender
          const minAmount = 50;
          const maxAmount = remainingAmount / remainingLenders * 2; // Allow some variation
          const randomAmount = minAmount + (seededRandom(i * 789) * (maxAmount - minAmount));
          const deposit = parseUnits(randomAmount.toFixed(2), 6);
          deposits[i] = deposit;
          remainingAmount -= randomAmount;
        }
      }
      
      return deposits;
    };
    
    const lenderDeposits = generateRandomDeposits();
    
    // Each lender gets a 100 USDC credit line (admin override, 100% score) and backs borrowers from it:
    // 80% of the line is split across the borrowers, at 80% or 100% of a share, so the total always
    // fits and 20% is left for lender-to-lender backing.
    const LENDER_CREDIT = 100_000_000n;
    const getRandomBacking = (lenderIndex: number, borrowerCount: number) => {
      const share = (LENDER_CREDIT * 8n) / 10n / BigInt(Math.max(borrowerCount, 1));
      const seed = lenderIndex * 10000 + borrowerCount;
      const amount = seededRandom(seed) > 0.5 ? share : (share * 8n) / 10n;
      return (amount / 10_000n) * 10_000n; // whole cents
    };

    // 1) Deposits
    setCurrentStep(1);
    setStatus("⏳ Processing deposits...");
    for (let i = 0; i < lenders.length; i++) {
      const L = lenders[i];
      const depositAmt = lenderDeposits[i];
      setStatus(`⏳ Processing deposit ${i + 1}/${lenders.length} for ${L.address.slice(0, 6)}... ($${(Number(depositAmt) / 1e6).toFixed(2)})`);
      setProgress((i / lenders.length) * 0.25); // 25% for deposits
      
      try {
        await fetch(ANVIL_RPC_URL, { 
          method: "POST", 
          headers: { "Content-Type": "application/json" }, 
          body: JSON.stringify({ 
            jsonrpc: "2.0", 
            id: 1, 
            method: "anvil_setBalance", 
            params: [L.address, toHex(10n * 10n ** 18n)] 
          }) 
        });

        const usdcConfig = { address: USDC_ADDRESS as `0x${string}`, abi: USDC_ABI! };
        const microConfig = { address: MICROCREDIT_ADDRESS as `0x${string}`, abi: MICROCREDIT_ABI };
        const walletClient = createWalletClient({ 
          chain: { ...localhost, id: CHAIN_ID }, 
          transport: http(ANVIL_RPC_URL), 
          account: L 
        });

        let txHash = await walletClient.writeContract({ 
          ...usdcConfig, 
          functionName: "mint", 
          args: [L.address, depositAmt],
          gas: 5000000n // 5 million gas
        });
        await publicClient.waitForTransactionReceipt({ hash: txHash });
        
        // Small delay between transactions
        await new Promise(resolve => setTimeout(resolve, 100));
        
        txHash = await walletClient.writeContract({ 
          ...usdcConfig, 
          functionName: "approve", 
          args: [MICROCREDIT_ADDRESS, depositAmt],
          gas: 5000000n // 5 million gas
        });
        await publicClient.waitForTransactionReceipt({ hash: txHash });
        
        // Small delay between transactions
        await new Promise(resolve => setTimeout(resolve, 100));
        
        txHash = await walletClient.writeContract({ 
          ...microConfig, 
          functionName: "depositFunds", 
          args: [depositAmt],
          gas: 5000000n // 5 million gas
        });
        await publicClient.waitForTransactionReceipt({ hash: txHash });
        
        // Small delay between lenders
        await new Promise(resolve => setTimeout(resolve, 200));
      } catch (error) {
        console.error(`Failed to process deposit for ${L.address}:`, error);
        setStatus(`❌ Failed to process deposit ${i + 1}/${lenders.length}`);
        throw error;
      }
    }
    setProgress(0.25); // 25% complete after deposits
    setStatus("✅ Deposits complete");

    // 2) Credit lines and backing
    setCurrentStep(2);
    setStatus("⏳ Granting credit lines and recording backing...");
    let attestCount = 0;
    let actualLenderToBorrowerAttestations = 0;
    const lenderToLenderAttestations = includeLenderAttestations ? 1 : 0;
    
    // Lender-to-borrower backing
    // Grant each lender its credit line as the contract owner (Anvil impersonation; local only).
    setStatus("⏳ Granting lenders credit lines...");
    const contractOwner = (await publicClient.readContract({
      address: MICROCREDIT_ADDRESS as `0x${string}`,
      abi: MICROCREDIT_ABI,
      functionName: "owner",
    })) as `0x${string}`;
    const anvilCall = (method: string, params: unknown[]) =>
      fetch(ANVIL_RPC_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
      });
    await anvilCall("anvil_impersonateAccount", [contractOwner]);
    const ownerClient = createWalletClient({
      chain: { ...localhost, id: CHAIN_ID },
      transport: http(ANVIL_RPC_URL),
      account: contractOwner,
    });
    for (const L of lenders) {
      const hash = await ownerClient.writeContract({
        address: MICROCREDIT_ADDRESS as `0x${string}`,
        abi: MICROCREDIT_ABI,
        functionName: "setScoreOverride",
        args: [L.address, 1_000_000n],
      });
      await publicClient.waitForTransactionReceipt({ hash });
    }
    await anvilCall("anvil_stopImpersonatingAccount", [contractOwner]);
    
    for (let lenderIndex = 0; lenderIndex < lenders.length; lenderIndex++) {
      const L = lenders[lenderIndex];
      const walletClient = createWalletClient({ 
        chain: { ...localhost, id: CHAIN_ID }, 
        transport: http(ANVIL_RPC_URL), 
        account: L 
      });
      for (let borrowerIndex = 0; borrowerIndex < borrowers.length; borrowerIndex++) {
        const B = borrowers[borrowerIndex];
        // Apply probability - only back if random number is within the probability range
        // Use seeded random for reproducible results
        const seed = lenderIndex * 1000 + borrowerIndex;
        const randomValue = seededRandom(seed) * 100;
        if (randomValue <= attestationProbability) {
          actualLenderToBorrowerAttestations++;
          attestCount++;
          setStatus(`⏳ Lender ${L.address.slice(0, 6)}... backing borrower ${B.address.slice(0, 6)}... (${attestCount}/${actualLenderToBorrowerAttestations + lenderToLenderAttestations})`);
          setProgress(0.25 + (attestCount / (actualLenderToBorrowerAttestations + lenderToLenderAttestations)) * 0.25); // 25-50% for backing
          
          try {
            const txHash = await walletClient.writeContract({ 
              address: MICROCREDIT_ADDRESS as `0x${string}`, 
              abi: MICROCREDIT_ABI, 
              functionName: "back",
              args: [B.address, getRandomBacking(lenderIndex, borrowers.length)],
              gas: 5000000n // 5 million gas
            });
            await publicClient.waitForTransactionReceipt({ hash: txHash });
            
            // Add a small delay between transactions to prevent overwhelming the chain
            await new Promise(resolve => setTimeout(resolve, 100));
          } catch (error) {
            console.error(`Failed to record backing from ${L.address} to ${B.address}:`, error);
            setStatus(`❌ Failed to record backing ${attestCount}/${actualLenderToBorrowerAttestations + lenderToLenderAttestations}`);
            throw error;
          }
        } else {
          // Skip this backing based on probability
          console.log(`Skipping backing from ${L.address.slice(0, 6)}... to ${B.address.slice(0, 6)}... (probability: ${attestationProbability}%, random: ${randomValue.toFixed(1)})`);
        }
      }
    }
    
    // Lender-to-lender backing (if enabled)
    if (includeLenderAttestations) {
      setStatus("⏳ Recording lender-to-lender backing...");
      
      // Randomly select one lender-to-lender backing
      if (lenders.length >= 2) {
        // Generate two different random indices using seeded random
        let lender1Index, lender2Index;
        do {
          lender1Index = Math.floor(seededRandom(42) * lenders.length); // Use seed 42 for lender selection
          lender2Index = Math.floor(seededRandom(43) * lenders.length); // Use seed 43 for second lender
        } while (lender1Index === lender2Index); // Ensure they're different
        
        const L1 = lenders[lender1Index];
        const L2 = lenders[lender2Index];
        
        const walletClient = createWalletClient({ 
          chain: { ...localhost, id: CHAIN_ID }, 
          transport: http(ANVIL_RPC_URL), 
          account: L1 
        });
        
        attestCount++;
        setStatus(`⏳ Lender ${L1.address.slice(0, 6)}... backing lender ${L2.address.slice(0, 6)}... (${attestCount}/${actualLenderToBorrowerAttestations + 1})`);
        setProgress(0.25 + (attestCount / (actualLenderToBorrowerAttestations + 1)) * 0.25); // 25-50% for backing
        
        try {
                                const txHash = await walletClient.writeContract({ 
            address: MICROCREDIT_ADDRESS as `0x${string}`, 
            abi: MICROCREDIT_ABI, 
            functionName: "back",
            args: [L2.address, 10_000_000n], // 10 USDC from the 20% kept free
            gas: 5000000n // 5 million gas
          });
          await publicClient.waitForTransactionReceipt({ hash: txHash });
          
          // Add a small delay between transactions to prevent overwhelming the chain
          await new Promise(resolve => setTimeout(resolve, 100));
        } catch (error) {
          console.error(`Failed to record backing from ${L1.address} to ${L2.address}:`, error);
          setStatus(`❌ Failed to record backing ${attestCount}/${actualLenderToBorrowerAttestations + 1}`);
          throw error;
        }
      }
    }
    setProgress(0.5); // 50% complete after backing
    setStatus("✅ Credit lines granted and backing recorded");

    // 3) No ranking step: credit comes only from granted lines, dues and backing.
    setCurrentStep(3);
    setProgress(0.75);

  // 4) Give borrowers ETH for gas (backing in step 2 already lists them on the admin page)
  setCurrentStep(4);
  setStatus("⏳ Giving borrowers ETH for gas...");
  setProgress(0.8); // 80% complete after funding borrowers
  
  for (let i = 0; i < borrowers.length; i++) {
    const B = borrowers[i];
    setStatus(`⏳ Giving borrower ${i + 1}/${borrowers.length} (${B.address.slice(0, 6)}...) ETH for gas...`);
    setProgress(0.75 + (i / borrowers.length) * 0.05); // 75-80% for funding borrowers
    
    try {
      // Give borrower some ETH for gas
      await fetch(ANVIL_RPC_URL, { 
        method: "POST", 
        headers: { "Content-Type": "application/json" }, 
        body: JSON.stringify({ 
          jsonrpc: "2.0", 
          id: 1, 
          method: "anvil_setBalance", 
          params: [B.address, toHex(10n * 10n ** 18n)] 
        }) 
      });
      
      // No registration step: back() in step 2 adds borrowers to getBackedBorrowers, which the
      // admin page lists.
      console.log(`✅ Borrower ${B.address} funded with ETH for gas`);
      
    } catch (error) {
      console.error(`Failed to fund borrower ${B.address}:`, error);
      setStatus(`❌ Failed to fund borrower ${i + 1}/${borrowers.length}`);
    }
  }
  setProgress(0.8); // 80% complete after funding borrowers
  setStatus("✅ Borrowers funded");

    // 5) Loan Requests and Disbursements - Borrowers request loans for 80% or 100% of their max amount
  setCurrentStep(5);
  setStatus("⏳ Processing loan requests and disbursements...");
  setProgress(0.85); // 85% complete after loan requests
  
  let loanRequestsCreated = 0;
  
  // Get the contract's maxLoanAmount
  console.log(`Attempting to read maxLoanAmount from contract at ${MICROCREDIT_ADDRESS}`);
  const contractMaxLoanAmount = await publicClient.readContract({
    address: MICROCREDIT_ADDRESS as `0x${string}`,
    abi: MICROCREDIT_ABI,
    functionName: "maxLoanAmount",
  });
  console.log(`Successfully read maxLoanAmount: ${contractMaxLoanAmount}`);
  
  for (let i = 0; i < borrowers.length; i++) {
    const B = borrowers[i];
    
    try {
      // Get borrower's credit score using getCreditScore function
      const creditScore = await publicClient.readContract({
        address: MICROCREDIT_ADDRESS as `0x${string}`,
        abi: MICROCREDIT_ABI,
        functionName: "getCreditScore",
        args: [B.address],
      });
      
      if (creditScore > 0n) {
        // Calculate max allowed amount based on credit score
        // Formula: (maxLoanAmount / SCALE) * creditScore
        // where SCALE = 1e6 and creditScore is in the same scale
        const maxAllowed = (BigInt(contractMaxLoanAmount) * creditScore) / BigInt(1e6);
        
        if (maxAllowed > 0n) {
          // Randomly choose 80% or 100% of max allowed amount
          const use100Percent = seededRandom(1000 + i) > 0.5; // 50% chance for each
          const loanAmount = use100Percent ? maxAllowed : (maxAllowed * BigInt(80)) / BigInt(100);
          
          setStatus(`⏳ Borrower ${B.address.slice(0, 6)}... requesting loan for ${(Number(loanAmount) / 1e6).toFixed(2)} USDC (${use100Percent ? '100%' : '80%'} of max)...`);
          
          const walletClient = createWalletClient({ 
            chain: { ...localhost, id: CHAIN_ID }, 
            transport: http(ANVIL_RPC_URL), 
            account: B 
          });
          
          const loanTxHash = await walletClient.writeContract({ 
            address: MICROCREDIT_ADDRESS as `0x${string}`, 
            abi: MICROCREDIT_ABI, 
            functionName: "requestLoan", 
            args: [loanAmount],
            gas: 5000000n // 5 million gas
          });
          await publicClient.waitForTransactionReceipt({ hash: loanTxHash });
          
          // Use the tracked loan ID for disbursement
          const loanId = BigInt(nextLoanId);
          
          loanRequestsCreated++;
          console.log(`✅ Borrower ${B.address.slice(0, 6)}... requested loan for ${(Number(loanAmount) / 1e6).toFixed(2)} USDC`);
          
          // Disburse the loan immediately after requesting it
          setStatus(`⏳ Disbursing loan ${loanId} for ${B.address.slice(0, 6)}...`);
          try {
            const disburseTxHash = await walletClient.writeContract({ 
              address: MICROCREDIT_ADDRESS as `0x${string}`, 
              abi: MICROCREDIT_ABI, 
              functionName: "disburseLoan", 
              args: [loanId],
              gas: 5000000n // 5 million gas
            });
            await publicClient.waitForTransactionReceipt({ hash: disburseTxHash });
            console.log(`✅ Loan ${loanId} disbursed successfully to ${B.address.slice(0, 6)}...`);
          } catch (disburseError) {
            console.error(`Failed to disburse loan for borrower ${B.address}:`, disburseError);
            // Continue with other borrowers even if disbursement fails
          }
          
          // Increment the loan ID counter for the next loan
          setNextLoanId(nextLoanId + 1);
          
          // Add a small delay between loan requests
          await new Promise(resolve => setTimeout(resolve, 100));
        }
      }
    } catch (error) {
      console.error(`Failed to request loan for borrower ${B.address}:`, error);
      // Continue with other borrowers even if one fails
    }
  }
  
  setProgress(1); // 100% complete
  const lenderToLenderAttestationsCreated = includeLenderAttestations && lenders.length >= 2 ? 1 : 0;
  const totalAttestationsCreated = actualLenderToBorrowerAttestations + lenderToLenderAttestationsCreated;
  const totalDeposited = lenderDeposits.reduce((sum, deposit) => sum + Number(deposit) / 1e6, 0);
  setStatus(`🎉 Population complete! Created ${numLenders} lenders (total deposits: $${totalDeposited.toFixed(2)}), ${numBorrowers} borrowers, ${totalAttestationsCreated} backings (${actualLenderToBorrowerAttestations} lender-to-borrower at ${attestationProbability}% probability${includeLenderAttestations ? `, ${lenderToLenderAttestationsCreated} lender-to-lender` : ''}), and ${loanRequestsCreated} loan requests (all disbursed).`);
  }

  if (loading) return (
    <div className="container mx-auto px-4 py-8">
      <h1 className="text-3xl font-bold mb-8">🛠️ Admin: Populate Test Data</h1>
      <div className="bg-base-200 border border-base-300 rounded-lg p-6 text-gray-600">Checking admin access…</div>
    </div>
  );
  if (!connectedAddress) return <p>🔌 Connect wallet…</p>;
  if (!admin) return (
    <div className="container mx-auto px-4 py-8">
      <h1 className="text-3xl font-bold mb-8">🛠️ Admin: Populate Test Data</h1>
      <div className="bg-red-50 border border-red-200 rounded-lg p-6">
        <h2 className="text-xl font-semibold text-red-800 mb-4">⛔ Access Denied</h2>
        <p className="text-red-700 mb-4">
          You need to be the contract owner, oracle, or a whitelisted admin to access this page.
        </p>
        <div className="bg-gray-100 p-3 rounded-md mb-4">
          <p className="text-sm text-gray-700">
            <strong>Your Address:</strong> {connectedAddress}
          </p>
        </div>
        <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-4">
          <h3 className="text-lg font-semibold text-yellow-800 mb-2">🔍 Debug Information</h3>
          <div className="text-sm text-yellow-700 space-y-1">
            <p><strong>Contract Address:</strong> {MICROCREDIT_ADDRESS || "Not deployed"}</p>
            <p><strong>USDC Address:</strong> {USDC_ADDRESS || "Not deployed"}</p>
            <p><strong>Owner:</strong> {owner || "Loading..."}</p>
            <p><strong>Oracle:</strong> {oracle || "Loading..."}</p>
          </div>
        </div>
      </div>
    </div>
  );

  return (
    <div className="container mx-auto px-4 py-8">
      <h1 className="text-3xl font-bold mb-8">🛠️ Admin: Populate Test Data</h1>
      
      {/* Navigation Links */}
      <div className="flex justify-center mb-6">
        <Link 
          href="/admin" 
          className="btn btn-secondary btn-sm"
        >
          📊 Back to Admin Panel
        </Link>
      </div>
      

      
      {/* Configuration */}
      <div className="bg-blue-50 p-4 rounded-lg mb-6">
        <h3 className="text-lg font-semibold mb-4">⚙️ Configuration</h3>
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div>
            <label htmlFor="numLenders" className="block text-sm font-medium text-gray-700 mb-2">
              Number of Lenders
            </label>
            <select
              id="numLenders"
              value={numLenders}
              onChange={(e) => setNumLenders(Number(e.target.value))}
              className="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500"
            >
              <option value={1}>1</option>
              <option value={2}>2</option>
              <option value={3}>3</option>
              <option value={5}>5</option>
              <option value={10}>10</option>
              <option value={20}>20</option>
            </select>
          </div>
          <div>
            <label htmlFor="numBorrowers" className="block text-sm font-medium text-gray-700 mb-2">
              Number of Borrowers
            </label>
            <select
              id="numBorrowers"
              value={numBorrowers}
              onChange={(e) => setNumBorrowers(Number(e.target.value))}
              className="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500"
            >
              <option value={5}>5</option>
              <option value={10}>10</option>
              <option value={20}>20</option>
              <option value={50}>50</option>
              <option value={100}>100</option>
              <option value={300}>300</option>
            </select>
          </div>
        </div>
        <div className="mt-4">
          <div className="flex items-center">
            <input
              id="includeLenderAttestations"
              type="checkbox"
              checked={includeLenderAttestations}
              onChange={(e) => setIncludeLenderAttestations(e.target.checked)}
              className="h-4 w-4 text-blue-600 focus:ring-blue-500 border-gray-300 rounded"
            />
            <label htmlFor="includeLenderAttestations" className="ml-2 block text-sm text-gray-700">
              Include lender-to-lender backing
            </label>
          </div>
          <p className="text-xs text-gray-600 mt-1">
            When enabled, one random lender backs another with 10 USDC of its credit.
          </p>
        </div>
        <div className="mt-4">
          <label htmlFor="attestationProbability" className="block text-sm font-medium text-gray-700 mb-2">
            Lender-to-Borrower Backing Probability: {attestationProbability}%
          </label>
          <input
            id="attestationProbability"
            type="range"
            min="0"
            max="100"
            value={attestationProbability}
            onChange={(e) => setAttestationProbability(Number(e.target.value))}
            className="w-full h-2 bg-gray-200 rounded-lg appearance-none cursor-pointer"
          />
          <p className="text-xs text-gray-600 mt-1">
            Probability that a lender backs a given borrower. Lower values give fewer, sparser backings.
          </p>
        </div>
        <div className="mt-4 p-3 bg-blue-100 rounded-md">
          <p className="text-sm text-blue-800">
            <strong>Summary:</strong> This will create {numLenders} lenders (each given a full credit line to back from) and {numBorrowers} borrowers, 
            resulting in ~{Math.round((numLenders * numBorrowers * attestationProbability) / 100)} lender-to-borrower backings (at {attestationProbability}% probability)
            {includeLenderAttestations && numLenders >= 2 && `, plus 1 random lender-to-lender backing`}
            {includeLenderAttestations && numLenders < 2 && ` (lender-to-lender backing skipped: needs at least 2 lenders)`}
            , and borrowers will request loans for 80% or 100% of their maximum allowed amount. Total funding pool: ${numLenders * 400}.
          </p>
        </div>
      </div>
      
      {/* Status */}
      {status && (
        <div style={{ marginTop: "1rem" }}>
          <p>{status}</p>
          {totalSteps > 0 && (
            <div style={{ marginTop: "1rem" }}>
              <div style={{
                width: "100%",
                backgroundColor: "#e0e0e0",
                borderRadius: "10px",
                overflow: "hidden",
                marginBottom: "0.5rem"
              }}>
                <div style={{
                  width: `${progress * 100}%`,
                  height: "20px",
                  backgroundColor: "#4CAF50",
                  transition: "width 0.3s ease"
                }} />
              </div>
              <div style={{ fontSize: "14px", color: "#666" }}>
                Step {currentStep}/{totalSteps} - {Math.round(progress * 100)}% Complete
              </div>
            </div>
          )}
        </div>
      )}
      
      {/* Action Buttons */}
      <div className="flex gap-4" style={{ marginTop: "1rem" }}>
        <button
          onClick={populate}
          disabled={!admin}
          className="btn btn-primary"
        >
          Populate Test Data
        </button>
        <Link href="/debug" className="btn btn-secondary">
          Debug Contract
        </Link>
      </div>
    </div>
  );


}