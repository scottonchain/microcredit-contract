import { useState } from "react";
import { Address, AddressInput } from "../scaffold-eth";
import { useScaffoldWriteContract, useScaffoldReadContract } from "~~/hooks/scaffold-eth";
import { notification } from "~~/utils/scaffold-eth";
import { TransactionReceipt } from "viem";
import { ContractName } from "~~/utils/scaffold-eth/contract";

interface AttestationData {
  attester: string;
  weight: bigint;
  timestamp: bigint;
}

export const AttestationUI = () => {
  const [toAddress, setToAddress] = useState("");
  const [weight, setWeight] = useState("");
  const [lookupAddress, setLookupAddress] = useState("");

  const contractName = "YourContract" as ContractName;

  // Read attestations for a specific address
  const { data: attestations } = useScaffoldReadContract({
    contractName, 
    functionName: "getAttestations",
    args: [lookupAddress || "0x0000000000000000000000000000000000000000"],
  });

  const { writeContractAsync: recordAttestation } = useScaffoldWriteContract(contractName);

  const handleRecordAttestation = async () => {
    if (!toAddress || !weight) return;
    try {
      const weightValue = BigInt(weight);
      notification.info("Recording attestation...");
      await recordAttestation({
        functionName: "recordAttestation",
        args: [toAddress, weightValue],
      });
      setWeight("");
      notification.success("Attestation recorded successfully!");
    } catch (error) {
      console.error("Error recording attestation:", error);
      notification.error("Error recording attestation");
    }
  };

  return (
    <div className="flex flex-col gap-4 p-4">
      <div className="flex flex-col gap-2">
        <h2 className="text-2xl font-bold">Record Attestation</h2>
        <div>
          <label className="block text-sm font-medium mb-1">Borrower Address:</label>
          <AddressInput
            value={toAddress}
            onChange={setToAddress}
          />
        </div>
        <div>
          <label className="block text-sm font-medium mb-1">Weight (0-1000000):</label>
          <input
            type="number"
            value={weight}
            onChange={(e) => setWeight(e.target.value)}
            className="input input-bordered w-full"
            placeholder="Enter weight (0-1000000)"
            min="0"
            max="1000000"
          />
        </div>
        <button
          className="btn btn-primary"
          onClick={handleRecordAttestation}
          disabled={!toAddress || !weight}
        >
          Record Attestation
        </button>
      </div>

      <div className="flex flex-col gap-2 mt-4">
        <h2 className="text-2xl font-bold">View Attestations</h2>
        <div>
          <label className="block text-sm font-medium mb-1">Borrower Address:</label>
          <AddressInput
            value={lookupAddress}
            onChange={setLookupAddress}
          />
        </div>

        {attestations && Array.isArray(attestations) && attestations.length > 0 ? (
          <div className="mt-2">
            <h3 className="text-lg font-semibold">Attestations:</h3>
            <div className="space-y-2">
              {(attestations as AttestationData[]).map((attestation, index) => (
                <div key={index} className="card bg-base-200 p-4">
                  <p>Attester: <Address address={attestation.attester} /></p>
                  <p>Weight: {Number(attestation.weight)}</p>
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