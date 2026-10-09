import { IntentFlights } from "~~/utils/relayerConcurrency";
import { RelayerError, permitArg, relayerRpcUrl, requestBody } from "~~/utils/relayerRequest";
export { RelayerError, requireFields } from "~~/utils/relayerRequest";
import { NextRequest, NextResponse } from "next/server";
import { createHash } from "node:crypto";
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
  encodeFunctionData,
  http,
  keccak256,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { rateLimited } from "~~/app/api/meta/rateLimit";
import deployedContracts from "~~/contracts/deployedContracts";
import scaffoldConfig from "~~/scaffold.config";
import { contractErrorName, describeContractError } from "~~/utils/contractErrors";
import {
  type ChainReads,
  type Entry,
  type IntentKey,
  Journal,
  decide,
  isTerminal,
  keyId,
  recover,
} from "~~/utils/relayerJournal";
import { FileStore } from "~~/utils/relayerJournalStore";
import {
  BroadcastUnconfirmed,
  JournalWriteFailed,
  messageOf,
  rebroadcast,
  sendHashFirst,
} from "~~/utils/relayerSend";

/**
 * Shared server-side relayer for the /api/meta/* routes. Each route receives a payload signed by
 * the user (EIP-712 request and/or EIP-2612 permit) and submits it to DecentralizedMicrocredit,
 * paying gas from RELAYER_PRIVATE_KEY (or, on a local Anvil chain, its first unlocked account).
 */

const LOCAL_CHAIN_ID = 31337;

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

async function getRelayer(chainId: number) {
  const rpcUrl = relayerRpcUrl(chainId, process.env);
  const chain = defineChain({
    id: chainId,
    name: `chain-${chainId}`,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
  });
  const publicClient = createPublicClient({ chain, transport: http(rpcUrl) });

  if (await publicClient.getChainId() !== chainId) throw new RelayerError("The relayer RPC is on the wrong chain", 503);

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
let journalState: {
  path: string;
  store: FileStore;
  journal: Journal;
  recovered: Set<string>;
  recovering: Map<string, Promise<void>>;
} | undefined;
const flights = new IntentFlights<RelayResult>();

function journalFor() {
  const path = process.env.RELAYER_JOURNAL_PATH;
  if (!path) return undefined;
  if (!journalState || journalState.path !== path) {
    const store = new FileStore(path);
    journalState = { path, store, journal: Journal.replay(store.readLines()), recovered: new Set(), recovering: new Map() };
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
      (await publicClient.readContract({
        address: pool,
        abi,
        functionName: "nonces",
        args: [signer as Address],
      })) as bigint,
  };
}

/** Share initial recovery for a deployment. Failed reads stay open; a failed durable write blocks relaying. */
async function recoverOnce(state: NonNullable<ReturnType<typeof journalFor>>, chainId: number, pool: Address, reads: ChainReads) {
  const deploymentKey = `${chainId}:${pool.toLowerCase()}`;
  if (state.recovered.has(deploymentKey)) return;
  const active = state.recovering.get(deploymentKey);
  if (active) return active;
  const pending = Promise.resolve().then(async () => {
    let readFailures = 0;
    const done = await recover(
      state.journal,
      reads,
      new Date().toISOString(),
      e => e.key.chainId === chainId && e.key.pool.toLowerCase() === pool.toLowerCase() && !flights.has(keyId(e.key)),
      (_e, err) => {
        readFailures += 1;
        console.error("[relayer] journal read failed; the entry stays open:", messageOf(err));
      },
      entry => state.store.append(entry),
    );
    if (readFailures === 0) state.recovered.add(deploymentKey); // otherwise try again on the next request
    if (done.length)
      console.log(`[relayer] journal recovery settled ${done.length} open intent(s) on chain ${chainId}`);
  }).catch((e: unknown) => {
    console.error("[relayer] journal recovery failed, will retry on the next request:", messageOf(e));
    throw new RelayerError("The relayer journal is unavailable; the request was not sent", 503);
  });
  state.recovering.set(deploymentKey, pending);
  try {
    await pending;
  } finally {
    state.recovering.delete(deploymentKey);
  }
}

/** Submits `functionName(args)` to the contract from the relayer and waits for it to be mined. */
export type RelayParams = {
  chainId: number;
  contractAddress: Address;
  functionName: string;
  args: readonly unknown[];
  intent?: RelayIntent;
};

export function relay(params: RelayParams): Promise<RelayResult> {
  if (!params.intent) return relayRequest(params);
  const digest = digestOf(params.functionName, params.args);
  const key = keyId({ chainId: params.chainId, pool: params.contractAddress, signer: params.intent.signer,
    kind: params.intent.poolNonce === undefined ? "permit" : "pool", nonce: params.intent.poolNonce ?? digest });
  return flights.run(key, digest, () => relayRequest(params), () => new RelayerError("A different request with this nonce is already in flight", 409));
}

async function relayRequest(params: RelayParams): Promise<RelayResult> {
  const { chainId, functionName, args } = params;
  const { address: contractAddress, abi } = resolveDeployment(chainId, params.contractAddress);
  const { publicClient, walletClient, address } = await getRelayer(chainId);
  console.log(`[relayer] ${functionName}`, { chainId, contractAddress, relayer: address });

  // Journal (off unless RELAYER_JOURNAL_PATH is set and the route names its signer): the intent is durable before the
  // first network call; a request already seen is answered from the journal; a lost outcome is settled from the chain.
  const state = params.intent ? journalFor() : undefined;
  // Hash-first sending (relayerSend.ts) needs a local signer: the transaction hash must exist before the broadcast. An
  // unlocked development node cannot give that, so the journal is refused there outside the local chain.
  const localSigner = (walletClient.account as { type?: string } | undefined)?.type === "local";
  if (state && !localSigner && chainId !== LOCAL_CHAIN_ID) {
    throw new RelayerError(
      "The relayer journal needs a local signing key (RELAYER_PRIVATE_KEY) outside the local chain",
      500,
    );
  }
  let key: IntentKey | undefined;
  let entry: Entry | undefined;
  if (state && params.intent) {
    const reads = chainReads(publicClient, contractAddress, abi);
    await recoverOnce(state, chainId, contractAddress, reads);
    const digest = digestOf(functionName, args);
    key = {
      chainId,
      pool: contractAddress,
      signer: params.intent.signer,
      kind: params.intent.poolNonce !== undefined ? "pool" : "permit",
      nonce: params.intent.poolNonce ?? digest,
    };
    let d = decide(state.journal, key, digest, functionName, new Date().toISOString(), localSigner);
    if (d.action === "answer" && !isTerminal(d.entry.state)) {
      // An open entry from this process or an earlier one: let the chain settle what it can, then decide again.
      const done = await recover(
        state.journal,
        reads,
        new Date().toISOString(),
        e => keyId(e.key) === keyId(key!),
        (_e, err) => console.error("[relayer] journal read failed; the entry stays as it is:", messageOf(err)),
        entry => state.store.append(entry),
      );
      if (done.length) d = decide(state.journal, key, digest, functionName, new Date().toISOString(), localSigner);
    }
    if (d.action === "answer") {
      if (d.entry.digest !== digest)
        throw new RelayerError("A different signed request already uses this nonce", 409);
      if (d.answer.status === 200 && d.entry.hash) {
        const receipt = await publicClient.getTransactionReceipt({ hash: d.entry.hash as Hex });
        return {
          hash: d.entry.hash as Hex,
          receipt,
          relayer: address,
          events: decodeEvents(abi, contractAddress, receipt),
          replayed: true,
        };
      }
      if (d.entry.state === "submitted" && d.entry.raw && d.entry.hash && localSigner) {
        // The same signed request again, and its transaction has no receipt: send the identical bytes once more (one
        // transaction, one hash, however often) and wait for the receipt, which alone decides.
        const hash = d.entry.hash as Hex;
        try {
          await rebroadcast(d.entry, {
            broadcast: async raw => void (await publicClient.sendRawTransaction({ serializedTransaction: raw as Hex })),
          });
          const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 20_000 });
          state.store.append(
            state.journal.outcome(key, receipt.status === "success" ? "success" : "reverted", new Date().toISOString()),
          );
          if (receipt.status !== "success") throw new RelayerError(`Transaction ${hash} reverted`);
          return { hash, receipt, relayer: address, events: decodeEvents(abi, contractAddress, receipt) };
        } catch (e) {
          if (e instanceof RelayerError) throw e;
          throw new RelayerError(
            `Submitted but not yet confirmed (transaction ${hash}). Send the same request again: the identical transaction is rebroadcast, never a second one.`,
            202,
          );
        }
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
      // Nothing was signed or sent, whether the simulation reverted or its read failed.
      if (state && key)
        state.store.append(
          state.journal.settle(key, "abandoned", "simulation failed before any send", new Date().toISOString()),
        );
      throw e;
    }
    if (state && key && localSigner) {
      const account = walletClient.account!;
      const data = encodeFunctionData({ abi, functionName, args } as any);
      try {
        return (await sendHashFirst(
          state.journal,
          key,
          {
            // Signing reads the network (nonce, fees) but sends nothing; the hash is journaled before the broadcast.
            sign: async () => {
              const prepared = await walletClient.prepareTransactionRequest({
                account,
                to: contractAddress,
                data,
                chain: walletClient.chain,
              } as any);
              const raw = await walletClient.signTransaction(prepared as any);
              return { raw, hash: keccak256(raw) };
            },
            broadcast: async raw => void (await publicClient.sendRawTransaction({ serializedTransaction: raw as Hex })),
            append: e => state.store.append(e),
          },
          () => new Date().toISOString(),
        )) as Hex;
      } catch (e) {
        if (e instanceof JournalWriteFailed)
          throw new RelayerError("The relayer journal is unavailable; the request was not sent", 503);
        if (e instanceof BroadcastUnconfirmed) {
          throw new RelayerError(
            `Submitted but not yet confirmed (transaction ${e.hash}). Send the same request again: the identical transaction is rebroadcast, never a second one.`,
            202,
          );
        }
        // Signing failed before any hash existed: nothing was broadcast.
        state.store.append(
          state.journal.settle(key, "abandoned", "signing failed before any broadcast", new Date().toISOString()),
        );
        throw e;
      }
    }
    // Unjournaled, or an unlocked development node: the outcome of a failed call is unknown to the journal, which stays open.
    return walletClient.writeContract(request);
  });
  // The hash-first path has already journaled the hash (and the bytes) before the broadcast; the unlocked-node path has not.
  if (state && key && state.journal.get(key)?.hash !== hash)
    state.store.append(state.journal.submitted(key, hash, new Date().toISOString()));
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (state && key)
    state.store.append(
      state.journal.outcome(key, receipt.status === "success" ? "success" : "reverted", new Date().toISOString()),
    );
  if (receipt.status !== "success") throw new RelayerError(`Transaction ${hash} reverted`);

  return { hash, receipt, relayer: address, events: decodeEvents(abi, contractAddress, receipt) };
}

/** Standard fields every relayer route returns for a mined transaction. */
export function txResponse({ hash, receipt, relayer, replayed }: RelayResult) {
  return {
    txHash: hash,
    hash,
    status: "mined",
    receiptStatus: receipt.status,
    relayer,
    ...(replayed ? { replayed: true } : {}),
  };
}

export function findEvent(result: RelayResult, eventName: string) {
  return result.events.find(event => event.eventName === eventName);
}

export const toPermitArg = permitArg;

/** The account that signed a relayer request, whichever route it is for. */
function signerOf(body: Record<string, any>): string | undefined {
  const signer = body.req?.backer ?? body.req?.lender ?? body.req?.borrower ?? body.borrower ?? body.lender;
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
      let json: unknown;
      try { json = await req.json(); } catch { throw new RelayerError("Invalid JSON body", 400); }
      const body = requestBody(json);
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
