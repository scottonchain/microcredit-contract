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
    const { chainId, contractAddress, req: disburseReqRaw, signature } = body as {
      chainId: number;
      contractAddress: `0x${string}`;
      req: { borrower: `0x${string}`; loanId: string; to: `0x${string}`; nonce: string; deadline: string };
      signature: `0x${string}`;
    };

    if (!chainId || !contractAddress || !disburseReqRaw || !signature) {
      return NextResponse.json({ error: "Missing parameters" }, { status: 400 });
    }

    const rpcUrl = getRpcUrl(chainId);

    const publicClient = createPublicClient({
      chain: { id: chainId, name: "custom", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [rpcUrl] } } } as any,
      transport: http(rpcUrl),
    });

    // Resolve relayer account
    const pk = process.env.RELAYER_PRIVATE_KEY as `0x${string}` | undefined;
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
      try {
        const accounts = (await (publicClient as any).request({ method: "eth_accounts" })) as string[];
        if (!accounts || accounts.length === 0) throw new Error("No unlocked accounts");
        relayerAddress = accounts[0] as `0x${string}`;
        walletClient = createWalletClient({
          account: relayerAddress,
          chain: { id: chainId, name: "custom", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [rpcUrl] } } } as any,
          transport: http(rpcUrl),
        });
        console.log("[API disburse-loan] Using unlocked local relayer:", relayerAddress);
      } catch (e) {
        return NextResponse.json({ error: "Missing RELAYER_PRIVATE_KEY and no unlocked local accounts" }, { status: 500 });
      }
    } else {
      return NextResponse.json({ error: "Missing RELAYER_PRIVATE_KEY" }, { status: 500 });
    }

    const micro = (deployedContracts as any)[chainId]?.DecentralizedMicrocredit;
    if (!micro?.abi) return NextResponse.json({ error: "ABI not found for chain" }, { status: 500 });
    const abi = micro.abi as any;

    const disburseReq = {
      borrower: disburseReqRaw.borrower,
      loanId: BigInt(disburseReqRaw.loanId),
      to: disburseReqRaw.to,
      nonce: BigInt(disburseReqRaw.nonce),
      deadline: BigInt(disburseReqRaw.deadline),
    } as const;

    const hash = await walletClient.writeContract({
      address: contractAddress,
      abi,
      functionName: "disburseLoanMeta",
      args: [disburseReq, signature],
      chain: undefined,
    });

    // Wait for 1 confirmation to ensure transaction is mined
    const receipt = await publicClient.waitForTransactionReceipt({ 
      hash, 
      confirmations: 1 
    });

    // Detect USDC Transfer(to=borrower)
    let transferred = false as boolean;
    let transferAmount: string | null = null;
    try {
      const usdcAddress = (await publicClient.readContract({
        address: contractAddress,
        abi,
        functionName: "usdc",
        args: [],
      })) as `0x${string}`;

      // ERC20 Transfer event signature
      const transferTopic =
        "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef" as const;

      for (const log of receipt.logs) {
        if (
          log.address.toLowerCase() === usdcAddress.toLowerCase() &&
          log.topics?.[0] === transferTopic &&
          // topics[2] is indexed 'to'
          log.topics?.[2]?.toLowerCase() ===
            ("0x000000000000000000000000" + disburseReq.borrower.slice(2)).toLowerCase()
        ) {
          transferred = true;
          // data is amount as 32-byte hex
          if (log.data && log.data !== "0x") {
            try {
              transferAmount = BigInt(log.data).toString();
            } catch {}
          }
          break;
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
