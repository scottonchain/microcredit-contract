import { type ChainReads, type IntentKey, Journal, decide, recover } from "./relayerJournal.ts";
import { FileStore } from "./relayerJournalStore.ts";
import {
  BroadcastUnconfirmed,
  JournalWriteFailed,
  type SendDeps,
  isAlreadyKnown,
  isNonceTooLow,
  rebroadcast,
  sendHashFirst,
} from "./relayerSend.ts";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";

const POOL = "0x73872B8fB7F1771C67911f03edc75aBdc9514973";
const ALICE = "0x1111111111111111111111111111111111111111";
const T = "2026-10-06T23:00:00Z";
const now = () => T;
const key = (nonce: number): IntentKey => ({
  chainId: 84532,
  pool: POOL,
  signer: ALICE,
  kind: "pool",
  nonce: String(nonce),
});
const SIGNED = { hash: "0xaaaa", raw: "0x02f8aaaa" };
const reads = (o: Partial<{ receipts: Record<string, "success" | "reverted">; nonce: bigint }>): ChainReads => ({
  receipt: async h => (o.receipts?.[h] ? { status: o.receipts[h] } : undefined),
  poolNonce: async () => o.nonce ?? 0n,
});
const store = () => new FileStore(path.join(fs.mkdtempSync(path.join(os.tmpdir(), "relayer-send-")), "journal.jsonl"));
const timeout = () => Object.assign(new Error("HTTP request timed out"), { name: "TimeoutError" });

test("order: the hash and the raw bytes are on disk before the broadcast starts", async () => {
  const s = store();
  const j = new Journal();
  j.begin(key(0), "d", "backMeta", T);
  s.append(j.get(key(0))!);
  let onDiskAtBroadcast: string[] = [];
  const deps: SendDeps = {
    sign: async () => SIGNED,
    append: e => s.append(e),
    broadcast: async () => {
      onDiskAtBroadcast = s.readLines();
    },
  };
  const hash = await sendHashFirst(j, key(0), deps, now);
  assert.equal(hash, SIGNED.hash);
  const last = JSON.parse(onDiskAtBroadcast.at(-1)!);
  assert.equal(last.state, "submitted");
  assert.equal(last.hash, SIGNED.hash);
  assert.equal(last.raw, SIGNED.raw);
});

test("a failed journal write means nothing was broadcast, and the intent is abandoned so a fresh attempt may follow", async () => {
  const j = new Journal();
  j.begin(key(1), "d", "backMeta", T);
  let broadcasts = 0;
  const deps: SendDeps = {
    sign: async () => SIGNED,
    append: () => {
      throw new Error("disk full");
    },
    broadcast: async () => {
      broadcasts += 1;
    },
  };
  await assert.rejects(sendHashFirst(j, key(1), deps, now), JournalWriteFailed);
  assert.equal(broadcasts, 0);
  assert.equal(j.get(key(1))!.state, "abandoned");
  assert.equal(decide(j, key(1), "d", "backMeta", T).action, "send");
});

test("a signing failure journals no hash and broadcasts nothing; the intent stays for the caller to settle", async () => {
  const j = new Journal();
  j.begin(key(2), "d", "backMeta", T);
  let broadcasts = 0;
  const deps: SendDeps = {
    sign: async () => {
      throw timeout();
    },
    append: () => assert.fail("nothing to append"),
    broadcast: async () => {
      broadcasts += 1;
    },
  };
  await assert.rejects(sendHashFirst(j, key(2), deps, now), /timed out/);
  assert.equal(broadcasts, 0);
  assert.equal(j.get(key(2))!.state, "intent");
  assert.equal(j.get(key(2))!.hash, undefined);
});

test("email-11 case B: the node accepted the bytes, the worker died before recording an outcome: unknown, never abandoned, never resent as new", async () => {
  const s = store();
  const j = new Journal();
  const first = decide(j, key(3), "d", "backMeta", T);
  s.append((first as any).entry);
  const deps: SendDeps = {
    sign: async () => SIGNED,
    append: e => s.append(e),
    broadcast: async () => {
      throw timeout(); // the provider accepted it; the answer was lost
    },
  };
  await assert.rejects(sendHashFirst(j, key(3), deps, now), BroadcastUnconfirmed);
  assert.equal(j.get(key(3))!.state, "submitted");

  // the process restarts; the signer's pool nonce is NOT consumed yet because the transaction is only pending
  const restarted = Journal.replay(s.readLines());
  const settled = await recover(restarted, reads({ nonce: 3n }), T);
  assert.equal(settled.length, 0, "a hash exists, no receipt yet: nothing is concluded from the unconsumed nonce");
  assert.equal(restarted.get(key(3))!.state, "submitted");
  assert.equal(restarted.get(key(3))!.raw, SIGNED.raw);

  // the client retries the same signed request: answered from the journal, not signed again
  const retry = decide(restarted, key(3), "d", "backMeta", T);
  assert.equal(retry.action, "answer");
  assert.equal((retry as any).answer.status, 202);

  // the receipt appears: now it is settled
  const done = await recover(restarted, reads({ receipts: { [SIGNED.hash]: "success" } }), T);
  assert.equal(done[0].next.state, "mined");
});

test("a retry rebroadcasts the identical bytes; a node that already holds them changes nothing", async () => {
  const j = new Journal();
  j.begin(key(4), "d", "backMeta", T);
  const sent: string[] = [];
  let nodeHolds = false;
  const deps: SendDeps = {
    sign: async () => SIGNED,
    append: () => {},
    broadcast: async raw => {
      sent.push(raw);
      if (nodeHolds) throw new Error("already known");
      nodeHolds = true;
      throw timeout(); // the first answer was lost, but the node did take it
    },
  };
  await assert.rejects(sendHashFirst(j, key(4), deps, now), BroadcastUnconfirmed);
  const entry = j.get(key(4))!;
  assert.equal(await rebroadcast(entry, deps), "known");
  assert.deepEqual(sent, [SIGNED.raw, SIGNED.raw], "same bytes, same hash: one transaction at most");
  assert.equal(j.get(key(4))!.hash, SIGNED.hash, "no second hash was ever minted");
});

test("a retry whose node never received the bytes sends them now", async () => {
  const j = new Journal();
  j.begin(key(5), "d", "backMeta", T);
  let up = false;
  const deps: SendDeps = {
    sign: async () => SIGNED,
    append: () => {},
    broadcast: async () => {
      if (!up) throw new Error("fetch failed");
    },
  };
  await assert.rejects(sendHashFirst(j, key(5), deps, now), BroadcastUnconfirmed);
  up = true;
  assert.equal(await rebroadcast(j.get(key(5))!, deps), "sent");
});

test("a nonce-too-low response after transport retries preserves the accepted transaction until its receipt settles it", async () => {
  const s = store();
  const j = new Journal();
  s.append(j.begin(key(6), "d", "backMeta", T).entry);
  let acceptedRaw: string | undefined;
  let signatures = 0;
  const deps: SendDeps = {
    sign: async () => {
      signatures += 1;
      return SIGNED;
    },
    append: e => s.append(e),
    broadcast: async raw => {
      // One broadcast call can retry internally: the node accepted the first HTTP request,
      // its response was lost, and the retry now finds the account nonce consumed.
      acceptedRaw = raw;
      throw Object.assign(new Error("nonce too low: next nonce 12, tx nonce 11"), {
        shortMessage: "Nonce provided for the transaction is lower than the current nonce",
      });
    },
  };
  await assert.rejects(sendHashFirst(j, key(6), deps, now), error =>
    error instanceof BroadcastUnconfirmed && error.hash === SIGNED.hash);
  assert.equal(acceptedRaw, SIGNED.raw);
  assert.equal(signatures, 1);
  assert.equal(j.get(key(6))!.state, "submitted");

  const restarted = Journal.replay(s.readLines());
  assert.equal(restarted.get(key(6))!.state, "submitted");
  assert.equal(restarted.get(key(6))!.hash, SIGNED.hash);
  assert.equal(restarted.get(key(6))!.raw, SIGNED.raw);
  assert.equal((await recover(restarted, reads({ nonce: 7n }), T)).length, 0,
    "an unseen receipt remains unknown even when the signer nonce advanced");
  const retry = decide(restarted, key(6), "d", "backMeta", T);
  assert.equal(retry.action, "answer");
  if (retry.action === "answer") assert.equal(retry.answer.status, 202);
  assert.equal(decide(restarted, key(6), "different", "backMeta", T).action, "answer");

  const settled = await recover(restarted, reads({ receipts: { [SIGNED.hash]: "success" } }), T);
  assert.equal(settled[0].next.state, "mined");
  assert.equal(settled[0].next.hash, SIGNED.hash);
});

test("nonce too low on a rebroadcast proves nothing (the original may have mined while this node lags): the entry is left as it is", async () => {
  const j = new Journal();
  j.begin(key(7), "d", "backMeta", T);
  j.submitted(key(7), SIGNED.hash, T, SIGNED.raw);
  const out = await rebroadcast(j.get(key(7))!, {
    broadcast: async () => {
      throw new Error("nonce too low");
    },
  });
  assert.equal(out, "known");
  assert.equal(j.get(key(7))!.state, "submitted");
});

test("error classification reads the message, the short message and the details", () => {
  assert.ok(isAlreadyKnown(new Error("ALREADY_EXISTS: transaction already imported")));
  assert.ok(isAlreadyKnown({ details: "known transaction: 0xabc" }));
  assert.ok(isNonceTooLow({ shortMessage: "nonce too low" }));
  assert.ok(
    !isAlreadyKnown(new Error("replacement transaction underpriced")),
    "a different transaction at that nonce is not 'the same bytes'",
  );
  assert.ok(!isNonceTooLow(new Error("insufficient funds for gas")));
});

test("rebroadcast needs bytes: an entry without raw (written by an earlier version of the journal) is refused, not guessed", async () => {
  const j = new Journal();
  j.begin(key(8), "d", "backMeta", T);
  j.submitted(key(8), "0xold", T);
  await assert.rejects(rebroadcast(j.get(key(8))!, { broadcast: async () => {} }), /nothing to rebroadcast/);
});
