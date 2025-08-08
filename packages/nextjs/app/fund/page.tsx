"use client";

import { useState, useEffect, useCallback } from "react";
import { useAccount } from "wagmi";
import {
  createPublicClient,
  createWalletClient,
  http,
  toHex,
  custom,
} from "viem";
import { localhost } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import deployedContracts from "~~/contracts/deployedContracts";
import Link from "next/link";
import { DocumentDuplicateIcon } from "@heroicons/react/24/outline";
import QRCodeDisplay from "~~/components/QRCodeDisplay";

const RPC_URL = "http://127.0.0.1:8545";
const CHAIN_ID = 31337;

export default function FundPage() {
  const { address: connectedAddress } = useAccount();
  const [status, setStatus] = useState<string | null>(null);
  const [processing, setProcessing] = useState(false);
  const [ethBalance, setEthBalance] = useState<string>("0");
  const [usdcBalance, setUsdcBalance] = useState<string>("0");

  // Resolve contract addresses & ABIs
  const contracts = deployedContracts[31337];
  const USDC_ADDRESS = contracts?.MockUSDC?.address as `0x${string}` | undefined;
  const USDC_ABI = contracts?.MockUSDC?.abi;

  const publicClient = createPublicClient({
    chain: { ...localhost, id: CHAIN_ID },
    transport: http(RPC_URL),
  });

  // Debug: Log the public client configuration
  console.log("Public client configured with:", {
    rpcUrl: RPC_URL,
    chainId: CHAIN_ID,
    usdcAddress: USDC_ADDRESS
  });

  // Check if RPC endpoint is accessible
  useEffect(() => {
    const checkRPC = async () => {
      try {
        const response = await fetch(RPC_URL, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            jsonrpc: "2.0",
            id: 1,
            method: "eth_chainId",
            params: [],
          }),
        });
        
        if (!response.ok) {
          console.error("RPC endpoint not accessible:", response.status, response.statusText);
          setStatus("❌ RPC endpoint not accessible. Make sure Anvil is running on port 8545.");
        } else {
          const data = await response.json();
          console.log("RPC endpoint accessible, chain ID:", data.result);
        }
      } catch (error) {
        console.error("Failed to connect to RPC endpoint:", error);
        setStatus("❌ Failed to connect to RPC endpoint. Make sure Anvil is running on port 8545.");
      }
    };
    
    checkRPC();
  }, []);

  // Function to fetch ETH balance
  const fetchEthBalance = useCallback(async (address: string) => {
    try {
      const { result: balanceHex } = await fetch(RPC_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          method: "eth_getBalance",
          params: [address, "latest"],
        }),
      }).then(res => res.json());
      
      const balance = BigInt(balanceHex || "0x0");
      const ethBalance = Number(balance) / 1e18;
      setEthBalance(ethBalance.toFixed(4));
    } catch (err) {
      console.error("Failed to fetch ETH balance:", err);
      setEthBalance("0");
    }
  }, [setEthBalance]);

  // Function to fetch USDC balance
  const fetchUsdcBalance = useCallback(async (address: string) => {
    if (!USDC_ADDRESS || !USDC_ABI) {
      console.log("USDC_ADDRESS or USDC_ABI not available");
      setUsdcBalance("0");
      return;
    }
    
    console.log("Fetching USDC balance for address:", address);
    console.log("USDC contract address:", USDC_ADDRESS);
    
    try {
      // First, check if the contract exists at the address
      const code = await publicClient.getBytecode({ address: USDC_ADDRESS });
      if (!code || code === "0x") {
        console.error("No contract found at USDC address:", USDC_ADDRESS);
        setUsdcBalance("0");
        return;
      }
      
      console.log("Contract found at USDC address, calling balanceOf...");
      
      const balance = await publicClient.readContract({
        address: USDC_ADDRESS,
        abi: USDC_ABI,
        functionName: "balanceOf",
        args: [address],
      });
      
      console.log("USDC balance result:", balance);
      
      const usdcBalance = Number(balance) / 1e6; // USDC has 6 decimals
      setUsdcBalance(usdcBalance.toFixed(2));
    } catch (err) {
      console.error("Failed to fetch USDC balance:", err);
      console.error("Error details:", {
        address: USDC_ADDRESS,
        targetAddress: address,
        abi: USDC_ABI ? "Available" : "Missing"
      });
      setUsdcBalance("0");
    }
  }, [USDC_ADDRESS, USDC_ABI, publicClient, setUsdcBalance]);

  // Fetch balances when address changes
  useEffect(() => {
    if (connectedAddress) {
      console.log("Address changed, fetching balances for:", connectedAddress);
      fetchEthBalance(connectedAddress);
      fetchUsdcBalance(connectedAddress);
    } else {
      setEthBalance("0");
      setUsdcBalance("0");
    }
  }, [connectedAddress, USDC_ADDRESS, fetchEthBalance, fetchUsdcBalance]);

  const ensureMinterEth = async () => {
    // Use private key 0x01 as minting account (same as populate page)
    const MINTER_PK = toHex(1, { size: 32 }) as `0x${string}`;
    const minterAccount = privateKeyToAccount(MINTER_PK);
    
    // Set 50 ETH to ensure sufficient balance for gas
    const response = await fetch(RPC_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "hardhat_setBalance",
        params: [minterAccount.address, toHex(50n * 10n ** 18n)],
      }),
    });
    
    if (!response.ok) {
      throw new Error("Failed to set minter balance");
    }
    
    // Verify the balance was set correctly
    const balanceResponse = await fetch(RPC_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 2,
        method: "eth_getBalance",
        params: [minterAccount.address, "latest"],
      }),
    });
    
    const balanceData = await balanceResponse.json();
    const balance = BigInt(balanceData.result || "0x0");
    console.log(`Minter balance set to: ${Number(balance) / 1e18} ETH`);
    
    return createWalletClient({
      chain: { ...localhost, id: CHAIN_ID },
      transport: http(RPC_URL),
      account: minterAccount,
    });
  };

  const fundEth = async () => {
    if (!connectedAddress) return;
    setProcessing(true);
    setStatus("⛽ Funding ETH...");
    try {
      // Fetch current ETH balance
      const { result: currentBalanceHex } = await fetch(RPC_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          method: "eth_getBalance",
          params: [connectedAddress, "latest"],
        }),
      }).then(res => res.json());
      
      const currentBalance = BigInt(currentBalanceHex || "0x0");
      const newBalance = currentBalance + 1n * 10n ** 18n;
      
      console.log(`Setting balance for ${connectedAddress} from ${Number(currentBalance) / 1e18} ETH to ${Number(newBalance) / 1e18} ETH`);
      
      const response = await fetch(RPC_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          method: "hardhat_setBalance",
          params: [connectedAddress, toHex(newBalance)],
        }),
      });
      
      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`);
      }
      
      const responseData = await response.json();
      if (responseData.error) {
        throw new Error(`RPC error: ${responseData.error.message}`);
      }
      
      console.log("Balance set successfully:", responseData);
      
      // Verify the balance was set correctly
      const verifyResponse = await fetch(RPC_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: 2,
          method: "eth_getBalance",
          params: [connectedAddress, "latest"],
        }),
      });
      
      const verifyData = await verifyResponse.json();
      const actualBalance = BigInt(verifyData.result || "0x0");
      console.log(`Verified balance: ${Number(actualBalance) / 1e18} ETH`);
      
      if (actualBalance < newBalance) {
        throw new Error(`Balance verification failed. Expected: ${Number(newBalance) / 1e18} ETH, Got: ${Number(actualBalance) / 1e18} ETH`);
      }
      
      setStatus("✅ Funded 1 ETH to your address");
      // Refresh ETH balance
      await fetchEthBalance(connectedAddress);
    } catch (err) {
      console.error("ETH funding error:", err);
      setStatus(`❌ Failed to fund ETH: ${err instanceof Error ? err.message : 'Unknown error'}`);
    } finally {
      setProcessing(false);
    }
  };

  // Test function to verify hardhat_setBalance is working
  const testAnvilSetBalance = async () => {
    if (!connectedAddress) return;
    setProcessing(true);
    setStatus("🧪 Testing hardhat_setBalance...");
    try {
      // Test with a simple balance setting
      const testBalance = 5n * 10n ** 18n; // 5 ETH
      
      const response = await fetch(RPC_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          method: "hardhat_setBalance",
          params: [connectedAddress, toHex(testBalance)],
        }),
      });
      
      const responseData = await response.json();
      console.log("Test hardhat_setBalance response:", responseData);
      
      if (responseData.error) {
        throw new Error(`Test failed: ${responseData.error.message}`);
      }
      
      // Verify the test balance
      const verifyResponse = await fetch(RPC_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: 2,
          method: "eth_getBalance",
          params: [connectedAddress, "latest"],
        }),
      });
      
      const verifyData = await verifyResponse.json();
      const actualBalance = BigInt(verifyData.result || "0x0");
      
      if (actualBalance === testBalance) {
        setStatus("✅ hardhat_setBalance test passed! Balance set to 5 ETH");
        await fetchEthBalance(connectedAddress);
      } else {
        throw new Error(`Test verification failed. Expected: 5 ETH, Got: ${Number(actualBalance) / 1e18} ETH`);
      }
    } catch (err) {
      console.error("Test error:", err);
      setStatus(`❌ Test failed: ${err instanceof Error ? err.message : 'Unknown error'}`);
    } finally {
      setProcessing(false);
    }
  };

  // Function to refresh wallet balance
  const refreshWalletBalance = async () => {
    setProcessing(true);
    setStatus("🔄 Refreshing wallet balance...");
    try {
      // Trigger a small transaction to force wallet refresh
      // We'll use a simple RPC call that doesn't change state but forces a refresh
      await fetch(RPC_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          method: "eth_blockNumber",
          params: [],
        }),
      });
      
      // Also try to trigger a wallet refresh by requesting account info
      if (window.ethereum) {
        try {
          await window.ethereum.request({
            method: 'eth_requestAccounts'
          });
          console.log("Wallet refresh triggered");
        } catch (walletError) {
          console.log("Wallet refresh failed, but that's okay:", walletError);
        }
      }
      
      setStatus("✅ Wallet refresh triggered. Check your wallet now!");
      
      // Refresh our local balance display
      if (connectedAddress) {
        await fetchEthBalance(connectedAddress);
        await fetchUsdcBalance(connectedAddress);
      }
    } catch (err) {
      console.error("Wallet refresh error:", err);
      setStatus(`❌ Failed to refresh wallet: ${err instanceof Error ? err.message : 'Unknown error'}`);
    } finally {
      setProcessing(false);
    }
  };

  const fundUsdc = async () => {
    if (!connectedAddress || !USDC_ADDRESS || !USDC_ABI) return;
    setProcessing(true);
    setStatus("💵 Minting 10,000 USDC...");
    try {
      // Fetch current USDC balance
      const currentUsdc = await publicClient.readContract({
        address: USDC_ADDRESS,
        abi: USDC_ABI,
        functionName: "balanceOf",
        args: [connectedAddress],
      });
      
      const mintAmount = 10_000n * 1_000_000n;
      console.log(`Current USDC balance: ${Number(currentUsdc) / 1e6}`);
      console.log(`Minting ${Number(mintAmount) / 1e6} USDC to ${connectedAddress}`);
      
      // Ensure minter has sufficient ETH
      const minter = await ensureMinterEth();
      
      // Mint 10,000 USDC on top of current balance
      const txHash = await minter.writeContract({
        address: USDC_ADDRESS,
        abi: USDC_ABI,
        functionName: "mint",
        args: [connectedAddress, mintAmount],
        gas: 500_000n, // Reduced gas limit
      });
      
      console.log("USDC mint transaction hash:", txHash);
      
      const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
      console.log("USDC mint transaction receipt:", receipt);
      
      // Verify the mint was successful by checking the new balance
      const newUsdcBalance = await publicClient.readContract({
        address: USDC_ADDRESS,
        abi: USDC_ABI,
        functionName: "balanceOf",
        args: [connectedAddress],
      });
      
      console.log(`New USDC balance: ${Number(newUsdcBalance) / 1e6}`);
      
      if (newUsdcBalance < currentUsdc + mintAmount) {
        throw new Error(`USDC mint verification failed. Expected: ${Number(currentUsdc + mintAmount) / 1e6}, Got: ${Number(newUsdcBalance) / 1e6}`);
      }
      
      setStatus("✅ Minted 10,000 USDC to your address");
      // Refresh USDC balance
      await fetchUsdcBalance(connectedAddress);
    } catch (err) {
      console.error("USDC minting error:", err);
      setStatus(`❌ Failed to mint USDC: ${err instanceof Error ? err.message : 'Unknown error'}`);
    } finally {
      setProcessing(false);
    }
  };

  if (!connectedAddress) return <p className="p-6">🔌 Connect wallet…</p>;

  const copyToClipboard = async (text: string) => {
    try {
      await navigator.clipboard.writeText(text);
      setStatus("✅ Copied to clipboard!");
      setTimeout(() => setStatus(null), 2000);
    } catch (err) {
      console.error("Failed to copy:", err);
      setStatus("❌ Failed to copy to clipboard");
    }
  };

  return (
    <div className="container mx-auto px-4 py-10 max-w-lg">
      <h1 className="text-3xl font-bold mb-6">🚰 Faucet</h1>
      <p className="mb-4 text-sm text-gray-700 break-all">
        Connected Address: <span className="font-mono">{connectedAddress}</span>
      </p>
      
      {/* Wallet Balance Refresh Notice */}
      <div className="mb-6 p-4 bg-yellow-50 border border-yellow-200 rounded-lg">
        <h3 className="text-lg font-semibold mb-2 text-yellow-800">💡 Wallet Balance Notice</h3>
        <p className="text-sm text-yellow-700 mb-3">
          After funding ETH or USDC, your wallet may not immediately show the updated balance due to caching. 
          Use the &quot;Refresh Wallet Balance&quot; button below to force your wallet to update.
        </p>
        <div className="text-xs text-yellow-600">
          <strong>Alternative solutions:</strong>
          <ul className="mt-1 ml-4 list-disc">
            <li>Switch networks in your wallet and switch back</li>
            <li>Disconnect and reconnect your wallet</li>
            <li>Make a small transaction to trigger a balance refresh</li>
          </ul>
        </div>
      </div>
      
      {/* Current Balances */}
      <div className="mb-6 p-4 bg-blue-50 border border-blue-200 rounded-lg">
        <h3 className="text-lg font-semibold mb-3 text-blue-800">Current Balances</h3>
        <div className="grid grid-cols-2 gap-4">
          <div className="text-center">
            <div className="text-2xl font-bold text-blue-600">{ethBalance}</div>
            <div className="text-sm text-blue-700">ETH</div>
          </div>
          <div className="text-center">
            <div className="text-2xl font-bold text-green-600">{usdcBalance}</div>
            <div className="text-sm text-green-700">USDC</div>
          </div>
        </div>
      </div>
      
      {/* Mock USDC Token Address */}
      {USDC_ADDRESS ? (
        <div className="mb-6 p-4 bg-gray-50 rounded-lg">
          <h3 className="text-lg font-semibold mb-2">Mock USDC Token</h3>
          <div className="flex items-start gap-4">
            {/* QR Code */}
            <div className="flex-shrink-0">
              <div
                onClick={() => copyToClipboard(USDC_ADDRESS)}
                className="cursor-pointer flex flex-col items-center"
              >
                <QRCodeDisplay value={USDC_ADDRESS} size={80} />
                <span className="text-xs text-gray-500 mt-2">Click to copy</span>
              </div>
            </div>
            
            {/* Address and Copy Button */}
            <div className="flex-1">
              <div className="flex items-center gap-2 mb-2">
                <p className="text-sm text-gray-700 break-all font-mono flex-1">
                  {USDC_ADDRESS}
                </p>
                <button
                  onClick={() => copyToClipboard(USDC_ADDRESS)}
                  className="btn btn-sm btn-ghost"
                  title="Copy token address"
                >
                  <DocumentDuplicateIcon className="h-4 w-4" />
                </button>
              </div>
              <p className="text-xs text-gray-500">
                Use this address to add Mock USDC to your wallet. Click the QR code or copy button to copy the address.
              </p>
            </div>
          </div>
        </div>
      ) : (
        <div className="mb-6 p-4 bg-yellow-50 border border-yellow-200 rounded-lg">
          <h3 className="text-lg font-semibold mb-2 text-yellow-800">Mock USDC Not Deployed</h3>
          <p className="text-sm text-yellow-700">
            Mock USDC contract is not deployed. Deploy contracts first to get the token address.
          </p>
        </div>
      )}
      <div className="space-y-4">
        <button
          onClick={fundEth}
          disabled={processing}
          className="btn btn-primary w-full"
        >
          Fund 1 ETH
        </button>
        <button
          onClick={fundUsdc}
          disabled={processing}
          className="btn btn-secondary w-full"
        >
          Mint 10,000 USDC
        </button>
        <button
          onClick={testAnvilSetBalance}
          disabled={processing}
          className="btn btn-outline w-full"
        >
          🧪 Test hardhat_setBalance
        </button>
        <button
          onClick={refreshWalletBalance}
          disabled={processing}
          className="btn btn-ghost w-full"
        >
          🔄 Refresh Wallet Balance
        </button>
      </div>
      {status && <p className="mt-4 text-sm">{status}</p>}

      <div className="mt-8">
        <Link href="/" className="link">← Back Home</Link>
      </div>
    </div>
  );
} 