import { NextRequest, NextResponse } from "next/server";
import { createWalletClient, createPublicClient, decodeEventLog, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import deployedContracts from "~~/contracts/deployedContracts";

function getRpcUrl(chainId: number): string {
  if (chainId === 31337) return process.env.LOCAL_RPC_URL || "http://localhost:8545";
  return process.env.RPC_URL || "http://localhost:8545";
}

export async function POST(req: NextRequest) {
  try {
    const body = await req.json();
    const { chainId, contractAddress, req: requestRaw, signature } = body as {
      chainId: number;
      contractAddress: `0x${string}`;
      req: { lender: `0x${string}`; amount: string; to: `0x${string}`; nonce: string; deadline: string };
      signature: `0x${string}`;
    };

    if (!chainId || !contractAddress || !requestRaw || !signature) {
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
        console.log("[API request-withdrawal] Using unlocked local relayer:", relayerAddress);
      } catch (e) {
        return NextResponse.json({ error: "Missing RELAYER_PRIVATE_KEY and no unlocked local accounts" }, { status: 500 });
      }
    } else {
      return NextResponse.json({ error: "Missing RELAYER_PRIVATE_KEY" }, { status: 500 });
    }

    const micro = (deployedContracts as any)[chainId]?.DecentralizedMicrocredit;
    if (!micro?.abi) return NextResponse.json({ error: "ABI not found for chain" }, { status: 500 });
    const abi = micro.abi as any;

    const rq = {
      lender: requestRaw.lender,
      amount: BigInt(requestRaw.amount),
      to: requestRaw.to,
      nonce: BigInt(requestRaw.nonce),
      deadline: BigInt(requestRaw.deadline),
    } as const;

    console.log("[API request-withdrawal] Incoming:", {
      chainId,
      contractAddress,
      lender: rq.lender,
      amount: rq.amount.toString(),
      to: rq.to,
      nonce: rq.nonce.toString(),
      deadline: rq.deadline.toString(),
      signature: signature.slice(0, 10) + "...",
    });

    const txHash = await walletClient.writeContract({
      address: contractAddress,
      abi,
      functionName: "requestWithdrawalMeta",
      args: [rq, signature],
      chain: undefined,
    });

    const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash, confirmations: 1 });

    // Decode events for queueId and partial fill
    let queueId: string | null = null;
    let amountQueued: string | null = null;
    let amountFilledNow = 0n;

    for (const log of receipt.logs) {
      try {
        const decoded = decodeEventLog({ abi: abi as any, data: log.data, topics: log.topics }) as unknown as {
          eventName: string;
          args: Record<string, unknown>;
        };
        if (decoded.eventName === "MetaWithdrawalRequested") {
          const { queueId: qid, amount } = decoded.args as any;
          queueId = BigInt(qid).toString();
          amountQueued = BigInt(amount).toString();
        }
        if (decoded.eventName === "MetaWithdrawalFilled") {
          const { amountFilled } = decoded.args as any;
          amountFilledNow += BigInt(amountFilled);
        }
      } catch {}
    }

    return NextResponse.json({ txHash, status: "mined", queueId, amountQueued, amountFilledNow: amountFilledNow.toString(), relayer: relayerAddress, hash: txHash, receiptStatus: receipt.status });
  } catch (e: any) {
    const message = e?.shortMessage || e?.message || String(e);
    return NextResponse.json({ error: message }, { status: 500 });
  }
}
