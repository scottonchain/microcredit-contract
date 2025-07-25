"use client";

import { useState } from "react";
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

const RPC_URL = "http://127.0.0.1:8545";
const CHAIN_ID = 31337;

export default function FundPage() {
  const { address: connectedAddress } = useAccount();
  const [status, setStatus] = useState<string | null>(null);
  const [processing, setProcessing] = useState(false);

  // Resolve contract addresses & ABIs
  const contracts = deployedContracts[31337];
  const USDC_ADDRESS = contracts?.MockUSDC?.address as `0x${string}` | undefined;
  const USDC_ABI = contracts?.MockUSDC?.abi;

  const publicClient = createPublicClient({
    chain: { ...localhost, id: CHAIN_ID },
    transport: http(RPC_URL),
  });

  const ensureMinterEth = async () => {
    // Use private key 0x01 as minting account (same as populate page)
    const MINTER_PK = toHex(1, { size: 32 }) as `0x${string}`;
    const minterAccount = privateKeyToAccount(MINTER_PK);
    // Set 10 ETH
    await fetch(RPC_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "anvil_setBalance",
        params: [minterAccount.address, toHex(10n * 10n ** 18n)],
      }),
    });
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
      await fetch(RPC_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          method: "anvil_setBalance",
          params: [connectedAddress, toHex(1n * 10n ** 18n)], // 1 ETH
        }),
      });
      setStatus("✅ Funded 1 ETH to your address");
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
      const minter = await ensureMinterEth();
      const txHash = await minter.writeContract({
        address: USDC_ADDRESS,
        abi: USDC_ABI,
        functionName: "mint",
        args: [connectedAddress, 10_000n * 1_000_000n], // 10,000 USDC (6 dec)
        gas: 5_000_000n,
      });
      await publicClient.waitForTransactionReceipt({ hash: txHash });
      setStatus("✅ Minted 10,000 USDC to your address");
    } catch (err) {
      console.error(err);
      setStatus("❌ Failed to mint USDC");
    } finally {
      setProcessing(false);
    }
  };

  if (!connectedAddress) return <p className="p-6">🔌 Connect wallet…</p>;

  return (
    <div className="container mx-auto px-4 py-10 max-w-lg">
      <h1 className="text-3xl font-bold mb-6">🚰 Faucet</h1>
      <p className="mb-4 text-sm text-gray-700 break-all">
        Connected Address: <span className="font-mono">{connectedAddress}</span>
      </p>
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