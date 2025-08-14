import { NextRequest, NextResponse } from "next/server";
import { createWalletClient, createPublicClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import deployedContracts from "~~/contracts/deployedContracts";

// Simple RPC resolver per chain. For localhost (31337) use local Anvil/Hardhat.
function getRpcUrl(chainId: number): string {
  if (chainId === 31337) return process.env.LOCAL_RPC_URL || "http://localhost:8545";
  return process.env.RPC_URL || "http://localhost:8545";
}

export async function POST(req: NextRequest) {
  try {
    const body = await req.json();
    const { chainId, contractAddress, req: loanReqRaw, signature } = body as {
      chainId: number;
      contractAddress: `0x${string}`;
      req: { borrower: `0x${string}`; amount: string; nonce: string; deadline: string };
      signature: `0x${string}`;
    };

    if (!chainId || !contractAddress || !loanReqRaw || !signature) {
      return NextResponse.json({ error: "Missing parameters" }, { status: 400 });
    }

    const pk = process.env.RELAYER_PRIVATE_KEY as `0x${string}` | undefined;
    const rpcUrl = getRpcUrl(chainId);

    // Create public client for raw RPC access
    const publicClient = createPublicClient({
      chain: { id: chainId, name: "custom", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [rpcUrl] } } } as any,
      transport: http(rpcUrl),
    });

    // Resolve relayer account
    let relayerAddress: `0x${string}` | undefined;
    let walletClient;
    if (pk) {
      const account = privateKeyToAccount(pk);
      relayerAddress = account.address as `0x${string}`;
      walletClient = createWalletClient({
        account,
        chain: { id: chainId, name: "custom", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [rpcUrl] } } } as any,
        transport: http(rpcUrl),
      });
    } else if (chainId === 31337) {
      // Hardhat/Anvil fallback: use first unlocked account from node
      try {
        const accounts = (await (publicClient as any).request({ method: "eth_accounts" })) as string[];
        if (!accounts || accounts.length === 0) throw new Error("No unlocked accounts");
        relayerAddress = accounts[0] as `0x${string}`;
        walletClient = createWalletClient({
          account: relayerAddress,
          chain: { id: chainId, name: "custom", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [rpcUrl] } } } as any,
          transport: http(rpcUrl),
        });
        console.log("[API request-loan] Using unlocked local relayer:", relayerAddress);
      } catch (e) {
        return NextResponse.json({ error: "Missing RELAYER_PRIVATE_KEY and no unlocked local accounts" }, { status: 500 });
      }
    } else {
      return NextResponse.json({ error: "Missing RELAYER_PRIVATE_KEY" }, { status: 500 });
    }

    const micro = (deployedContracts as any)[chainId]?.DecentralizedMicrocredit;
    if (!micro?.abi) return NextResponse.json({ error: "ABI not found for chain" }, { status: 500 });
    const abi = micro.abi as any;

    // Convert string fields to bigint
    const loanReq = {
      borrower: loanReqRaw.borrower,
      amount: BigInt(loanReqRaw.amount),
      nonce: BigInt(loanReqRaw.nonce),
      deadline: BigInt(loanReqRaw.deadline),
    } as const;

    // Server-side logs to aid debugging without DevTools
    console.log("[API request-loan] Incoming:", {
      chainId,
      contractAddress,
      borrower: loanReq.borrower,
      amount: loanReq.amount.toString(),
      nonce: loanReq.nonce.toString(),
      deadline: loanReq.deadline.toString(),
      signature: signature.slice(0, 10) + "...",
    });

    // Send meta request
    const hash = await walletClient.writeContract({
      address: contractAddress,
      abi,
      functionName: "requestLoanMeta",
      args: [loanReq, signature],
      // Explicitly undefined to satisfy viem type union when using custom chain object
      chain: undefined,
    });

    // Wait for 1 confirmation to ensure transaction is mined
    const receipt = await publicClient.waitForTransactionReceipt({ 
      hash, 
      confirmations: 1 
    });
    console.log("[API request-loan] Tx sent:", { hash, status: receipt.status });

    // Query latest loanId for borrower
    const loanIds = (await publicClient.readContract({
      address: contractAddress,
      abi,
      functionName: "getBorrowerLoanIds",
      args: [loanReq.borrower],
    })) as bigint[];

    const loanId = loanIds.length > 0 ? loanIds[loanIds.length - 1] : null;
    const loanIdStr = loanId !== null ? loanId.toString() : null;
    console.log("[API request-loan] Derived loanId:", loanIdStr);

    return NextResponse.json({ 
      txHash: hash, 
      status: "mined", 
      loanId: loanIdStr, 
      relayer: relayerAddress,
      // Legacy fields for compatibility
      hash,
      receiptStatus: receipt.status
    });
  } catch (e: any) {
    const message = e?.shortMessage || e?.message || String(e);
    console.error("[API request-loan] Error:", message);
    return NextResponse.json({ error: message }, { status: 500 });
  }
}
