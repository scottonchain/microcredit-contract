"use client";

import { useState, useEffect } from "react";
import type { NextPage } from "next";
import { useAccount } from "wagmi";
import { localhost } from "viem/chains";
import { createPublicClient, http, toHex } from "viem";
import Link from "next/link";

/* ------------------------------------------------------------------
   Utility: Nonce Sync for demo
   Lets an admin manually set the on-chain nonce (via anvil_setNonce)
   so it matches the nonce cached by their browser wallet.
   ----------------------------------------------------------------*/

const RPC_URL = "http://127.0.0.1:8545"; // Anvil default
const CHAIN_ID = 31337;

const publicClient = createPublicClient({
  chain: { ...localhost, id: CHAIN_ID },
  transport: http(RPC_URL),
});

const NonceSyncPage: NextPage = () => {
  const { address: connectedAddress } = useAccount();

  const [chainNonce, setChainNonce] = useState<number | null>(null);
  const [desiredNonce, setDesiredNonce] = useState<string>("");
  const [status, setStatus] = useState<string>("");
  const [loading, setLoading] = useState(false);

  // Pull current chain nonce whenever the connected address changes
  useEffect(() => {
    if (!connectedAddress) return;
    const fetchNonce = async () => {
      try {
        const count = await publicClient.getTransactionCount({
          address: connectedAddress as `0x${string}`,
        });
        setChainNonce(Number(count));
        setDesiredNonce(String(Number(count)));
      } catch (err) {
        console.error("Failed to fetch nonce", err);
      }
    };
    fetchNonce();
  }, [connectedAddress]);

  const handleSetNonce = async () => {
    if (!connectedAddress) return;
    const target = parseInt(desiredNonce);
    if (isNaN(target) || target < 0) {
      setStatus("❌  Please enter a valid non-negative integer.");
      return;
    }
    setLoading(true);
    setStatus("Sending anvil_setNonce …");
    try {
      await fetch(RPC_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          method: "anvil_setNonce",
          params: [connectedAddress, toHex(BigInt(target))],
        }),
      });
      setStatus("✅  Nonce updated on chain.");
      setChainNonce(target);
    } catch (err: any) {
      console.error(err);
      setStatus(`❌  Failed: ${err.message || err}`);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="container mx-auto px-4 py-8 space-y-4">
      <h1 className="text-3xl font-bold mb-4">Nonce Sync Utility</h1>

      <Link href="/admin" className="btn btn-secondary btn-sm mb-4">
        ← Back to Admin Panel
      </Link>

      {!connectedAddress ? (
        <p>🔌 Connect your wallet to use this page.</p>
      ) : (
        <>
          <p className="text-sm text-gray-600">
            Connected address: <span className="font-mono">{connectedAddress}</span>
          </p>

          <div className="bg-base-200 p-4 rounded-lg space-y-2 max-w-sm">
            <div>
              Current on-chain nonce: <strong>{chainNonce ?? "…"}</strong>
            </div>
            <label className="form-control w-full">
              <span className="label-text mb-1">Desired nonce</span>
              <input
                type="number"
                className="input input-bordered"
                value={desiredNonce}
                onChange={e => setDesiredNonce(e.target.value)}
                min={0}
              />
            </label>
            <button
              className="btn btn-primary w-full"
              onClick={handleSetNonce}
              disabled={loading}
            >
              {loading ? "Setting…" : "Set nonce on chain"}
            </button>
            {status && <p className="text-sm mt-2">{status}</p>}
          </div>
          <p className="text-xs text-gray-500 mt-4 max-w-md">
            This issues the private-network JSON-RPC method <code>anvil_setNonce</code>
            so the next transaction nonce on the chain matches the number your
            wallet expects. Only works while connected to the local Anvil
            network (chain ID 31337).
          </p>
        </>
      )}
    </div>
  );
};

export default NonceSyncPage; 