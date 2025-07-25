"use client";

import { useState, useEffect } from "react";
import { useAccount } from "wagmi";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";

const DebugApprovePage = () => {
  const { address: connectedAddress } = useAccount();
  const [spender, setSpender] = useState("");
  const [amount, setAmount] = useState("1000");
  const [log, setLog] = useState<string[]>([]);
  const [txHash, setTxHash] = useState<string | null>(null);
  const [contractName, setContractName] = useState<"MockUSDC" | "DecentralizedMicrocredit">("MockUSDC");
  const [allowance, setAllowance] = useState<bigint | null>(null);

  const { writeContractAsync } = useScaffoldWriteContract(contractName);

  // Read allowance
  const { data: allowanceData, refetch: refetchAllowance } = useScaffoldReadContract({
    contractName,
    functionName: "allowance",
    args:
      connectedAddress && spender
        ? ([connectedAddress as `0x${string}`, spender as `0x${string}`] as any)
        : undefined,
  });

  useEffect(() => {
    setAllowance(allowanceData ?? null);
  }, [allowanceData]);

  useEffect(() => {
    setLog(l => [
      `[Effect] connectedAddress: ${connectedAddress}, spender: ${spender}, amount: ${amount}, contract: ${contractName}, allowance: ${allowance}`,
      ...l,
    ]);
    console.log("[DebugApprove] connectedAddress:", connectedAddress, "spender:", spender, "amount:", amount, "contract:", contractName, "allowance:", allowance);
  }, [connectedAddress, spender, amount, contractName, allowance]);

  const handleApprove = async () => {
    setLog(l => [
      `[Action] Approve called: contract=${contractName}, spender=${spender}, amount=${amount}`,
      ...l,
    ]);
    try {
      if (!connectedAddress || !spender || !amount) {
        setLog(l => ["[Error] Missing connected address, spender, or amount", ...l]);
        return;
      }
      const parsedAmount = BigInt(Math.floor(Number(amount) * 1e6));
      setLog(l => [
        `[Action] Sending approve: spender=${spender}, amount=${parsedAmount.toString()}`,
        ...l,
      ]);
      const txHashStr = await writeContractAsync({
        functionName: "approve",
        args: [spender, parsedAmount],
      });
      setTxHash(txHashStr ?? null);
      setLog(l => [
        `[Result] Approve tx sent: ${txHashStr}`,
        ...l,
      ]);
      await refetchAllowance();
    } catch (err: any) {
      setLog(l => [
        `[Error] Approve failed: ${err?.message || err}`,
        ...l,
      ]);
      console.error("[DebugApprove] Approve error:", err);
    }
  };

  return (
    <div style={{ padding: 32 }}>
      <h1>Debug ERC20 Approve</h1>
      <div style={{ marginBottom: 16 }}>
        <label>Contract:
          <select
            value={contractName}
            onChange={e => setContractName(e.target.value as "MockUSDC" | "DecentralizedMicrocredit")}
            style={{ marginLeft: 8 }}
          >
            <option value="MockUSDC">MockUSDC</option>
            {/* Add more contracts if needed */}
          </select>
        </label>
      </div>
      <div style={{ marginBottom: 16 }}>
        <label>Spender Address:
          <input type="text" value={spender} onChange={e => setSpender(e.target.value)} style={{ marginLeft: 8, width: 400 }} placeholder="0x..." />
        </label>
      </div>
      <div style={{ marginBottom: 16 }}>
        <label>Amount (USDC):
          <input type="number" value={amount} onChange={e => setAmount(e.target.value)} style={{ marginLeft: 8, width: 120 }} />
        </label>
      </div>
      <div style={{ marginBottom: 16 }}>
        <button onClick={handleApprove} style={{ padding: 8, background: '#eee', borderRadius: 4 }}>
          Approve
        </button>
      </div>
      <div style={{ marginBottom: 16 }}>
        <strong>Current Allowance:</strong> {allowance !== null ? allowance.toString() : "-"}
      </div>
      {txHash && (
        <div style={{ marginBottom: 16 }}>
          <strong>Last Tx Hash:</strong> {txHash}
        </div>
      )}
      <div style={{ marginTop: 32 }}>
        <h2>Debug Log</h2>
        <pre style={{ background: '#f8f8f8', padding: 16, borderRadius: 4, maxHeight: 400, overflow: 'auto' }}>
          {log.join('\n')}
        </pre>
      </div>
    </div>
  );
};

export default DebugApprovePage; 