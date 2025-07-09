import { useState } from "react";
import { BanknotesIcon, PlusIcon, CheckCircleIcon } from "@heroicons/react/24/outline";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { formatUSDC } from "~~/utils/format";
import { useReadContract, useWriteContract } from "wagmi";
import { Address, erc20Abi } from "viem";
import deployedContracts from "~~/contracts/deployedContracts";

interface LendWizardProps {
  connectedAddress?: `0x${string}`;
}

const LendWizard: React.FC<LendWizardProps> = ({ connectedAddress }) => {
  // Pool info (for yield estimation)
  const { data: poolInfo } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "getPoolInfo",
  });
  const totalDeposits = poolInfo ? Number(poolInfo[0]) : 0;
  const lenderCount = poolInfo ? Number(poolInfo[2]) : 0;

  // Interest bounds (rough yield)
  const { data: rMin } = useScaffoldReadContract({ contractName: "DecentralizedMicrocredit", functionName: "rMin" });
  const { data: rMax } = useScaffoldReadContract({ contractName: "DecentralizedMicrocredit", functionName: "rMax" });
  const rMinPct = rMin ? (Number(rMin) / 10000).toFixed(2) : "-";
  const rMaxPct = rMax ? (Number(rMax) / 10000).toFixed(2) : "-";

  // Local state to track if user funded (since contract doesn\'t expose per-lender balances yet)
  const [hasFunded, setHasFunded] = useState(false);
  const [depositAmount, setDepositAmount] = useState("");
  const [isLoading, setIsLoading] = useState(false);

  const { writeContractAsync } = useScaffoldWriteContract({ contractName: "DecentralizedMicrocredit" });

  // Fetch USDC token address from microcredit contract
  const { data: usdcAddress } = useScaffoldReadContract({
    contractName: "DecentralizedMicrocredit",
    functionName: "usdc",
  });

  // Resolve microcredit contract address dynamically (assumes chainId 31337 local)
  const microcreditAddress = deployedContracts[31337]?.DecentralizedMicrocredit?.address as Address;

  // Read current allowance
  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: usdcAddress as Address | undefined,
    abi: erc20Abi,
    functionName: "allowance",
    args: [connectedAddress as Address, microcreditAddress],
    query: {
      enabled: Boolean(usdcAddress && connectedAddress && microcreditAddress),
    },
  });

  const { writeContractAsync: writeToken } = useWriteContract();

  const ensureAllowanceAndDeposit = async () => {
    if (!depositAmount || !connectedAddress || !usdcAddress) return;
    const amountInt = BigInt(Math.floor(parseFloat(depositAmount) * 1e6));

    // If allowance insufficient, approve first
    if (!allowance || allowance < amountInt) {
      await writeToken({
        address: usdcAddress as Address,
        abi: erc20Abi,
        functionName: "approve",
        args: [microcreditAddress as Address, amountInt],
      });
      await refetchAllowance();
    }

    await writeContractAsync({ functionName: "depositFunds", args: [amountInt] });
  };

  const handleDeposit = async () => {
    setIsLoading(true);
    try { await ensureAllowanceAndDeposit(); setHasFunded(true); setDepositAmount(""); } catch(e){ console.error(e);} finally{ setIsLoading(false);} }

  return (
    <div className="bg-base-100 rounded-lg p-6 shadow-lg">
      <h3 className="text-lg font-semibold mb-4 flex items-center">
        <BanknotesIcon className="h-5 w-5 mr-2" />
        Earn Interest
      </h3>

      {!hasFunded ? (
        <div className="space-y-4 text-sm text-gray-700">
          <p>
            Deposit USDC into the shared lending pool and earn interest from borrowers. Current loans pay between {rMinPct}%
            and {rMaxPct}% APR. There are currently <span className="font-semibold">{lenderCount}</span> active lenders with a
            total of <span className="font-semibold">{formatUSDC(BigInt(totalDeposits))}</span> USDC deposited.
          </p>
          <div className="flex gap-2">
            <input
              type="number"
              value={depositAmount}
              onChange={e => setDepositAmount(e.target.value)}
              placeholder="Amount (USDC)"
              className="flex-1 p-2 border border-gray-300 rounded-lg"
              min="1"
            />
            <button
              className="btn btn-primary flex items-center"
              disabled={!depositAmount || isLoading}
              onClick={handleDeposit}
            >
              <PlusIcon className="h-4 w-4 mr-1" />
              {isLoading ? "Depositing..." : "Deposit"}
            </button>
          </div>
        </div>
      ) : (
        <div className="text-green-700 flex items-center space-x-2">
          <CheckCircleIcon className="h-5 w-5" />
          <span>You have funded the pool. Track your earnings on the Lend page.</span>
        </div>
      )}
    </div>
  );
};

export default LendWizard; 