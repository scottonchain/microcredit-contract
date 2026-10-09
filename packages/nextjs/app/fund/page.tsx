"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { type Address as WalletAddress, formatEther } from "viem";
import { useAccount } from "wagmi";
import { Address } from "~~/components/scaffold-eth";
import { formatUSDC } from "~~/utils/format";
import { createLocalFaucetClient, fundLocalEth, mintLocalUsdc } from "~~/utils/localFaucet";
import { ANVIL_RPC_URL, CHAIN_ID, IS_MOCK_USDC, USDC_ABI, USDC_ADDRESS } from "~~/utils/microcredit";

const client = createLocalFaucetClient(ANVIL_RPC_URL);
const isLocal = (CHAIN_ID as number) === 31337;
const localToken = IS_MOCK_USDC ? USDC_ADDRESS : undefined;
type Balances = { address: WalletAddress; eth: bigint; usdc?: bigint };

export default function FundPage() {
  const { address } = useAccount();
  const [balances, setBalances] = useState<Balances>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");

  const readBalances = useCallback(async (wallet: WalletAddress): Promise<Balances> => {
    if (!isLocal || (await client.getChainId()) !== 31337) throw new Error("Start local Anvil on chain 31337.");
    const [eth, usdc] = await Promise.all([
      client.getBalance({ address: wallet }),
      localToken
        ? client.readContract({ address: localToken, abi: USDC_ABI, functionName: "balanceOf", args: [wallet] })
        : undefined,
    ]);
    return { address: wallet, eth, usdc };
  }, []);

  useEffect(() => {
    let active = true;
    setError("");
    setMessage("");
    if (isLocal && address) {
      readBalances(address).then(
        result => active && setBalances(result),
        () => active && setError("Cannot read local balances. Start Anvil and run yarn deploy."),
      );
    }
    return () => {
      active = false;
    };
  }, [address, readBalances]);

  async function run(action: "eth" | "usdc" | "refresh") {
    if (!address || busy || !isLocal) return;
    setBusy(true);
    setError("");
    setMessage("");
    try {
      if (action === "eth") await fundLocalEth(client, CHAIN_ID, address);
      if (action === "usdc") {
        if (!localToken) throw new Error("This deployment does not use a local MockUSDC token.");
        await mintLocalUsdc(client, CHAIN_ID, address, localToken);
      }
      if (action !== "refresh") setMessage(`${action === "eth" ? "1 ETH" : "10,000 USDC"} added to ${address}.`);
      try {
        setBalances(await readBalances(address));
      } catch {
        setError("Could not refresh balances. Check that Anvil and the local token are available.");
      }
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Local funding failed.");
    } finally {
      setBusy(false);
    }
  }

  const current = balances?.address === address ? balances : undefined;
  return (
    <main className="w-full max-w-2xl mx-auto p-6 space-y-5">
      <h1 className="text-3xl font-bold">Local faucet</h1>
      {!isLocal ? (
        <p>This faucet is available only on local Anvil. This build targets chain {CHAIN_ID}.</p>
      ) : (
        <>
          <p>Start Anvil and deploy the local demo before adding test ETH or MockUSDC to a connected wallet.</p>
          {!address ? (
            <p>Connect your wallet to continue.</p>
          ) : (
            <div className="bg-base-100 rounded-lg p-6 space-y-4">
              <Address address={address} />
              <p>ETH: {current ? formatEther(current.eth) : "—"}</p>
              <p>MockUSDC: {current?.usdc !== undefined ? formatUSDC(current.usdc) : "—"}</p>
              <div className="flex gap-3 flex-wrap">
                <button className="btn btn-primary" disabled={busy} onClick={() => run("eth")}>
                  Fund 1 ETH
                </button>
                <button className="btn btn-primary" disabled={busy || !localToken} onClick={() => run("usdc")}>
                  Mint 10,000 USDC
                </button>
                <button className="btn btn-outline" disabled={busy} onClick={() => run("refresh")}>
                  Refresh balances
                </button>
              </div>
              {localToken && (
                <div>
                  <p>Local token</p>
                  <Address address={localToken} />
                </div>
              )}
            </div>
          )}
          {message && (
            <p role="status" className="text-success break-all">
              {message}
            </p>
          )}
          {error && (
            <p role="alert" className="text-error break-words">
              {error}
            </p>
          )}
          <Link href="/populate-test-data" className="link">
            Local demo setup
          </Link>
        </>
      )}
    </main>
  );
}
