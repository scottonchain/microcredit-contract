import { useState } from "react";
import { Address, AddressInput } from "../scaffold-eth";
import { useScaffoldWriteContract, useScaffoldReadContract } from "~~/hooks/scaffold-eth";
import { notification } from "~~/utils/scaffold-eth";
import { TransactionReceipt } from "viem";
import { ContractName } from "~~/utils/scaffold-eth/contract";

interface AttestationData {
  from: string;
  to: string;
  message: string;
  timestamp: bigint;
}

export const AttestationUI = () => {
  const [toAddress, setToAddress] = useState("");
  const [message, setMessage] = useState("");
  const [lookupAddress, setLookupAddress] = useState("");

  const contractName = "Attestation" as ContractName;

  // Read attestations for a specific address
  const { data: receivedAttestations } = useScaffoldReadContract({
    contractName, 
    functionName: "getReceivedAttestations",
    args: [lookupAddress || "0x0000000000000000000000000000000000000000"],
  });

  const { writeContractAsync: createAttestation } = useScaffoldWriteContract(contractName);

  const handleCreateAttestation = async () => {
    if (!toAddress || !message) return;
    try {
      notification.info("Creating attestation...");
      await createAttestation({
        functionName: "createAttestation",
        args: [toAddress, message],
      });
      setMessage("");
      notification.success("Attestation created successfully!");
    } catch (error) {
      console.error("Error creating attestation:", error);
      notification.error("Error creating attestation");
    }
  };

  return (
    <div className="flex flex-col gap-4 p-4">
      <div className="flex flex-col gap-2">
        <h2 className="text-2xl font-bold">Create Attestation</h2>
        <div>
          <label className="block text-sm font-medium mb-1">To Address:</label>
          <AddressInput
            value={toAddress}
            onChange={setToAddress}
          />
        </div>
        <div>
          <label className="block text-sm font-medium mb-1">Message:</label>
          <textarea
            value={message}
            onChange={(e) => setMessage(e.target.value)}
            className="textarea textarea-bordered w-full"
            placeholder="Enter your attestation message"
            rows={3}
          />
        </div>
        <button
          className="btn btn-primary"
          onClick={handleCreateAttestation}
          disabled={!toAddress || !message}
        >
          Create Attestation
        </button>
      </div>

      <div className="flex flex-col gap-2 mt-4">
        <h2 className="text-2xl font-bold">View Attestations</h2>
        <div>
          <label className="block text-sm font-medium mb-1">Lookup Address:</label>
          <AddressInput
            value={lookupAddress}
            onChange={setLookupAddress}
          />
        </div>

        {receivedAttestations && Array.isArray(receivedAttestations) && receivedAttestations.length > 0 ? (
          <div className="mt-2">
            <h3 className="text-lg font-semibold">Received Attestations:</h3>
            <div className="space-y-2">
              {(receivedAttestations as AttestationData[]).map((attestation, index) => (
                <div key={index} className="card bg-base-200 p-4">
                  <p>From: <Address address={attestation.from} /></p>
                  <p>Message: {attestation.message}</p>
                  <p>Time: {new Date(Number(attestation.timestamp) * 1000).toLocaleString()}</p>
                </div>
              ))}
            </div>
          </div>
        ) : lookupAddress && (
          <p>No attestations found for this address</p>
        )}
      </div>
    </div>
  );
}; 