import { NextRequest, NextResponse } from "next/server";
import {
  type Abi,
  type Account,
  type Address,
  type Hex,
  type TransactionReceipt,
  createPublicClient,
  createWalletClient,
  decodeEventLog,
  defineChain,
  http,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import deployedContracts from "~~/contracts/deployedContracts";
import scaffoldConfig from "~~/scaffold.config";
import { contractErrorName, describeContractError } from "~~/utils/contractErrors";

/**
 * Shared server-side relayer for the /api/meta/* routes. Each route receives a payload signed by
 * the user (EIP-712 request and/or EIP-2612 permit) and submits it to DecentralizedMicrocredit,
 * paying gas from RELAYER_PRIVATE_KEY (or, on a local Anvil chain, its first unlocked account).
 */

const LOCAL_CHAIN_ID = 31337;

export class RelayerError extends Error {
  constructor(
    message: string,
    readonly status = 500,
  ) {
    super(message);
  }
}

export type PermitPayload = { value: string; deadline: string; v: number; r: Hex; s: Hex };

export type DecodedEvent = { eventName: string; args: Record<string, unknown> };

export type RelayResult = {
  hash: Hex;
  receipt: TransactionReceipt;
  relayer: Address;
  events: DecodedEvent[];
};

const deployments = deployedContracts as unknown as Record<
  number,
  { DecentralizedMicrocredit?: { address: Address; abi: Abi } }
>;
const TARGET_CHAIN_IDS = new Set<number>(scaffoldConfig.targetNetworks.map(network => network.id));

/**
 * Resolves the contract to call from server-side config only. The request's chainId and
 * contractAddress must match a known deployment, so the relayer can't be pointed at other
 * contracts or chains.
 */
function resolveDeployment(chainId: number, contractAddress: Address) {
  if (!TARGET_CHAIN_IDS.has(chainId)) throw new RelayerError(`Unsupported chain ${chainId}`, 400);
  const deployment = deployments[chainId]?.DecentralizedMicrocredit;
  if (!deployment) throw new RelayerError(`DecentralizedMicrocredit is not deployed on chain ${chainId}`);
  if (contractAddress?.toLowerCase() !== deployment.address.toLowerCase()) {
    throw new RelayerError("Unknown contract address", 400);
  }
  return deployment;
}

// One relayer key sends every transaction. Sends are serialized so concurrent requests can't
// pick the same account nonce; receipts are awaited outside the queue.
let sendQueue: Promise<unknown> = Promise.resolve();
function serialized<T>(send: () => Promise<T>): Promise<T> {
  const result = sendQueue.then(send, send);
  sendQueue = result.catch(() => undefined);
  return result;
}

function getRpcUrl(chainId: number): string {
  if (chainId === LOCAL_CHAIN_ID) return process.env.LOCAL_RPC_URL || "http://localhost:8545";
  return process.env.RPC_URL || "http://localhost:8545";
}

async function getRelayer(chainId: number) {
  const rpcUrl = getRpcUrl(chainId);
  const chain = defineChain({
    id: chainId,
    name: `chain-${chainId}`,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
  });
  const publicClient = createPublicClient({ chain, transport: http(rpcUrl) });

  let account: Account | Address;
  const pk = process.env.RELAYER_PRIVATE_KEY as Hex | undefined;
  if (pk) {
    account = privateKeyToAccount(pk);
  } else if (chainId === LOCAL_CHAIN_ID) {
    const [unlocked] = await createWalletClient({ chain, transport: http(rpcUrl) }).getAddresses();
    if (!unlocked) throw new RelayerError("Missing RELAYER_PRIVATE_KEY and no unlocked local accounts");
    account = unlocked;
  } else {
    throw new RelayerError("Missing RELAYER_PRIVATE_KEY");
  }

  const walletClient = createWalletClient({ account, chain, transport: http(rpcUrl) });
  const address = typeof account === "string" ? account : account.address;
  return { publicClient, walletClient, address };
}

/** Decodes the receipt's DecentralizedMicrocredit events (other contracts' logs are skipped). */
function decodeEvents(abi: Abi, contractAddress: Address, receipt: TransactionReceipt): DecodedEvent[] {
  return receipt.logs
    .filter(log => log.address.toLowerCase() === contractAddress.toLowerCase())
    .flatMap(log => {
      try {
        return [decodeEventLog({ abi, data: log.data, topics: log.topics }) as unknown as DecodedEvent];
      } catch {
        return [];
      }
    });
}

/** Submits `functionName(args)` to the contract from the relayer and waits for it to be mined. */
export async function relay(params: {
  chainId: number;
  contractAddress: Address;
  functionName: string;
  args: readonly unknown[];
}): Promise<RelayResult> {
  const { chainId, functionName, args } = params;
  const { address: contractAddress, abi } = resolveDeployment(chainId, params.contractAddress);
  const { publicClient, walletClient, address } = await getRelayer(chainId);
  console.log(`[relayer] ${functionName}`, { chainId, contractAddress, relayer: address });

  const hash = await serialized(async () => {
    // Simulate first so reverts surface with their reason and never cost the relayer gas.
    const { request } = await publicClient.simulateContract({
      address: contractAddress,
      abi,
      functionName,
      args,
      account: walletClient.account!,
    });
    return walletClient.writeContract(request);
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new RelayerError(`Transaction ${hash} reverted`);

  return { hash, receipt, relayer: address, events: decodeEvents(abi, contractAddress, receipt) };
}

/** Standard fields every relayer route returns for a mined transaction. */
export function txResponse({ hash, receipt, relayer }: RelayResult) {
  return { txHash: hash, hash, status: "mined", receiptStatus: receipt.status, relayer };
}

export function findEvent(result: RelayResult, eventName: string) {
  return result.events.find(event => event.eventName === eventName);
}

export function toPermitArg(permit: PermitPayload) {
  return {
    value: BigInt(permit.value),
    deadline: BigInt(permit.deadline),
    v: Number(permit.v),
    r: permit.r,
    s: permit.s,
  };
}

export function requireFields(body: Record<string, unknown>, ...fields: string[]) {
  if (fields.some(field => !body[field])) throw new RelayerError("Missing parameters", 400);
}

/** Wraps a POST handler: parses the JSON body and turns thrown errors into `{ error }` responses. */
export function relayerRoute(handler: (body: Record<string, any>) => Promise<Record<string, unknown>>) {
  return async (req: NextRequest) => {
    try {
      return NextResponse.json(await handler(await req.json()));
    } catch (e: any) {
      // A contract revert is the caller's problem (400) and gets plain-language text.
      const code = contractErrorName(e);
      const status = e instanceof RelayerError ? e.status : code ? 400 : 500;
      const message = describeContractError(e) || e?.shortMessage || e?.message || String(e);
      console.error("[relayer] error:", code ?? "", message);
      return NextResponse.json({ error: message, code }, { status });
    }
  };
}
