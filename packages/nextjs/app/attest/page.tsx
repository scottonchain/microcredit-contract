"use client";

import { useEffect, useMemo, useState } from "react";
import { useSearchParams } from "next/navigation";
import { useAccount, useSignTypedData } from "wagmi";
import { toast } from "react-hot-toast";
import { AddressInput } from "~~/components/scaffold-eth";
import { DocumentDuplicateIcon, CheckIcon } from "@heroicons/react/24/outline";
import deployedContracts from "~~/contracts/deployedContracts";
import { useAddressDisplayName } from "~~/hooks/useAddressDisplayName";
import { useDisplayName } from "~~/components/scaffold-eth/DisplayNameContext";
import { createPublicClient, http } from "viem";
import { localhost } from "viem/chains";
import { MICRO_DOMAIN, TYPES, AttestRequest } from "../../types/eip712";

export default function AttestPage() {
  const searchParams = useSearchParams();
  const { address: connectedAddress } = useAccount();
  const { signTypedDataAsync } = useSignTypedData();

  // Contract config
  const CONTRACT_ADDRESS = deployedContracts[31337]?.DecentralizedMicrocredit?.address as `0x${string}` | undefined;
  const CONTRACT_ABI = deployedContracts[31337]?.DecentralizedMicrocredit?.abi as any;
  const CHAIN_ID = 31337;
  const RPC_URL = "http://localhost:8545";
  const publicClient = useMemo(
    () => createPublicClient({ chain: { ...localhost, id: CHAIN_ID }, transport: http(RPC_URL) }),
    []
  );

  // Attestation form state
  const [attestBorrower, setAttestBorrower] = useState<string>("");
  const [attestWeight, setAttestWeight] = useState<number>(80);
  const [attestLoading, setAttestLoading] = useState(false);
  const [arrivedViaAttestLink, setArrivedViaAttestLink] = useState(false);
  const [submittedInfo, setSubmittedInfo] = useState<{ borrower: string; weight: number; txHash?: string } | null>(null);
  const [linkCopied, setLinkCopied] = useState(false);

  const borrowerDisplayName = useAddressDisplayName(attestBorrower || undefined);
  const { displayName: attesterDisplayName } = useDisplayName();

  const copyAttestationLink = async () => {
    if (!connectedAddress) return;
    const url = `${window.location.origin}/attest?borrower=${connectedAddress}`;
    try {
      await navigator.clipboard.writeText(url);
      setLinkCopied(true);
      toast.success("Attestation link copied!", { position: "top-center", duration: 2000 });
      setTimeout(() => setLinkCopied(false), 2500);
    } catch {
      toast.error("Could not copy link", { position: "top-center" });
    }
  };

  // Connected user's own credit score
  const [myScore, setMyScore] = useState<number | null>(null);
  useEffect(() => {
    if (!connectedAddress || !CONTRACT_ADDRESS || !CONTRACT_ABI) return;
    publicClient
      .readContract({
        address: CONTRACT_ADDRESS,
        abi: CONTRACT_ABI,
        functionName: "getCreditScore",
        args: [connectedAddress as `0x${string}`],
      })
      .then((score) => setMyScore(Number(score as bigint)))
      .catch(() => setMyScore(null));
  }, [connectedAddress, CONTRACT_ADDRESS, CONTRACT_ABI]);

  // Prefill from query params (?borrower=0x...&weight=80)
  useEffect(() => {
    if (!searchParams) return;
    const borrowerParam = searchParams.get("borrower");
    const weightParam = searchParams.get("weight");
    if (borrowerParam) {
      setAttestBorrower(borrowerParam);
      setArrivedViaAttestLink(true);
    }
    if (weightParam) {
      const w = Number(weightParam);
      if (!Number.isNaN(w) && w >= 1 && w <= 100) setAttestWeight(w);
    }
  }, [searchParams]);

  // Persist prefill in session storage so refreshes keep the form
  useEffect(() => {
    try {
      if (attestBorrower) {
        window.sessionStorage.setItem("attest_prefill_borrower", attestBorrower);
      }
    } catch {}
  }, [attestBorrower]);

  useEffect(() => {
    try {
      window.sessionStorage.setItem("attest_prefill_weight", String(attestWeight));
    } catch {}
  }, [attestWeight]);

  // Main submit handler (gasless via relayer)
  const handleAttestation = async () => {
    if (!attestBorrower || !connectedAddress) return;
    setAttestLoading(true);
    try {
      if (!CONTRACT_ADDRESS || !CONTRACT_ABI) throw new Error("Contract not available");
      const attester = connectedAddress as `0x${string}`;
      const borrower = attestBorrower as `0x${string}`;
      const weight = BigInt(attestWeight * 10000); // percent -> SCALE(1e6)

      const metaNonce = (await publicClient.readContract({
        address: CONTRACT_ADDRESS,
        abi: CONTRACT_ABI,
        functionName: "nonces",
        args: [attester],
      })) as bigint;
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);

      const rq: AttestRequest = { attester, borrower, weight, nonce: metaNonce, deadline };

      const sig = await signTypedDataAsync({
        domain: MICRO_DOMAIN(31337, CONTRACT_ADDRESS) as any,
        types: { AttestRequest: TYPES.AttestRequest } as any,
        primaryType: "AttestRequest",
        message: rq as any,
      });

      const resp = await fetch("/api/meta/attest", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          chainId: 31337,
          contractAddress: CONTRACT_ADDRESS,
          req: {
            attester,
            borrower,
            weight: weight.toString(),
            nonce: metaNonce.toString(),
            deadline: deadline.toString(),
          },
          signature: sig,
        }),
      });
      if (!resp.ok) throw new Error(await resp.text());
      const j = await resp.json();
      console.log("Meta attestation result:", j);

      const txHash = j?.txHash || j?.hash || j?.transactionHash || undefined;
      setSubmittedInfo({ borrower, weight: Number(attestWeight), txHash });
      toast.success("Attestation submitted via relayer", { position: "top-center" });
    } catch (err: any) {
      console.error("Meta attestation error", err);
      toast.error(`Failed to attest: ${err?.message || "Unknown error"}`);
    } finally {
      setAttestLoading(false);
    }
  };

  return (
    <div className="flex items-center flex-col grow pt-10">
      <div className="px-5 w-full max-w-2xl">
        <div className="text-center mb-8">
          <h1 className="text-3xl font-bold">Make an Attestation</h1>
          <p className="text-gray-600 mt-2">No deposit required.</p>
        </div>

        {arrivedViaAttestLink && !submittedInfo && (
          <div className="bg-blue-50 border border-blue-200 rounded-lg p-5 mb-6">
            {connectedAddress ? (
              attestBorrower && connectedAddress.toLowerCase() === attestBorrower.toLowerCase() ? (
                <div className="text-blue-800">
                  <h3 className="text-lg font-semibold mb-2">This is your attestation link</h3>
                  <p className="mb-3">Share this URL so others can attest to your creditworthiness. The form is pre-filled with your address.</p>
                  <button
                    onClick={copyAttestationLink}
                    className="inline-flex items-center gap-2 bg-blue-600 hover:bg-blue-700 text-white text-sm font-semibold px-4 py-2 rounded-lg transition-colors"
                  >
                    {linkCopied ? (
                      <><CheckIcon className="h-4 w-4" /> Copied!</>
                    ) : (
                      <><DocumentDuplicateIcon className="h-4 w-4" /> Copy Attestation Link</>
                    )}
                  </button>
                </div>
              ) : (
                <div className="text-blue-800">
                  <h3 className="text-lg font-semibold mb-1">You were invited to make an attestation</h3>
                  <p>
                    The form below is pre-filled to attest for{" "}
                    {borrowerDisplayName ? (
                      <strong>{borrowerDisplayName}</strong>
                    ) : (
                      <span className="font-mono break-all">{attestBorrower}</span>
                    )}.
                  </p>
                </div>
              )
            ) : (
              <div className="text-blue-800">
                <h3 className="text-lg font-semibold mb-1">Attestation link detected</h3>
                <p>Connect your wallet to continue. The form will be pre-filled.</p>
              </div>
            )}
          </div>
        )}

        {connectedAddress && myScore !== null && (
          <div className="bg-base-200 border border-base-300 rounded-lg p-4 mb-6 flex items-center justify-between">
            <div>
              <div className="text-sm text-gray-500">Your credit score</div>
              <div className="text-2xl font-bold">{(myScore / 10000).toFixed(1)}%</div>
            </div>
            <div
              className={`radial-progress text-sm font-semibold ${
                myScore >= 900000 ? "text-success" : myScore >= 600000 ? "text-warning" : "text-error"
              }`}
              style={{ "--value": String(Math.round(myScore / 10000)), "--size": "3.5rem" } as React.CSSProperties}
            >
              {Math.round(myScore / 10000)}%
            </div>
          </div>
        )}

        {!submittedInfo ? (
          <>
            <div className="bg-base-100 rounded-lg p-6 shadow w-full">
              <div className="space-y-4">
                <div>
                  <label className="block text-sm font-medium mb-2">Borrower Address</label>
                  <AddressInput value={attestBorrower} onChange={setAttestBorrower} placeholder="0x..." />
                </div>
                <div>
                  <label className="block text-sm font-medium mb-2">Confidence Level: {attestWeight}%</label>
                  <input type="range" min="1" max="100" value={attestWeight} onChange={e=>setAttestWeight(Number(e.target.value))} className="w-full" />
                </div>
                <button onClick={handleAttestation} disabled={!attestBorrower || attestLoading || !connectedAddress} className="btn btn-primary w-full">
                  {attestLoading ? "Submitting..." : "Submit Attestation"}
                </button>
              </div>
            </div>

            <div className="text-xs text-gray-500 mt-4 text-center">
              Attestations are gasless: you sign a message and our relayer submits it on-chain.
            </div>
          </>
        ) : (
          <div className="bg-base-100 rounded-lg p-6 shadow w-full">
            <h2 className="text-xl font-semibold mb-4">Attestation Recorded</h2>
            <div className="space-y-3 text-sm">
              <div>
                <div className="text-gray-600">Attester</div>
                {attesterDisplayName ? (
                  <div className="font-semibold">{attesterDisplayName}</div>
                ) : null}
                <div className="font-mono break-all text-xs text-gray-500">{connectedAddress}</div>
              </div>
              <div>
                <div className="text-gray-600">Borrower</div>
                {borrowerDisplayName ? (
                  <div className="font-semibold">{borrowerDisplayName}</div>
                ) : null}
                <div className="font-mono break-all text-xs text-gray-500">{submittedInfo.borrower}</div>
              </div>
              <div>
                <div className="text-gray-600">Confidence</div>
                <div className="font-medium">{submittedInfo.weight}%</div>
              </div>
              {submittedInfo.txHash && (
                <div>
                  <div className="text-gray-600">Transaction</div>
                  <div className="font-mono break-all text-xs text-gray-500">{submittedInfo.txHash}</div>
                </div>
              )}
            </div>
            <div className="mt-6">
              <button className="btn btn-outline" onClick={() => setSubmittedInfo(null)}>Edit</button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}