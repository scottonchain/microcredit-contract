import type { Entry, IntentKey, Journal } from "./relayerJournal";

/**
 * The relayer's send, ordered so that a crash at any point leaves the journal truthful (relayerJournal.ts, rule 1b):
 *
 *   sign (nothing leaves the process) -> journal hash and raw bytes durably -> broadcast
 *
 * Every step before the journal write is safe to lose: no hash is recorded because nothing was broadcast. Every step after
 * it leaves the entry `submitted` with its hash, which recovery settles only from a receipt; an absent receipt stays
 * unknown. A retry of the same signed request rebroadcasts the identical bytes (idempotent: one transaction, one hash).
 *
 * The signing, the broadcast and the durable append are injected, so the ordering is tested without a chain.
 */
export type Signed = { hash: string; raw: string };

export type SendDeps = {
  /** Builds and signs the transaction locally. May read the network (nonce, fees) but must not send anything. */
  sign: () => Promise<Signed>;
  /** Sends the signed bytes. Idempotent for the same bytes. */
  broadcast: (raw: string) => Promise<void>;
  /** Appends the entry durably (written and fsynced before it returns). */
  append: (entry: Entry) => void;
};

/** The journal could not record the hash, so nothing was broadcast. */
export class JournalWriteFailed extends Error {
  constructor(cause: unknown) {
    super("The relayer journal could not record the transaction; nothing was sent.");
    this.name = "JournalWriteFailed";
    this.cause = cause;
  }
}

/** The bytes may or may not have reached the network. The entry stays `submitted`; the receipt decides. */
export class BroadcastUnconfirmed extends Error {
  readonly hash: string;
  constructor(hash: string, cause: unknown) {
    super(`Transaction ${hash} was journaled but its broadcast was not confirmed: ${messageOf(cause)}`);
    this.name = "BroadcastUnconfirmed";
    this.hash = hash;
    this.cause = cause;
  }
}

type ErrorLike = { shortMessage?: string; details?: string; message?: string } | undefined;

/** Text for people and logs: the short message and details only, never the full viem message (it carries the RPC URL and the request body). */
export function messageOf(e: unknown): string {
  const x = e as ErrorLike;
  const parts = [x?.shortMessage, x?.details].filter(Boolean);
  return parts.length ? parts.join(" | ") : (x?.message ?? String(e)).split("\n")[0];
}

/** Everything an error says, for classification only (never displayed). */
const classifiable = (e: unknown) => {
  const x = e as ErrorLike;
  return [x?.shortMessage, x?.details, x?.message].filter(Boolean).join(" | ") || String(e);
};

/** A node saying it already holds these exact bytes: the broadcast succeeded earlier, so the outcome is as before. */
export const isAlreadyKnown = (e: unknown) =>
  /already known|known transaction|already imported|already exists/i.test(classifiable(e));

/** The account nonce was consumed; the original transaction may already have mined. */
export const isNonceTooLow = (e: unknown) => /nonce too low|nonce is too low/i.test(classifiable(e));

/**
 * First send of an intent. Returns the hash once the bytes were broadcast (or the node already held them). Throws
 * `JournalWriteFailed` (nothing sent) or `BroadcastUnconfirmed` (unknown: the entry stays `submitted`). Even the first
 * broadcast call may contain transport retries: a lost successful response followed by "nonce too low" cannot prove
 * the transaction did not land. Only its receipt can settle a journaled hash.
 */
export async function sendHashFirst(
  journal: Journal,
  key: IntentKey,
  deps: SendDeps,
  now: () => string,
): Promise<string> {
  const { hash, raw } = await deps.sign();
  const entry = journal.submitted(key, hash, now(), raw);
  try {
    deps.append(entry); // durable BEFORE the broadcast
  } catch (e) {
    journal.settle(key, "abandoned", "journal write failed before the broadcast; nothing was sent", now());
    throw new JournalWriteFailed(e);
  }
  try {
    await deps.broadcast(raw);
  } catch (e) {
    if (isAlreadyKnown(e)) return hash;
    throw new BroadcastUnconfirmed(hash, e);
  }
  return hash;
}

/**
 * A retry of a request whose entry is `submitted` with bytes but no receipt: send the identical bytes again. Already known,
 * or a consumed nonce (the original may have mined while this node lags), prove nothing and leave the entry as it is.
 * Any other failure is an unconfirmed broadcast. The caller then waits for the receipt, which alone decides.
 */
export async function rebroadcast(entry: Entry, deps: Pick<SendDeps, "broadcast">): Promise<"sent" | "known"> {
  if (!entry.raw || !entry.hash) throw new Error("journal: nothing to rebroadcast for this entry");
  try {
    await deps.broadcast(entry.raw);
    return "sent";
  } catch (e) {
    if (isAlreadyKnown(e) || isNonceTooLow(e)) return "known";
    throw new BroadcastUnconfirmed(entry.hash, e);
  }
}
