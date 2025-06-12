import { useState } from "react";
import { Address, AddressInput } from "../scaffold-eth";
import { useScaffoldWriteContract, useScaffoldReadContract } from "~~/hooks/scaffold-eth";
import { notification } from "~~/utils/scaffold-eth";
import { TransactionReceipt } from "viem";
import { ContractName } from "~~/utils/scaffold-eth/contract";

export const AttestationUI = () => {
  const [toAddress, setToAddress] = useState("");
  const [weight, setWeight] = useState("");
  const [lookupAddress, setLookupAddress] = useState("");

  const contractName = "YourContract" as ContractName;

  // Read attestations for a specific address
  const { data: receivedAttestations } = useScaffoldReadContract({
    contractName, 
    functionName: "getAttestations",
    args: [lookupAddress || "0x0000000000000000000000000000000000000000"],
  });

  const { writeContractAsync: recordAttestation } = useScaffoldWriteContract("YourContract");

  const handleRecordAttestation = async () => {
    if (!toAddress || !weight) return;
    try {
      notification.info("Recording attestation...");
      await recordAttestation({
        functionName: "recordAttestation", 
        args: [toAddress, BigInt(weight || "0")],
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
        <h2 className="text-2xl font-bold">Create Attestation</h2>
        <div>
          <label className="block text-sm font-medium mb-1">To Address:</label>
          <AddressInput
            value={toAddress}
            onChange={setToAddress}
          />
        </div>
        <div>
          <label className="block text-sm font-medium mb-1">Weight (0-1e18):</label>
          <input
            type="number"
            value={weight}
            onChange={(e) => {
              const val = e.target.value;
              if (!val || (Number(val) >= 0 && Number(val) <= 1e18)) {
                setWeight(val);
              }
            }}
            className="input input-bordered w-full"
            placeholder="Enter attestation weight"
            min="0"
            max="1000000000000000000"
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
          <label className="block text-sm font-medium mb-1">Lookup Address:</label>
          <AddressInput
            value={lookupAddress}
            onChange={setLookupAddress}
          />
        </div>

        {receivedAttestations && (receivedAttestations as any[]).length > 0 ? (
          <div className="mt-2">
            <h3 className="text-lg font-semibold">Received Attestations:</h3>
            <div className="space-y-2">
              {(receivedAttestations as any[]).map((attestation: any, index: number) => (
                <div key={index} className="card bg-base-200 p-4">
                  <p>From: <Address address={attestation.attester} /></p>
                  <p>Weight: {attestation.weight.toString()}</p>
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