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
        method: "anvil_setBalance",
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
      await fetch(RPC_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          method: "anvil_setBalance",
          params: [connectedAddress, toHex(newBalance)],
        }),
      });
      setStatus("✅ Funded 1 ETH to your address");
      // Refresh ETH balance
      await fetchEthBalance(connectedAddress);
    } catch (err) {
      console.error(err);
      setStatus("❌ Failed to fund ETH");
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
      
      await publicClient.waitForTransactionReceipt({ hash: txHash });
      setStatus("✅ Minted 10,000 USDC to your address");
      // Refresh USDC balance
      await fetchUsdcBalance(connectedAddress);
    } catch (err) {
      console.error("USDC minting error:", err);
      setStatus("❌ Failed to mint USDC. Check console for details.");
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
      </div>
      {status && <p className="mt-4 text-sm">{status}</p>}

      <div className="mt-8">
        <Link href="/" className="link">← Back Home</Link>
      </div>
    </div>
  );
} 