import { NextRequest, NextResponse } from "next/server";
import { createWalletClient, createPublicClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import deployedContracts from "~~/contracts/deployedContracts";

function getRpcUrl(chainId: number): string {
  if (chainId === 31337) return process.env.LOCAL_RPC_URL || "http://localhost:8545";
  return process.env.RPC_URL || "http://localhost:8545";
}

// MUST NOT require any borrower signature besides the EIP-2612 Permit that the client sends
export async function POST(req: NextRequest) {
  try {
    const body = await req.json();
    // Hard assertion: reject any legacy meta-sig payloads
    if ((body as any).signature || (body as any).req) {
      return NextResponse.json({ error: "RepayRequest/meta signature is not allowed; use permit-only" }, { status: 400 });
    }
    const { chainId, contractAddress, borrower, loanId, amount, permit } = body as {
      chainId: number;
      contractAddress: `0x${string}`;
      borrower: `0x${string}`;
      loanId: string;
      amount: string; // "0" means repay-all up to permit value
      permit: { value: string; deadline: string; v: number; r: `0x${string}`; s: `0x${string}` };
    };

    if (!chainId || !contractAddress || !borrower || !loanId || !amount || !permit) {
      return NextResponse.json({ error: "Missing parameters" }, { status: 400 });
    }

    const pk = process.env.RELAYER_PRIVATE_KEY as `0x${string}` | undefined;
    const rpcUrl = getRpcUrl(chainId);

    const publicClient = createPublicClient({
      chain: { id: chainId, name: "custom", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [rpcUrl] } } } as any,
      transport: http(rpcUrl),
    });

    // Resolve relayer
    let relayerAddress: `0x${string}` | undefined;
    let walletClient: any;
    if (pk) {
      const account = privateKeyToAccount(pk);
      relayerAddress = account.address as `0x${string}`;
      walletClient = createWalletClient({ account, chain: { id: chainId } as any, transport: http(rpcUrl) });
    } else if (chainId === 31337) {
      try {
        const accounts = (await (publicClient as any).request({ method: "eth_accounts" })) as string[];
        if (!accounts || accounts.length === 0) throw new Error("No unlocked accounts");
        relayerAddress = accounts[0] as `0x${string}`;
        walletClient = createWalletClient({ account: relayerAddress, chain: { id: chainId } as any, transport: http(rpcUrl) });
        console.log("[API repay-one] Using unlocked local relayer:", relayerAddress);
      } catch (e) {
        return NextResponse.json({ error: "Missing RELAYER_PRIVATE_KEY and no unlocked local accounts" }, { status: 500 });
      }
    } else {
      return NextResponse.json({ error: "Missing RELAYER_PRIVATE_KEY" }, { status: 500 });
    }

    const micro = (deployedContracts as any)[chainId]?.DecentralizedMicrocredit;
    if (!micro?.abi) return NextResponse.json({ error: "ABI not found for chain" }, { status: 500 });
    const abi = micro.abi as any;

    // Optionally read current outstanding (rounded) for UI amountUsed when amount == "0"
    let priorOutRounded: bigint | undefined;
    if (amount === "0") {
      try {
        priorOutRounded = (await publicClient.readContract({
          address: contractAddress,
          abi,
          functionName: "getOutstandingRoundedToCent",
          args: [BigInt(loanId)],
        })) as bigint;
      } catch {}
    }

    console.log("[API repay-one] Incoming:", {
      chainId,
      contractAddress,
      borrower,
      loanId,
      amount,
      permitValue: permit.value,
      permitDeadline: permit.deadline,
    });

    const txHash = await walletClient.writeContract({
      address: contractAddress,
      abi,
      functionName: "repayWithPermit",
      args: [
        borrower,
        BigInt(loanId),
        BigInt(amount),
        BigInt(permit.value),
        BigInt(permit.deadline),
        Number(permit.v),
        permit.r,
        permit.s,
      ],
      chain: undefined,
    });

    const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash, confirmations: 1 });

    // Compute amountUsed best-effort for UI
    let amountUsed: string | undefined;
    try {
      const p = BigInt(permit.value);
      const a = BigInt(amount);
      if (amount === "0" && priorOutRounded !== undefined) {
        amountUsed = (priorOutRounded < p ? priorOutRounded : p).toString();
      } else {
        amountUsed = (a < p ? a : p).toString();
      }
    } catch {}

    return NextResponse.json({ txHash, status: "mined", relayer: relayerAddress, amountUsed });
  } catch (e: any) {
    const message = e?.shortMessage || e?.message || String(e);
    return NextResponse.json({ error: message }, { status: 500 });
  }
}
