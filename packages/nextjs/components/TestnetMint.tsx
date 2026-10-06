"use client";

import { useState } from "react";
import { useAccount } from "wagmi";
import { toast } from "react-hot-toast";
import { useUsdcWrite } from "~~/hooks/useUsdc";
import { getParsedError } from "~~/utils/scaffold-eth";
import { IS_LIVE_TESTNET, IS_MOCK_USDC } from "~~/utils/microcredit";

const MINT_AMOUNT = 100_000_000n; // 100 test USDC (6 decimals)

/**
 * Mints 100 test USDC to the connected wallet. Only on the live test network, where the pool's token is
 * the free-mint MockUSDC; locally the fund page does this, and on a real token the button does not exist.
 */
export const TestnetMint = ({ onMinted }: { onMinted?: () => void | Promise<unknown> }) => {
  const { address } = useAccount();
  const writeUsdc = useUsdcWrite();
  const [busy, setBusy] = useState(false);
  if (!IS_LIVE_TESTNET || !IS_MOCK_USDC || !address) return null;

  const mint = async () => {
    setBusy(true);
    try {
      await writeUsdc("mint", [address as `0x${string}`, MINT_AMOUNT]);
      toast.success("Minted 100 test USDC", { position: "top-center" });
      await onMinted?.();
    } catch (err: any) {
      toast.error(`Mint failed: ${getParsedError(err)}`);
    } finally {
      setBusy(false);
    }
  };

  return (
    <button className="btn btn-outline btn-sm" onClick={mint} disabled={busy}>
      {busy ? "Minting…" : "Get 100 test USDC"}
    </button>
  );
};
