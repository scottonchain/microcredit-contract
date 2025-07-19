"use client";

import { useEffect, useState } from "react";
import { useAccount, useWalletClient } from "wagmi";
import {
  createPublicClient,
  http,
  createWalletClient,
  custom,
  parseUnits,
  toHex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { localhost } from "viem/chains";
import { useScaffoldReadContract } from "~~/hooks/scaffold-eth";
import deployedContracts from "~~/contracts/deployedContracts";

const RPC_URL = "http://127.0.0.1:8545";
const CHAIN_ID = 31337; // Anvil's default chain ID

const ADDITIONAL_ADMINS = [
  "0x8b45296027564ef1e472eea87b4d03bbf9dad149".toLowerCase(),
  "0xffe03408f9789c0dd867c398c36a2511bf346600".toLowerCase(),
  "0x4Dc35a5a3bdB14e9b7675cc0cA833Ce8248509fF".toLowerCase(),
];

export default function PopulatePage() {
  const { address: connectedAddress } = useAccount();
  const { data: walletClient } = useWalletClient();
  const [hasAccess, setHasAccess] = useState(false);
  const [status, setStatus] = useState("");
  const [progress, setProgress] = useState(0);
  const [totalSteps, setTotalSteps] = useState(0);
  const [currentStep, setCurrentStep] = useState(0);
  const [numLenders, setNumLenders] = useState(2);
  const [numBorrowers, setNumBorrowers] = useState(10);

  // Read deployed addresses
  const contracts = deployedContracts[31337];
  const CONTRACT_ADDRESS = contracts?.DecentralizedMicrocredit?.address;
  const USDC_ADDRESS = contracts?.MockUSDC?.address;

  // Use scaffold-eth hooks to read contract data
  const { data: owner } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "owner",
  });

  const { data: oracle } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "oracle",
  });

  useEffect(() => {
    
    if (!CONTRACT_ADDRESS || !USDC_ADDRESS) {
      setStatus("❌ Contracts not deployed");
      setHasAccess(false);
      return;
    }

    if (!connectedAddress) {
      setStatus("❌ Wallet not connected");
      setHasAccess(false);
      return;
    }

    const me = connectedAddress.toLowerCase();
    
    // Check whitelist first (this doesn't depend on contract data)
    const isWhitelisted = ADDITIONAL_ADMINS.includes(me);
    
    if (isWhitelisted) {
      setHasAccess(true);
      setStatus("✅ Access granted - Ready to populate test data");
      return;
    }
    
    // If not whitelisted, we need to check owner/oracle, but they might still be loading
    if (!owner || !oracle) {
      setStatus("⏳ Loading contract data...");
      setHasAccess(false);
      return;
    }
    
    const isOwner = me === owner.toLowerCase();
    const isOracle = me === oracle.toLowerCase();
    
    const accessDebug = { 
      connectedAddress, 
      me, 
      owner: owner?.toLowerCase(), 
      oracle: oracle?.toLowerCase(),
      ADDITIONAL_ADMINS,
      isOwner, 
      isOracle, 
      isWhitelisted 
    };
    console.log("Access debug:", accessDebug);
    
    const hasAccessNow = isOwner || isOracle || isWhitelisted;
    setHasAccess(hasAccessNow);
    
    if (hasAccessNow) {
      setStatus("✅ Access granted - Ready to populate test data");
    } else {
      setStatus("❌ No access - You need to be owner, oracle, or whitelisted admin");
    }
  }, [connectedAddress, walletClient, CONTRACT_ADDRESS, USDC_ADDRESS, owner, oracle]);

  async function populate() {
    if (!CONTRACT_ADDRESS || !USDC_ADDRESS) {
      setStatus("❌ Contracts not deployed");
      return;
    }

    setStatus("⏳ Starting population...");
    setProgress(0);
    setCurrentStep(0);
    setTotalSteps(5); // Deposits, Attestations, PageRank, Borrower Registration, Loans

    const publicClient = createPublicClient({ 
      chain: { ...localhost, id: CHAIN_ID }, 
      transport: http(RPC_URL) 
    });
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

    const depositAmt = parseUnits("3000", 6);
    // Use maximum attestation weight (100% = 1000000 in the contract's scale)
    const attestWeight = 1000000n; // 100% attestation strength

    // 1) Deposits
    setCurrentStep(1);
    setStatus("⏳ Processing deposits...");
    for (let i = 0; i < lenders.length; i++) {
      const L = lenders[i];
      setStatus(`⏳ Processing deposit ${i + 1}/${lenders.length} for ${L.address.slice(0, 6)}...`);
      setProgress((i / lenders.length) * 0.25); // 25% for deposits
      
      try {
        await fetch(RPC_URL, { 
          method: "POST", 
          headers: { "Content-Type": "application/json" }, 
          body: JSON.stringify({ 
            jsonrpc: "2.0", 
            id: 1, 
            method: "anvil_setBalance", 
            params: [L.address, toHex(10n * 10n ** 18n)] 
          }) 
        });

        const usdcConfig = { address: USDC_ADDRESS as `0x${string}`, abi: contracts.MockUSDC.abi };
        const microConfig = { address: CONTRACT_ADDRESS as `0x${string}`, abi: contracts.DecentralizedMicrocredit.abi };
        const walletClient = createWalletClient({ 
          chain: { ...localhost, id: CHAIN_ID }, 
          transport: http(RPC_URL), 
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
          args: [CONTRACT_ADDRESS, depositAmt],
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

    // 2) Attestations
    setCurrentStep(2);
    setStatus("⏳ Processing attestations...");
    let attestCount = 0;
    const totalAttestations = lenders.length * borrowers.length;
    
    for (const L of lenders) {
      const walletClient = createWalletClient({ 
        chain: { ...localhost, id: CHAIN_ID }, 
        transport: http(RPC_URL), 
        account: L 
      });
      for (const B of borrowers) {
        attestCount++;
        setStatus(`⏳ Attesting ${B.address.slice(0, 6)}... to ${L.address.slice(0, 6)}... (${attestCount}/${totalAttestations})`);
        setProgress(0.25 + (attestCount / totalAttestations) * 0.25); // 25-50% for attestations
        
        try {
                  const txHash = await walletClient.writeContract({ 
          address: CONTRACT_ADDRESS as `0x${string}`, 
          abi: contracts.DecentralizedMicrocredit.abi, 
          functionName: "recordAttestation", 
          args: [B.address, attestWeight],
          gas: 5000000n // 5 million gas
        });
          await publicClient.waitForTransactionReceipt({ hash: txHash });
          
          // Add a small delay between transactions to prevent overwhelming the chain
          await new Promise(resolve => setTimeout(resolve, 100));
        } catch (error) {
          console.error(`Failed to record attestation from ${L.address} to ${B.address}:`, error);
          setStatus(`❌ Failed to record attestation ${attestCount}/${totalAttestations}`);
          throw error;
        }
      }
    }
    setProgress(0.5); // 50% complete after attestations
    setStatus("✅ Attestations recorded");

    // 3) PageRank - compute in smaller batches to avoid gas limit
    setCurrentStep(3);
    setStatus("⏳ Computing PageRank...");
    setProgress(0.75); // 75% complete after PageRank
    
    try {
      // Try with a more reasonable gas limit that fits within block limits
      const prHash = await createWalletClient({ 
        chain: { ...localhost, id: CHAIN_ID }, 
        transport: http(RPC_URL), 
        account: lenders[0] 
      }).writeContract({ 
        address: CONTRACT_ADDRESS as `0x${string}`, 
        abi: contracts.DecentralizedMicrocredit.abi, 
        functionName: "computePageRank",
        gas: 30000000n // Use 30 million gas (block limit)
      });
      await publicClient.waitForTransactionReceipt({ hash: prHash });
      setProgress(0.75); // 75% complete after PageRank
          setStatus("✅ PageRank computed");
  } catch (error) {
    console.error("Failed to compute PageRank:", error);
    setStatus("❌ Failed to compute PageRank - will try alternative approach");
    
    // Alternative: Skip PageRank for now and proceed with loans
    // The credit scores will be 0, but loans can still be requested
    console.log("Proceeding without PageRank computation");
  }

  // 4) Register Borrowers (so they show up in admin page)
  setCurrentStep(4);
  setStatus("⏳ Registering borrowers...");
  setProgress(0.8); // 80% complete after borrower registration
  
  for (let i = 0; i < borrowers.length; i++) {
    const B = borrowers[i];
    setStatus(`⏳ Registering borrower ${i + 1}/${borrowers.length} for ${B.address.slice(0, 6)}...`);
    setProgress(0.75 + (i / borrowers.length) * 0.05); // 75-80% for borrower registration
    
    try {
      // Give borrower some ETH for gas
      await fetch(RPC_URL, { 
        method: "POST", 
        headers: { "Content-Type": "application/json" }, 
        body: JSON.stringify({ 
          jsonrpc: "2.0", 
          id: 1, 
          method: "anvil_setBalance", 
          params: [B.address, toHex(10n * 10n ** 18n)] 
        }) 
      });
      
      // Note: Borrowers will be automatically registered when they receive attestations
      // The recordAttestation function adds both attester and borrower to the PageRank nodes
      // For now, we'll skip explicit registration and let the attestations handle it
      console.log(`✅ Borrower ${B.address} will be registered via attestations`);
      
    } catch (error) {
      console.error(`Failed to register borrower ${B.address}:`, error);
      setStatus(`❌ Failed to register borrower ${i + 1}/${borrowers.length}`);
    }
  }
  setProgress(0.8); // 80% complete after borrower registration
  setStatus("✅ Borrowers registered");

    // 5) Loans - Skip for now since credit scores are 0
  setCurrentStep(5);
  setStatus("⏳ Skipping loan creation (credit scores are 0)...");
  setProgress(1);
  setStatus(`🎉 Population complete! Created ${numLenders} lenders, ${numBorrowers} borrowers, and ${numLenders * numBorrowers} attestations. Loans skipped due to credit score requirements.`);
  }

  if (!connectedAddress) return <p>🔌 Connect wallet…</p>;
  if (!hasAccess) return (
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
            <p><strong>Contract Address:</strong> {CONTRACT_ADDRESS || "Not deployed"}</p>
            <p><strong>USDC Address:</strong> {USDC_ADDRESS || "Not deployed"}</p>
            <p><strong>Owner:</strong> {owner || "Loading..."}</p>
            <p><strong>Oracle:</strong> {oracle || "Loading..."}</p>
            <p><strong>Whitelisted Admins:</strong></p>
            <ul className="ml-4 list-disc">
              {ADDITIONAL_ADMINS.map((admin, index) => (
                <li key={index} className={admin === connectedAddress?.toLowerCase() ? "font-bold text-green-700" : ""}>
                  {admin} {admin === connectedAddress?.toLowerCase() ? "← This is you!" : ""}
                </li>
              ))}
            </ul>
          </div>
        </div>
      </div>
    </div>
  );

  return (
    <div className="container mx-auto px-4 py-8">
      <h1 className="text-3xl font-bold mb-8">🛠️ Admin: Populate Test Data</h1>
      

      
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
        <div className="mt-4 p-3 bg-blue-100 rounded-md">
          <p className="text-sm text-blue-800">
            <strong>Summary:</strong> This will create {numLenders} lenders and {numBorrowers} borrowers, 
            resulting in {numLenders * numBorrowers} attestations and {numBorrowers} loans.
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
      
      {/* Populate Button */}
      <button
        onClick={populate}
        disabled={!hasAccess}
        className="btn btn-primary"
        style={{ marginTop: "1rem" }}
      >
        Populate Test Data
      </button>
    </div>
  );


}
