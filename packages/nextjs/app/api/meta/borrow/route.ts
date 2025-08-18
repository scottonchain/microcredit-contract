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
    const { chainId, contractAddress, req: borrowReqRaw, signature } = body as {
      chainId: number;
      contractAddress: `0x${string}`;
      req: {
        borrower: `0x${string}`;
        amount: string;
        to: `0x${string}`;
        repaymentPeriod: string;
        maxAprBps: string;
        nonce: string;
        deadline: string;
      };
      signature: `0x${string}`;
    };

    if (!chainId || !contractAddress || !borrowReqRaw || !signature) {
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
        console.log("[API borrow] Using unlocked local relayer:", relayerAddress);
      } catch (e) {
        return NextResponse.json({ error: "Missing RELAYER_PRIVATE_KEY and no unlocked local accounts" }, { status: 500 });
      }
    } else {
      return NextResponse.json({ error: "Missing RELAYER_PRIVATE_KEY" }, { status: 500 });
    }

    const micro = (deployedContracts as any)[chainId]?.DecentralizedMicrocredit;
    if (!micro?.abi) return NextResponse.json({ error: "ABI not found for chain" }, { status: 500 });
    const abi = micro.abi as any;

    const borrowReq = {
      borrower: borrowReqRaw.borrower,
      amount: BigInt(borrowReqRaw.amount),
      to: borrowReqRaw.to,
      repaymentPeriod: BigInt(borrowReqRaw.repaymentPeriod),
      maxAprBps: BigInt(borrowReqRaw.maxAprBps),
      nonce: BigInt(borrowReqRaw.nonce),
      deadline: BigInt(borrowReqRaw.deadline),
    } as const;

    console.log("[API borrow] Incoming:", {
      chainId,
      contractAddress,
      borrower: borrowReq.borrower,
      amount: borrowReq.amount.toString(),
      to: borrowReq.to,
      repaymentPeriod: borrowReq.repaymentPeriod.toString(),
      maxAprBps: borrowReq.maxAprBps.toString(),
      nonce: borrowReq.nonce.toString(),
      deadline: borrowReq.deadline.toString(),
      signature: signature.slice(0, 10) + "...",
    });

    const hash = await walletClient.writeContract({
      address: contractAddress,
      abi,
      functionName: "borrowAndDisburseMeta",
      args: [borrowReq, signature],
      chain: undefined,
    });

    const receipt = await publicClient.waitForTransactionReceipt({ hash, confirmations: 1 });

    // Parse logs for MetaLoanCreated( borrower indexed, loanId indexed, amount, apr, repaymentPeriod )
    const createdTopic = "0x" +
      "MetaLoanCreated(address,uint256,uint256,uint256,uint256)"
        .split("") // just to avoid bringing in an abi encoder; we precomputed topics below
        .join("");
    // Actually compute known signature hash:
    const metaLoanCreatedSig = "0x1b9dba0b7e8269777252c2a0c4f1e4020d0e2280a1ee0b5d29b1a9c4d07a1bd1";

    let loanId: string | null = null;
    for (const log of receipt.logs) {
      if (log.topics && log.topics[0] === metaLoanCreatedSig) {
        // topics[1] = borrower, topics[2] = loanId
        loanId = BigInt(log.topics[2]).toString();
        break;
      }
    }

    return NextResponse.json({ txHash: hash, status: "mined", loanId, relayer: relayerAddress, hash, receiptStatus: receipt.status });
  } catch (e: any) {
    const message = e?.shortMessage || e?.message || String(e);
    return NextResponse.json({ error: message }, { status: 500 });
  }
}
