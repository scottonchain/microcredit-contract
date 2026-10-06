import { createHash } from "node:crypto";
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
import { rateLimited } from "~~/app/api/meta/rateLimit";
import { contractErrorName, describeContractError } from "~~/utils/contractErrors";
import { type ChainReads, type Entry, type IntentKey, Journal, decide, isTerminal, keyId, recover } from "~~/utils/relayerJournal";
import { FileStore } from "~~/utils/relayerJournalStore";

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
  /** True when the answer came from the journal: the same signed request had already landed. */
  replayed?: boolean;
};

/** Who signed the request and, for pool meta-transactions, the pool nonce they signed (see utils/relayerJournal.ts). */
export type RelayIntent = { signer: string; poolNonce?: string };

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

// ---- durable journal (utils/relayerJournal.ts; off unless RELAYER_JOURNAL_PATH is set) ----------------------------------
let journalState: { path: string; store: FileStore; journal: Journal } | undefined;
const recoveredChains = new Set<number>();

function journalFor() {
  const path = process.env.RELAYER_JOURNAL_PATH;
  if (!path) return undefined;
  if (!journalState || journalState.path !== path) {
    const store = new FileStore(path);
    journalState = { path, store, journal: Journal.replay(store.readLines()) };
    recoveredChains.clear();
  }
  return journalState;
}

const digestOf = (functionName: string, args: readonly unknown[]) =>
  createHash("sha256")
    .update(functionName + JSON.stringify(args, (_k, v) => (typeof v === "bigint" ? v.toString() : v)))
    .digest("hex");

function chainReads(publicClient: any, pool: Address, abi: Abi): ChainReads {
  return {
    receipt: async hash => {
      try {
        const r = await publicClient.getTransactionReceipt({ hash: hash as Hex });
        return { status: r.status as "success" | "reverted" };
      } catch (e: any) {
        if (e?.name === "TransactionReceiptNotFoundError") return undefined; // not mined yet: neither success nor absence
        throw e;
      }
    },
    poolNonce: async signer =>
      (await publicClient.readContract({ address: pool, abi, functionName: "nonces", args: [signer as Address] })) as bigint,
  };
}

/** Settles what the chain can settle for this chain's open entries, once per process and chain. Errors do not block relaying. */
async function recoverOnce(state: NonNullable<ReturnType<typeof journalFor>>, chainId: number, reads: ChainReads) {
  if (recoveredChains.has(chainId)) return;
  try {
    const done = await recover(state.journal, reads, new Date().toISOString(), e => e.key.chainId === chainId);
    for (const r of done) state.store.append(r.next);
    recoveredChains.add(chainId);
    if (done.length) console.log(`[relayer] journal recovery settled ${done.length} open intent(s) on chain ${chainId}`);
  } catch (e: any) {
    console.error("[relayer] journal recovery failed, will retry on the next request:", e?.message ?? e);
  }
}

/** Submits `functionName(args)` to the contract from the relayer and waits for it to be mined. */
export async function relay(params: {
  chainId: number;
  contractAddress: Address;
  functionName: string;
  args: readonly unknown[];
  intent?: RelayIntent;
}): Promise<RelayResult> {
  const { chainId, functionName, args } = params;
  const { address: contractAddress, abi } = resolveDeployment(chainId, params.contractAddress);
  const { publicClient, walletClient, address } = await getRelayer(chainId);
  console.log(`[relayer] ${functionName}`, { chainId, contractAddress, relayer: address });

  // Journal (off unless RELAYER_JOURNAL_PATH is set and the route names its signer): the intent is durable before the
  // first network call; a request already seen is answered from the journal; a lost outcome is settled from the chain.
  const state = params.intent ? journalFor() : undefined;
  let key: IntentKey | undefined;
  let entry: Entry | undefined;
  if (state && params.intent) {
    const reads = chainReads(publicClient, contractAddress, abi);
    await recoverOnce(state, chainId, reads);
    const digest = digestOf(functionName, args);
    key = {
      chainId,
      pool: contractAddress,
      signer: params.intent.signer,
      kind: params.intent.poolNonce !== undefined ? "pool" : "permit",
      nonce: params.intent.poolNonce ?? digest,
    };
    let d = decide(state.journal, key, digest, functionName, new Date().toISOString());
    if (d.action === "answer" && !isTerminal(d.entry.state)) {
      // An open entry from this process or an earlier one: let the chain settle what it can, then decide again.
      const done = await recover(state.journal, reads, new Date().toISOString(), e => keyId(e.key) === keyId(key!));
      for (const r of done) state.store.append(r.next);
      if (done.length) d = decide(state.journal, key, digest, functionName, new Date().toISOString());
    }
    if (d.action === "answer") {
      if (d.answer.status === 200 && d.entry.hash) {
        const receipt = await publicClient.getTransactionReceipt({ hash: d.entry.hash as Hex });
        return { hash: d.entry.hash as Hex, receipt, relayer: address, events: decodeEvents(abi, contractAddress, receipt), replayed: true };
      }
      const note = String(d.answer.body.note ?? d.answer.body.status);
      throw new RelayerError(d.entry.hash ? `${note} (transaction ${d.entry.hash})` : note, d.answer.status);
    }
    entry = d.entry;
    try {
      state.store.append(entry); // durable before any network call
    } catch (e: any) {
      state.journal.settle(key, "abandoned", "journal write failed; nothing was sent", new Date().toISOString());
      throw new RelayerError("The relayer journal is unavailable; the request was not sent", 503);
    }
  }

  const hash = await serialized(async () => {
    // Simulate first so reverts surface with their reason and never cost the relayer gas.
    let request;
    try {
      ({ request } = await publicClient.simulateContract({
        address: contractAddress,
        abi,
        functionName,
        args,
        account: walletClient.account!,
      }));
    } catch (e) {
      if (state && key) state.store.append(state.journal.settle(key, "abandoned", "simulation reverted before any send", new Date().toISOString()));
      throw e;
    }
    // From here on the outcome of a failed call is unknown: the entry stays open for recovery.
    return walletClient.writeContract(request);
  });
  if (state && key) state.store.append(state.journal.submitted(key, hash, new Date().toISOString()));
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (state && key) state.store.append(state.journal.outcome(key, receipt.status === "success" ? "success" : "reverted", new Date().toISOString()));
  if (receipt.status !== "success") throw new RelayerError(`Transaction ${hash} reverted`);

  return { hash, receipt, relayer: address, events: decodeEvents(abi, contractAddress, receipt) };
}

/** Standard fields every relayer route returns for a mined transaction. */
export function txResponse({ hash, receipt, relayer, replayed }: RelayResult) {
  return { txHash: hash, hash, status: "mined", receiptStatus: receipt.status, relayer, ...(replayed ? { replayed: true } : {}) };
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

/** The account that signed a relayer request, whichever route it is for. */
function signerOf(body: Record<string, any>): string | undefined {
  const signer = body.req?.borrower ?? body.req?.backer ?? body.req?.lender ?? body.borrower ?? body.lender;
  return typeof signer === "string" ? signer : undefined;
}

function clientIp(req: NextRequest): string {
  return req.headers.get("x-forwarded-for")?.split(",")[0].trim() || req.headers.get("x-real-ip") || "unknown";
}

/**
 * Wraps a POST handler: parses the JSON body, applies the relayer's rate limits (see rateLimit.ts)
 * and turns thrown errors into `{ error }` responses.
 */
export function relayerRoute(handler: (body: Record<string, any>) => Promise<Record<string, unknown>>) {
  return async (req: NextRequest) => {
    try {
      const body = await req.json();
      if (rateLimited(clientIp(req), signerOf(body))) {
        throw new RelayerError("Too many requests. Please wait a minute and try again.", 429);
      }
      return NextResponse.json(await handler(body));
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
