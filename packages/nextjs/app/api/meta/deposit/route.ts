import { NextRequest, NextResponse } from "next/server";
import { createWalletClient, createPublicClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import deployedContracts from "~~/contracts/deployedContracts";

function getRpcUrl(chainId: number): string {
  if (chainId === 31337) return process.env.LOCAL_RPC_URL || "http://localhost:8545";
  return process.env.RPC_URL || "http://localhost:8545";
}

export async function POST(req: NextRequest) {
  try {
    const body = await req.json();
    const { chainId, contractAddress, lender, permit } = body as {
      chainId: number;
      contractAddress: `0x${string}`;
      lender: `0x${string}`;
      permit: { value: string; deadline: string; v: number; r: `0x${string}`; s: `0x${string}` };
    };

    if (!chainId || !contractAddress || !lender || !permit) {
      return NextResponse.json({ error: "Missing parameters" }, { status: 400 });
    }

    const pk = process.env.RELAYER_PRIVATE_KEY as `0x${string}` | undefined;
    const rpcUrl = getRpcUrl(chainId);

    const publicClient = createPublicClient({
      chain: { id: chainId, name: "custom", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [rpcUrl] } } } as any,
      transport: http(rpcUrl),
    });

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
        console.log("[API deposit] Using unlocked local relayer:", relayerAddress);
      } catch (e) {
        return NextResponse.json({ error: "Missing RELAYER_PRIVATE_KEY and no unlocked local accounts" }, { status: 500 });
      }
    } else {
      return NextResponse.json({ error: "Missing RELAYER_PRIVATE_KEY" }, { status: 500 });
    }

    const micro = (deployedContracts as any)[chainId]?.DecentralizedMicrocredit;
    if (!micro?.abi) return NextResponse.json({ error: "ABI not found for chain" }, { status: 500 });
    const abi = micro.abi as any;

    const permitArg = { value: BigInt(permit.value), deadline: BigInt(permit.deadline), v: permit.v, r: permit.r, s: permit.s } as const;

    console.log("[API deposit] Incoming:", {
      chainId,
      contractAddress,
      lender,
      permitValue: permitArg.value.toString(),
      permitDeadline: permitArg.deadline.toString(),
    });

    const txHash = await walletClient.writeContract({
      address: contractAddress,
      abi,
      functionName: "depositPermitOnlyMeta",
      args: [lender, permitArg],
      chain: undefined,
    });

    const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash, confirmations: 1 });

    return NextResponse.json({ txHash, status: "mined", relayer: relayerAddress, hash: txHash, receiptStatus: receipt.status });
  } catch (e: any) {
    const message = e?.shortMessage || e?.message || String(e);
    return NextResponse.json({ error: message }, { status: 500 });
  }
}
