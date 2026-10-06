"use client";

import { Suspense, useEffect, useState } from "react";
import { useSearchParams } from "next/navigation";
import { useAccount, usePublicClient, useSignTypedData } from "wagmi";
import { toast } from "react-hot-toast";
import { AddressInput } from "~~/components/scaffold-eth";
import { DocumentDuplicateIcon, CheckIcon } from "@heroicons/react/24/outline";
import { useAddressDisplayName } from "~~/hooks/useAddressDisplayName";
import { useUsdcWrite } from "~~/hooks/useUsdc";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { useDisplayName } from "~~/components/scaffold-eth/DisplayNameContext";
import { relayerErrorMessage } from "~~/utils/contractErrors";
import { getParsedError } from "~~/utils/scaffold-eth";
import { formatUSDC } from "~~/utils/format";
import { BackRequest, MICRO_DOMAIN, TYPES } from "~~/utils/eip712";
import { BASE_PATH, CHAIN_ID, MICROCREDIT_ABI, MICROCREDIT_ADDRESS, RELAYER_ENABLED } from "~~/utils/microcredit";
import { assertSameSigner, captureSigner, requireHash, waitForAllowance } from "~~/utils/walletWrite";
import { usePoolToken } from "~~/hooks/usePoolToken";
import { stopMessage } from "~~/utils/stopMessage";

// useSearchParams() needs a Suspense boundary for the page to be prerendered at build time.
export default function BackPage() {
  return (
    <Suspense>
      <BackForm />
    </Suspense>
  );
}

/** Parses a USDC amount typed by the user into 6-decimal units; null when invalid. */
const parseUsdc = (value: string): bigint | null => {
  const parsed = Number(value);
  if (!value.trim() || Number.isNaN(parsed) || parsed < 0) return null;
  return BigInt(Math.round(parsed * 1e6));
};

function BackForm() {
  const searchParams = useSearchParams();
  const { address: connectedAddress } = useAccount();
  const { signTypedDataAsync } = useSignTypedData();
  const publicClient = usePublicClient({ chainId: CHAIN_ID });

  const [borrower, setBorrower] = useState<string>("");
  const [amountInput, setAmountInput] = useState<string>("");
  const [loading, setLoading] = useState(false);
  const [stakeLoading, setStakeLoading] = useState(false);
  const [arrivedViaLink, setArrivedViaLink] = useState(false);
  const [submitted, setSubmitted] = useState<{ borrower: string; amount: bigint; txHash?: string } | null>(null);
  const [linkCopied, setLinkCopied] = useState(false);
  // The last step that stopped, kept on the page: a toast is gone before anyone can read it.
  const [stepError, setStepError] = useState("");

  const borrowerDisplayName = useAddressDisplayName(borrower || undefined);
  const { displayName: backerDisplayName } = useDisplayName();
  const isOwnLink = !!connectedAddress && !!borrower && connectedAddress.toLowerCase() === borrower.toLowerCase();

  // ── Your credit: granted (score x max loan) and staked; backing commits part of it ──
  const { data: granted } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "grantedCredit",
    args: [connectedAddress],
  });
  const { data: staked, refetch: refetchStake } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "stakeOf",
    args: [connectedAddress],
  });
  const { data: free, refetch: refetchFree } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getFreeCredit",
    args: [connectedAddress],
  });
  const { data: currentBacking, refetch: refetchBacking } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getBacking",
    args: [connectedAddress, (borrower || undefined) as `0x${string}` | undefined],
  });
  const { writeContractAsync: writeCreditAsync } = useScaffoldWriteContract({ contractName: "DecentralizedMicrocredit" });
  const writeUsdc = useUsdcWrite();

  const amount = parseUsdc(amountInput);
  const backedNow = currentBacking ? currentBacking[0] + currentBacking[1] : 0n;
  const freeCredit = free?.[0] ?? 0n;
  const freeStake = free?.[1] ?? 0n;
  // Raising a backing commits free credit first, then free stake; the rest has to be staked.
  const extra = amount !== null && amount > backedNow ? amount - backedNow : 0n;
  const fromCredit = extra < freeCredit ? extra : freeCredit;
  const stakeShortfall = extra - fromCredit > freeStake ? extra - fromCredit - freeStake : 0n;

  const copyLink = async () => {
    if (!connectedAddress) return;
    try {
      await navigator.clipboard.writeText(`${window.location.origin}${BASE_PATH}/attest?borrower=${connectedAddress}`);
      setLinkCopied(true);
      toast.success("Backing link copied!", { position: "top-center", duration: 2000 });
      setTimeout(() => setLinkCopied(false), 2500);
    } catch {
      toast.error("Could not copy link", { position: "top-center" });
    }
  };

  // Prefill from query params (?borrower=0x...&amount=50)
  useEffect(() => {
    if (!searchParams) return;
    const borrowerParam = searchParams.get("borrower");
    const amountParam = searchParams.get("amount");
    if (borrowerParam) {
      setBorrower(borrowerParam);
      setArrivedViaLink(true);
    }
    if (amountParam && parseUsdc(amountParam) !== null) setAmountInput(amountParam);
  }, [searchParams]);

  const refreshCredit = () => Promise.all([refetchStake(), refetchFree(), refetchBacking()]);

  // The build's token must be the pool's token; otherwise no write is offered (see TestnetBanner).
  const { mismatch: tokenMismatch } = usePoolToken();

  const handleStake = async () => {
    if (tokenMismatch) {
      toast.error("This build's token does not match the pool's token; staking is disabled.");
      return;
    }
    if (!connectedAddress || stakeShortfall === 0n) return;
    setStakeLoading(true);
    setStepError("");
    try {
      // Two transactions, each required to have been sent and mined, by the same account on the same chain.
      const signer = captureSigner("Staking");
      await writeUsdc("approve", [MICROCREDIT_ADDRESS, stakeShortfall]);
      if (!publicClient) throw new Error("Contract not available");
      await waitForAllowance(publicClient, signer.address, MICROCREDIT_ADDRESS, stakeShortfall);
      assertSameSigner(signer);
      requireHash(await writeCreditAsync({ functionName: "stake", args: [stakeShortfall] }), "Staking");
      await refreshCredit();
      toast.success(`Staked ${formatUSDC(stakeShortfall)}`, { position: "top-center" });
    } catch (err: any) {
      console.error("Stake error", err);
      toast.error(`Failed to stake: ${getParsedError(err)}`);
      setStepError(stopMessage("Staking stopped", getParsedError(err), String(err?.message ?? err)));
    } finally {
      setStakeLoading(false);
    }
  };

  // Gasless: the backer signs a BackRequest and the relayer submits it.
  const handleBack = async () => {
    if (!borrower || !connectedAddress || amount === null) return;
    setLoading(true);
    setStepError("");
    try {
      if (!publicClient) throw new Error("Contract not available");
      if (!RELAYER_ENABLED) {
        // Wallet-direct: the backer sends the transaction and pays the gas. Success is the mined hash, nothing less.
        const txHash = requireHash(
          await writeCreditAsync({ functionName: "back", args: [borrower as `0x${string}`, amount] }),
          "The backing",
        );
        await refreshCredit();
        setSubmitted({ borrower, amount, txHash });
        toast.success("Backing recorded", { position: "top-center" });
        return;
      }
      const backer = connectedAddress as `0x${string}`;
      const nonce = (await publicClient.readContract({
        address: MICROCREDIT_ADDRESS,
        abi: MICROCREDIT_ABI,
        functionName: "nonces",
        args: [backer],
      })) as bigint;
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
      const req: BackRequest = { backer, borrower: borrower as `0x${string}`, amount, nonce, deadline };

      const signature = await signTypedDataAsync({
        domain: MICRO_DOMAIN(CHAIN_ID, MICROCREDIT_ADDRESS) as any,
        types: { BackRequest: TYPES.BackRequest } as any,
        primaryType: "BackRequest",
        message: req as any,
      });

      const resp = await fetch("/api/meta/back", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          chainId: CHAIN_ID,
          contractAddress: MICROCREDIT_ADDRESS,
          req: {
            backer,
            borrower,
            amount: amount.toString(),
            nonce: nonce.toString(),
            deadline: deadline.toString(),
          },
          signature,
        }),
      });
      if (!resp.ok) throw new Error(await relayerErrorMessage(resp));
      const result = await resp.json();
      await refreshCredit();
      setSubmitted({ borrower, amount, txHash: result?.txHash });
      toast.success("Backing recorded", { position: "top-center" });
    } catch (err: any) {
      console.error("Backing error", err);
      toast.error(`Failed to back: ${getParsedError(err)}`);
      setStepError(stopMessage("Backing stopped", getParsedError(err), String(err?.message ?? err)));
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="flex items-center flex-col grow pt-10">
      <div className="px-5 w-full max-w-2xl">
        {stepError && (
          <div className="alert alert-warning mb-6" role="alert">
            {stepError}
          </div>
        )}
        {arrivedViaLink && !submitted && (
          <div className="bg-blue-50 border border-blue-200 rounded-lg p-5 mb-6 text-blue-800">
            {!connectedAddress ? (
              <>
                <h3 className="text-lg font-semibold mb-1">Backing link detected</h3>
                <p>Connect your wallet to continue. The form will be pre-filled.</p>
              </>
            ) : isOwnLink ? (
              <>
                <h3 className="text-lg font-semibold mb-2">This is your backing link</h3>
                <p className="mb-3">
                  Share it with people who have credit. Backing you moves part of their credit to you.
                </p>
                <button
                  onClick={copyLink}
                  className="inline-flex items-center gap-2 bg-blue-600 hover:bg-blue-700 text-white text-sm font-semibold px-4 py-2 rounded-lg transition-colors"
                >
                  {linkCopied ? (
                    <>
                      <CheckIcon className="h-4 w-4" /> Copied!
                    </>
                  ) : (
                    <>
                      <DocumentDuplicateIcon className="h-4 w-4" /> Copy Backing Link
                    </>
                  )}
                </button>
              </>
            ) : (
              <h3 className="text-lg font-semibold">
                You are invited to back{" "}
                {borrowerDisplayName ? (
                  <strong>{borrowerDisplayName}</strong>
                ) : (
                  <span className="font-mono break-all">{borrower}</span>
                )}
              </h3>
            )}
          </div>
        )}

        {connectedAddress && granted !== undefined && free !== undefined && (
          <div className="bg-base-200 border border-base-300 rounded-lg p-4 mb-6 text-sm">
            <div className="grid grid-cols-3 gap-4 text-center">
              <div>
                <div className="text-gray-500">Your credit</div>
                <div className="text-xl font-bold">{formatUSDC(granted)}</div>
              </div>
              <div>
                <div className="text-gray-500">Staked</div>
                <div className="text-xl font-bold">{formatUSDC(staked ?? 0n)}</div>
              </div>
              <div>
                <div className="text-gray-500">Free to back</div>
                <div className="text-xl font-bold">{formatUSDC(freeCredit + freeStake)}</div>
              </div>
            </div>
            <p className="text-gray-500 mt-3">
              Backing moves part of your own credit to the borrower: your limit drops by what theirs gains. If they
              default, your backing pays first. Staked USDC is slashed and committed credit is lost. Without credit or
              stake you have nothing to back with.
            </p>
          </div>
        )}

        {!submitted ? (
          <div className="bg-base-100 rounded-lg p-6 shadow w-full space-y-4">
            <div>
              <label className="block text-sm font-medium mb-2">Borrower Address</label>
              <AddressInput value={borrower} onChange={setBorrower} placeholder="0x..." />
            </div>
            <div>
              <label className="block text-sm font-medium mb-2">
                Back with (USDC){backedNow > 0n ? `, currently ${formatUSDC(backedNow)}` : ""}
              </label>
              <input
                type="number"
                min="0"
                step="0.01"
                value={amountInput}
                onChange={e => setAmountInput(e.target.value)}
                placeholder="50"
                className="input input-bordered w-full"
              />
            </div>
            {stakeShortfall > 0n ? (
              <button onClick={handleStake} disabled={stakeLoading || !connectedAddress} className="btn btn-secondary w-full">
                {stakeLoading ? "Staking..." : `Stake ${formatUSDC(stakeShortfall)} to back this much`}
              </button>
            ) : (
              <button
                onClick={handleBack}
                disabled={tokenMismatch || !borrower || amount === null || loading || !connectedAddress || isOwnLink}
                className="btn btn-primary w-full"
              >
                {loading ? "Submitting..." : amount !== null ? `Back with ${formatUSDC(amount)}` : "Back"}
              </button>
            )}
            <div className="text-xs text-gray-500 text-center">
              {RELAYER_ENABLED
                ? "Backing is gasless: you sign a message and our relayer submits it. Staking is a normal wallet transaction."
                : "Your wallet signs and pays for the backing transaction, and for staking: each is a normal wallet transaction on this network."}
            </div>
          </div>
        ) : (
          <div className="bg-base-100 rounded-lg p-6 shadow w-full">
            <h2 className="text-xl font-semibold mb-4">Backing Recorded</h2>
            <div className="space-y-3 text-sm">
              <div>
                <div className="text-gray-600">Backer</div>
                {backerDisplayName ? <div className="font-semibold">{backerDisplayName}</div> : null}
                <div className="font-mono break-all text-xs text-gray-500">{connectedAddress}</div>
              </div>
              <div>
                <div className="text-gray-600">Borrower</div>
                {borrowerDisplayName ? <div className="font-semibold">{borrowerDisplayName}</div> : null}
                <div className="font-mono break-all text-xs text-gray-500">{submitted.borrower}</div>
              </div>
              <div>
                <div className="text-gray-600">Backing</div>
                <div className="font-medium">{formatUSDC(submitted.amount)}</div>
              </div>
              {submitted.txHash && (
                <div>
                  <div className="text-gray-600">Transaction</div>
                  <div className="font-mono break-all text-xs text-gray-500">{submitted.txHash}</div>
                </div>
              )}
            </div>
            <div className="mt-6">
              <button className="btn btn-outline" onClick={() => setSubmitted(null)}>
                Edit
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
