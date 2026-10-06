/**
 * Durable journal for the gasless relayer: what the retry fixture's rules (testbed retry-fixture, chain-1 to chain-7 and
 * email-11, email-13) require of a relayer that can die between submitting a signed request and seeing its receipt.
 *
 * Rules, each from the fixture or the contract tests (`test/RelayerRetry.t.sol`, `test/RelayerRetryBatch.t.sol`):
 *  1. The intent is written, and made durable, BEFORE the first network call. A present record means "permitted or
 *     intended", never "performed".
 *  1b. For a local signer the signed transaction is built before it is sent, so its hash exists before the network does:
 *     the hash and the raw bytes are journaled durably BEFORE the broadcast (relayerSend.ts). "No hash" therefore means
 *     "never broadcast", and "a hash" means "may be in a mempool": absence of a mined receipt is then unknown, not failure
 *     (fixture email-11 case B: the node accepted it and the worker died before persisting). The identical bytes may be
 *     rebroadcast any number of times; they cannot land twice. A signer that cannot sign locally (an unlocked development
 *     node) cannot give this guarantee and is refused outside the local chain.
 *  2. The key of an intent is (chain, pool, signer, nonce), the nonce the signer signed. The contract consumes that
 *     nonce exactly once (`InvalidNonce`), so a duplicate submission cannot land twice; the journal's job is to make the
 *     relayer's own answers truthful and idempotent, not to be the last line of defence.
 *  3. A second, different signed request under the same key is refused while the first is unresolved: at most one can
 *     land, and the relayer must not choose by sending both.
 *  4. Recovery after a restart reads the chain, never the journal's silence. With a transaction hash: its receipt. Without
 *     one: the signer's on-chain nonce. Nonce not past the intent's nonce means nothing consumed it (the intent may be
 *     abandoned and the client's retry may submit); nonce past it means something consumed it, and whether this request
 *     did is established only by decoding the consuming transaction's calldata, so the state is `consumed_unattributed`
 *     and the relayer never resends on it ("absence of a hash is not absence of an effect").
 *  5. A terminal state stays terminal. Unknown stays unknown: nothing here turns an unresolved intent into a failure on
 *     the strength of elapsed time.
 *
 * Permit-only routes (`depositPermitOnlyMeta`, `repayWithPermit`) have no pool nonce; they are keyed by the digest of the
 * permit and recovered by their hash only. With no hash they stay `unresolved` for an operator, by rule 5.
 *
 * Pure functions and an in-memory model; the file store (relayerJournalStore.ts) only appends lines and replays them.
 */

export const JOURNAL_VERSION = 1 as const;

export type NonceKind = "pool" | "permit";

export type IntentKey = {
  chainId: number;
  pool: string;
  signer: string;
  kind: NonceKind;
  /** The pool nonce the signer signed, as a decimal string; for permit-only routes the digest of the permit. */
  nonce: string;
};

export type State =
  | "intent" // written before submit; nothing known about the network
  | "submitted" // a hash exists
  | "mined" // receipt, status success
  | "reverted" // receipt, status reverted (the contract refused it; nothing took effect)
  | "abandoned" // recovery found the nonce unconsumed and no hash: nothing landed, a retry may submit
  | "consumed_unattributed" // the nonce was consumed; no hash is known; whether by this request is not established
  | "unresolved"; // permit-only intent with no hash after a restart: an operator decides

export const TERMINAL: readonly State[] = ["mined", "reverted", "abandoned", "consumed_unattributed", "unresolved"];

export type Entry = {
  v: typeof JOURNAL_VERSION;
  at: string;
  key: IntentKey;
  /** keccak or sha digest of the signed request and signature, so a different request under the same key is detected. */
  digest: string;
  state: State;
  functionName?: string;
  hash?: string;
  /** The signed transaction (public once broadcast), kept so the identical bytes can be rebroadcast. */
  raw?: string;
  note?: string;
};

export const keyId = (k: IntentKey) =>
  [k.chainId, k.pool.toLowerCase(), k.signer.toLowerCase(), k.kind, k.nonce].join(":");

export const isTerminal = (s: State) => TERMINAL.includes(s);

export type BeginResult =
  | { kind: "new"; entry: Entry }
  | { kind: "existing"; entry: Entry } // same key, same digest: answer from it, do not submit again
  | { kind: "conflict"; entry: Entry }; // same key, different digest, first unresolved or landed: refuse

/** In-memory model of the journal: the latest entry per key. */
export class Journal {
  private latest = new Map<string, Entry>();
  private order: string[] = [];

  /** Replays appended lines in order; later lines for a key supersede earlier ones, but a terminal state never reverts. */
  static replay(lines: readonly string[]): Journal {
    const j = new Journal();
    for (const line of lines) {
      let e: Entry;
      try {
        e = JSON.parse(line);
      } catch {
        continue; // a torn last line (crash during append) is ignored, never trusted
      }
      if (!e || e.v !== JOURNAL_VERSION || !e.key || typeof e.state !== "string") continue;
      j.apply(e);
    }
    return j;
  }

  private apply(e: Entry) {
    const id = keyId(e.key);
    const prev = this.latest.get(id);
    const reopened = e.state === "intent" && prev !== undefined && (prev.state === "abandoned" || prev.state === "reverted");
    if (prev && isTerminal(prev.state) && !reopened) return; // rule 5: a terminal state is replaced only by a new intent
    if (!prev) this.order.push(id);
    this.latest.set(id, e);
  }

  /** A new intent replaces an abandoned or reverted one; nothing else may replace a terminal entry. */
  private reopen(entry: Entry) {
    const id = keyId(entry.key);
    if (!this.latest.has(id)) this.order.push(id);
    this.latest.set(id, entry);
  }

  get(key: IntentKey): Entry | undefined {
    return this.latest.get(keyId(key));
  }

  all(): Entry[] {
    return this.order.map(id => this.latest.get(id)!);
  }

  /** Entries recovery must look at after a restart. */
  open(): Entry[] {
    return this.all().filter(e => e.state === "intent" || e.state === "submitted");
  }

  /** Rule 1 and 3. The caller appends `entry` durably BEFORE any network call when the result is `new`. */
  begin(key: IntentKey, digest: string, functionName: string, now: string): BeginResult {
    const prev = this.get(key);
    // Nothing took effect under an abandoned or reverted intent: a fresh attempt (same or different signed request)
    // is journaled as a new intent for the same key. Every other state answers from the journal (rule 3).
    if (!prev || prev.state === "abandoned" || prev.state === "reverted") {
      const entry: Entry = { v: JOURNAL_VERSION, at: now, key, digest, state: "intent", functionName };
      this.reopen(entry);
      return { kind: "new", entry };
    }
    if (prev.digest !== digest) return { kind: "conflict", entry: prev };
    return { kind: "existing", entry: prev };
  }

  submitted(key: IntentKey, hash: string, now: string, raw?: string): Entry {
    return this.advance(key, { state: "submitted", hash, ...(raw ? { raw } : {}) }, now);
  }

  outcome(key: IntentKey, status: "success" | "reverted", now: string): Entry {
    return this.advance(key, { state: status === "success" ? "mined" : "reverted" }, now);
  }

  /** Recovery's transition: a terminal state decided from chain reads, with the reason recorded. */
  settle(key: IntentKey, state: State, note: string, now: string): Entry {
    return this.advance(key, { state, note }, now);
  }

  private advance(key: IntentKey, patch: Partial<Entry>, now: string): Entry {
    const prev = this.get(key);
    if (!prev) throw new Error("journal: no intent for " + keyId(key));
    if (isTerminal(prev.state)) return prev; // rule 5
    const next: Entry = { ...prev, ...patch, at: now };
    this.apply(next);
    return next;
  }
}

// ---- recovery (rule 4) ---------------------------------------------------------------------------------------------

export type ChainReads = {
  /** Receipt of a hash: undefined = not found yet (neither success nor absence), else its status. */
  receipt(hash: string): Promise<{ status: "success" | "reverted" } | undefined>;
  /** The signer's current on-chain pool nonce. */
  poolNonce(signer: string): Promise<bigint>;
};

export type Recovery = { entry: Entry; next: Entry };

/**
 * Settles what the chain can settle for every open entry. An entry whose receipt is not yet visible stays `submitted`
 * (unknown stays unknown); nothing is ever marked failed from a timeout.
 */
export async function recover(
  journal: Journal,
  reads: ChainReads,
  now: string,
  only: (e: Entry) => boolean = () => true,
): Promise<Recovery[]> {
  const out: Recovery[] = [];
  for (const entry of journal.open().filter(only)) {
    let next: Entry | undefined;
    if (entry.hash) {
      const r = await reads.receipt(entry.hash);
      if (r) next = journal.outcome(entry.key, r.status, now);
    } else if (entry.key.kind === "pool") {
      const current = await reads.poolNonce(entry.key.signer);
      next =
        current <= BigInt(entry.key.nonce)
          ? journal.settle(entry.key, "abandoned", "nonce unconsumed and no hash: nothing landed; a retry may submit", now)
          : journal.settle(
              entry.key,
              "consumed_unattributed",
              "nonce consumed and no hash known: decode the consuming transaction's calldata to attribute it; never resend",
              now,
            );
    } else {
      next = journal.settle(entry.key, "unresolved", "permit-only intent with no hash: operator decides; never resend", now);
    }
    if (next && next !== entry) out.push({ entry, next });
  }
  return out;
}

/** What the relayer answers a client that retries a request it has already seen. */
export function answerFor(entry: Entry): { status: number; body: Record<string, unknown> } {
  switch (entry.state) {
    case "mined":
      return { status: 200, body: { status: "mined", txHash: entry.hash, replayed: true } };
    case "submitted":
      return { status: 202, body: { status: "submitted", txHash: entry.hash, note: "the receipt is not yet confirmed" } };
    case "intent":
      return { status: 202, body: { status: "in_flight", note: "an earlier submission of this request is being processed" } };
    case "reverted":
      return { status: 409, body: { status: "reverted", txHash: entry.hash, note: "the contract refused this request" } };
    case "abandoned":
      return { status: 409, body: { status: "abandoned", note: entry.note } };
    case "consumed_unattributed":
      return { status: 409, body: { status: "unknown_landed", note: entry.note } };
    default:
      return { status: 409, body: { status: "unresolved", note: entry.note } };
  }
}

export type Decision =
  | { action: "send"; entry: Entry } // journal the entry durably, then submit
  | { action: "answer"; entry: Entry; answer: { status: number; body: Record<string, unknown> } };

/**
 * The relayer's decision for one incoming signed request: submit (after journaling the returned entry), or answer from
 * the journal without touching the network. A conflicting request under the same key is answered with a 409.
 */
export function decide(journal: Journal, key: IntentKey, digest: string, functionName: string, now: string): Decision {
  const r = journal.begin(key, digest, functionName, now);
  if (r.kind === "new") return { action: "send", entry: r.entry };
  if (r.kind === "conflict") {
    return {
      action: "answer",
      entry: r.entry,
      answer: {
        status: 409,
        body: { status: "nonce_in_use", note: "a different signed request with this nonce is already being processed or has landed" },
      },
    };
  }
  return { action: "answer", entry: r.entry, answer: answerFor(r.entry) };
}
