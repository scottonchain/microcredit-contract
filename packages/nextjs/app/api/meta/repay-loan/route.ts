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
    const { chainId, contractAddress, req: repayReqRaw, signature, permit } = body as {
      chainId: number;
      contractAddress: `0x${string}`;
      req: { borrower: `0x${string}`; loanId: string; amount: string; nonce: string; deadline: string };
      signature: `0x${string}`;
      permit?: { value: string; deadline: string; v: number; r: `0x${string}`; s: `0x${string}` };
    };

    if (!chainId || !contractAddress || !repayReqRaw || !signature) {
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
    let walletClient;
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
        console.log("[API repay-loan] Using unlocked local relayer:", relayerAddress);
      } catch (e) {
        return NextResponse.json({ error: "Missing RELAYER_PRIVATE_KEY and no unlocked local accounts" }, { status: 500 });
      }
    } else {
      return NextResponse.json({ error: "Missing RELAYER_PRIVATE_KEY" }, { status: 500 });
    }

    const micro = (deployedContracts as any)[chainId]?.DecentralizedMicrocredit;
    if (!micro?.abi) return NextResponse.json({ error: "ABI not found for chain" }, { status: 500 });
    const abi = micro.abi as any;

    const repayReq = {
      borrower: repayReqRaw.borrower,
      loanId: BigInt(repayReqRaw.loanId),
      amount: BigInt(repayReqRaw.amount),
      nonce: BigInt(repayReqRaw.nonce),
      deadline: BigInt(repayReqRaw.deadline),
    } as const;

    const permitArg = permit
      ? {
          value: BigInt(permit.value),
          deadline: BigInt(permit.deadline),
          v: permit.v,
          r: permit.r,
          s: permit.s,
        }
      : { value: 0n, deadline: 0n, v: 0, r: "0x0000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`, s: "0x0000000000000000000000000000000000000000000000000000000000000000" as `0x${string}` };

    console.log("[API repay-loan] Incoming:", {
      chainId,
      contractAddress,
      borrower: repayReq.borrower,
      loanId: repayReq.loanId.toString(),
      amount: repayReq.amount.toString(),
      nonce: repayReq.nonce.toString(),
      deadline: repayReq.deadline.toString(),
      hasPermit: !!permit,
      signature: signature.slice(0, 10) + "...",
    });

    const hash = await walletClient.writeContract({
      address: contractAddress,
      abi,
      functionName: "repayLoanMeta",
      args: [repayReq, signature, permitArg],
      chain: undefined,
    });

    // Wait for 1 confirmation to ensure transaction is mined
    const receipt = await publicClient.waitForTransactionReceipt({ 
      hash, 
      confirmations: 1 
    });

    // Try to detect an ERC20 Transfer from borrower to contract
    let transferred = false;
    let transferAmount: string | null = null;
    try {
      const usdcAddress = (await publicClient.readContract({
        address: contractAddress,
        abi,
        functionName: "usdc",
        args: [],
      })) as `0x${string}`;
      const transferTopic = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"; // Transfer(address,address,uint256)
      for (const log of receipt.logs) {
        if (log.address.toLowerCase() === usdcAddress.toLowerCase() && log.topics?.[0] === transferTopic) {
          const from = `0x${log.topics[1].slice(26)}`.toLowerCase();
          const to = `0x${log.topics[2].slice(26)}`.toLowerCase();
          if (from === repayReq.borrower.toLowerCase()) {
            transferred = true;
            transferAmount = BigInt(log.data as string).toString();
            break;
          }
        }
      }
    } catch {}

    return NextResponse.json({ 
      txHash: hash, 
      status: "mined", 
      transferred, 
      transferAmount, 
      relayer: relayerAddress,
      // Legacy fields for compatibility
      hash,
      receiptStatus: receipt.status
    });
  } catch (e: any) {
    const message = e?.shortMessage || e?.message || String(e);
    return NextResponse.json({ error: message }, { status: 500 });
  }
}
