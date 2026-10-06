import {
  type ChainReads,
  type IntentKey,
  Journal,
  answerFor,
  decide,
  isTerminal,
  keyId,
  recover,
} from "./relayerJournal.ts";
import { FileStore } from "./relayerJournalStore.ts";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";

const POOL = "0x73872B8fB7F1771C67911f03edc75aBdc9514973";
const ALICE = "0x1111111111111111111111111111111111111111";
const BOB = "0x2222222222222222222222222222222222222222";
const T = "2026-10-06T22:00:00Z";
const key = (nonce: number, signer = ALICE): IntentKey => ({
  chainId: 84532,
  pool: POOL,
  signer,
  kind: "pool",
  nonce: String(nonce),
});
const reads = (
  o: Partial<{ receipts: Record<string, "success" | "reverted">; nonces: Record<string, bigint> }>,
): ChainReads => ({
  receipt: async h => (o.receipts?.[h] ? { status: o.receipts[h] } : undefined),
  poolNonce: async s => o.nonces?.[s.toLowerCase()] ?? 0n,
});
const lines = (store: FileStore) => store.readLines();

test("chain-1/2: the intent is journaled before submit; a replay of the same signed request is answered, not resent", () => {
  const j = new Journal();
  const a = j.begin(key(0), "d1", "borrowAndDisburseMeta", T);
  assert.equal(a.kind, "new");
  const b = j.begin(key(0), "d1", "borrowAndDisburseMeta", T);
  assert.equal(b.kind, "existing");
  assert.deepEqual(answerFor(b.entry), {
    status: 202,
    body: { status: "in_flight", note: "an earlier submission of this request is being processed" },
  });
  j.submitted(key(0), "0xabc", T);
  j.outcome(key(0), "success", T);
  const c = j.begin(key(0), "d1", "borrowAndDisburseMeta", T);
  assert.equal(c.kind, "existing");
  assert.equal(answerFor(c.entry).status, 200);
  assert.equal((answerFor(c.entry).body as any).replayed, true);
});

test("a different signed request under the same nonce is refused while the first is unresolved or landed (at most one lands)", () => {
  const j = new Journal();
  j.begin(key(5), "dA", "backMeta", T);
  assert.equal(j.begin(key(5), "dB", "backMeta", T).kind, "conflict");
  j.submitted(key(5), "0xaa", T);
  assert.equal(j.begin(key(5), "dB", "backMeta", T).kind, "conflict");
  j.outcome(key(5), "success", T);
  assert.equal(j.begin(key(5), "dB", "backMeta", T).kind, "conflict");
  // another signer's nonce 5, and the same signer's nonce 6, are different keys
  assert.equal(j.begin(key(5, BOB), "dB", "backMeta", T).kind, "new");
  assert.equal(j.begin(key(6), "dB", "backMeta", T).kind, "new");
});

test("email-11/13 shape: crash after the intent, before any hash (so nothing was broadcast, rule 1b); the nonce is unconsumed: abandoned, a retry may submit", async () => {
  const j = new Journal();
  j.begin(key(3), "d", "requestWithdrawalMeta", T);
  const r = await recover(j, reads({ nonces: { [ALICE]: 3n } }), T);
  assert.equal(r.length, 1);
  assert.equal(r[0].next.state, "abandoned");
  assert.equal(answerFor(r[0].next).status, 409);
});

test("crash after submit, receipt later: submitted stays submitted until the receipt is visible (unknown stays unknown), then mined", async () => {
  const j = new Journal();
  j.begin(key(1), "d", "backMeta", T);
  j.submitted(key(1), "0xfeed", T);
  const none = await recover(j, reads({}), T);
  assert.equal(none.length, 0, "no receipt yet: nothing is concluded");
  assert.equal(j.get(key(1))!.state, "submitted");
  const done = await recover(j, reads({ receipts: { "0xfeed": "success" } }), T);
  assert.equal(done[0].next.state, "mined");
  assert.equal(j.get(key(1))!.state, "mined");
});

test("a reverted receipt is recorded as reverted, with its hash", async () => {
  const j = new Journal();
  j.begin(key(2), "d", "backMeta", T);
  j.submitted(key(2), "0xbad", T);
  const r = await recover(j, reads({ receipts: { "0xbad": "reverted" } }), T);
  assert.equal(r[0].next.state, "reverted");
  assert.equal(r[0].next.hash, "0xbad");
});

test("hash lost but the nonce is consumed (chain-7 shape): consumed_unattributed, never resend, attribute by calldata", async () => {
  const j = new Journal();
  j.begin(key(0), "d", "borrowAndDisburseMeta", T);
  const r = await recover(j, reads({ nonces: { [ALICE]: 1n } }), T);
  assert.equal(r[0].next.state, "consumed_unattributed");
  assert.match(r[0].next.note!, /calldata/);
  assert.equal(answerFor(r[0].next).status, 409);
  assert.equal((answerFor(r[0].next).body as any).status, "unknown_landed");
});

test("two signers in one process: each journal key recovers against its own signer's nonce (batch-envelope shape)", async () => {
  const j = new Journal();
  j.begin(key(0, ALICE), "dA", "backMeta", T);
  j.begin(key(0, BOB), "dB", "backMeta", T);
  const r = await recover(j, reads({ nonces: { [ALICE]: 1n, [BOB]: 0n } }), T);
  const byId = Object.fromEntries(r.map(x => [keyId(x.entry.key), x.next.state]));
  assert.equal(byId[keyId(key(0, ALICE))], "consumed_unattributed");
  assert.equal(byId[keyId(key(0, BOB))], "abandoned");
});

test("a permit-only intent with no hash, made without hash-first sending, is unresolved for an operator, never resent", async () => {
  const j = new Journal();
  const k: IntentKey = { chainId: 84532, pool: POOL, signer: ALICE, kind: "permit", nonce: "digest-of-permit" };
  j.begin(k, "d", "depositPermitOnlyMeta", T);
  const r = await recover(j, reads({}), T);
  assert.equal(r[0].next.state, "unresolved");
  assert.equal(answerFor(r[0].next).status, 409);
});

test("a permit-only intent with no hash, made under hash-first sending, was never broadcast: abandoned, a retry may submit", async () => {
  const j = new Journal();
  const k: IntentKey = { chainId: 84532, pool: POOL, signer: ALICE, kind: "permit", nonce: "digest-of-permit-2" };
  const first = decide(j, k, "d", "depositPermitOnlyMeta", T, true);
  assert.equal(first.action, "send");
  assert.equal((first as any).entry.hashFirst, true);
  const r = await recover(j, reads({}), T);
  assert.equal(r[0].next.state, "abandoned");
  assert.equal(decide(j, k, "d", "depositPermitOnlyMeta", T, true).action, "send", "the retry is a new intent");
  // with a hash and no receipt it stays unknown, like every hashed entry
  j.submitted(k, "0xpermit", T, "0xraw");
  assert.equal((await recover(j, reads({}), T)).length, 0);
});

test("terminal states stay terminal: a late 'submitted' or a second recovery changes nothing", async () => {
  const j = new Journal();
  j.begin(key(9), "d", "backMeta", T);
  j.submitted(key(9), "0x1", T);
  j.outcome(key(9), "success", T);
  assert.equal(j.submitted(key(9), "0x2", T).state, "mined");
  assert.equal(j.get(key(9))!.hash, "0x1");
  assert.equal((await recover(j, reads({ nonces: { [ALICE]: 99n } }), T)).length, 0);
  assert.ok(isTerminal(j.get(key(9))!.state));
});

test("rule 1 on disk: lines are appended and fsynced; replay after a crash restores state; a torn last line is ignored", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "relayer-journal-"));
  const store = new FileStore(path.join(dir, "journal.jsonl"));
  const j = new Journal();
  const begin = j.begin(key(4), "d", "backMeta", T);
  assert.equal(begin.kind, "new");
  store.append(begin.entry); // durable BEFORE the network call
  const sub = j.submitted(key(4), "0xcafe", T);
  store.append(sub);
  // the process dies mid-append of the next line
  fs.appendFileSync(store.path, '{"v":1,"at":"2026-10-06T22:00:01Z","key":{"chainId":84532');
  const restarted = Journal.replay(store.readLines());
  assert.equal(restarted.get(key(4))!.state, "submitted");
  assert.equal(restarted.get(key(4))!.hash, "0xcafe");
  assert.equal(restarted.open().length, 1);
  assert.equal(new FileStore(path.join(dir, "absent.jsonl")).readLines().length, 0);
  assert.equal((fs.statSync(store.path).mode & 0o777).toString(8), "600");
  assert.equal(lines(store).length, 3, "the torn fragment is a line the replay skipped, not one it trusted");
});

test("abandoned and reverted intents allow a fresh attempt (nothing took effect); landed and in-flight ones do not", async () => {
  const j = new Journal();
  // abandoned by recovery, then the client retries with the same signed request: a new intent, journaled again
  j.begin(key(7), "d", "backMeta", T);
  await recover(j, reads({ nonces: { [ALICE]: 7n } }), T);
  assert.equal(j.get(key(7))!.state, "abandoned");
  assert.equal(decide(j, key(7), "d", "backMeta", T).action, "send");
  assert.equal(j.get(key(7))!.state, "intent");
  // a reverted receipt: the retry (same or re-signed) may submit
  j.submitted(key(7), "0xrev", T);
  j.outcome(key(7), "reverted", T);
  assert.equal(decide(j, key(7), "d2", "backMeta", T).action, "send");
  // a landed one never re-opens, and a different request under it is a 409
  j.submitted(key(7), "0xok", T);
  j.outcome(key(7), "success", T);
  const again = decide(j, key(7), "d3", "backMeta", T);
  assert.equal(again.action, "answer");
  assert.equal((again as any).answer.status, 409);
  assert.equal((again as any).answer.body.status, "nonce_in_use");
  const same = decide(j, key(7), "d2", "backMeta", T);
  assert.equal((same as any).answer.status, 200);
});

test("replay of the file keeps the reopen rule: intent, abandoned, intent again", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "relayer-journal-"));
  const store = new FileStore(path.join(dir, "j.jsonl"));
  const j = new Journal();
  const first = decide(j, key(8), "d", "backMeta", T);
  store.append((first as any).entry);
  const abandoned = j.settle(key(8), "abandoned", "nothing landed", T);
  store.append(abandoned);
  const second = decide(j, key(8), "d", "backMeta", T);
  store.append((second as any).entry);
  const restarted = Journal.replay(store.readLines());
  assert.equal(restarted.get(key(8))!.state, "intent");
  assert.equal(restarted.open().length, 1);
});

test("recovery can be limited to one chain's entries", async () => {
  const j = new Journal();
  const other: IntentKey = { ...key(0), chainId: 8453 };
  j.begin(key(0), "d", "backMeta", T);
  j.begin(other, "d", "backMeta", T);
  const r = await recover(j, reads({ nonces: { [ALICE]: 0n } }), T, e => e.key.chainId === 84532);
  assert.equal(r.length, 1);
  assert.equal(j.get(other)!.state, "intent", "the other chain's entry is untouched");
});

test("email-9: a verification read that fails is neither confirmation nor absence; that entry stays open and the others are still settled", async () => {
  const j = new Journal();
  j.begin(key(10), "d", "backMeta", T);
  j.submitted(key(10), "0xflaky", T, "0xraw");
  j.begin(key(11), "d", "backMeta", T);
  j.submitted(key(11), "0xfine", T, "0xraw");
  const failures: string[] = [];
  const r = await recover(
    j,
    {
      receipt: async h => {
        if (h === "0xflaky") throw new Error("HTTP request timed out");
        return { status: "success" };
      },
      poolNonce: async () => 0n,
    },
    T,
    () => true,
    (e, err) => failures.push(e.hash + ": " + (err as Error).message),
  );
  assert.equal(r.length, 1);
  assert.equal(j.get(key(10))!.state, "submitted", "the failed read concluded nothing");
  assert.equal(j.get(key(11))!.state, "mined");
  assert.deepEqual(failures, ["0xflaky: HTTP request timed out"]);
});

test("email-9: a failed nonce read for a hash-less entry does not abandon it", async () => {
  const j = new Journal();
  j.begin(key(12), "d", "backMeta", T);
  await recover(
    j,
    {
      receipt: async () => undefined,
      poolNonce: async () => {
        throw new Error("ECONNRESET");
      },
    },
    T,
  );
  assert.equal(j.get(key(12))!.state, "intent");
});
