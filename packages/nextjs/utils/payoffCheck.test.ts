import assert from "node:assert/strict";
import { test } from "node:test";
import { confirmPayoffOutcome, payoffNotice } from "./payoffCheck.ts";
import { type PayoffOutcome, payoffOutcome } from "./repayAmount.ts";
import { waitForStable } from "./stableRead.ts";

// These run the page's actual orchestration (confirmPayoffOutcome) with the actual waitForStable and a fake clock.
const clock = () => {
  let t = 0;
  return { now: () => t, sleep: async (ms: number) => void (t += ms), elapsed: () => t };
};
const CLOSED = payoffOutcome(false, 0n);
const open = (owed: bigint) => payoffOutcome(true, owed);

// A scripted loan read: each entry is an outcome to return or an Error to throw, then the last entry repeats.
const script = (steps: (PayoffOutcome | Error)[]) => {
  let i = 0;
  return {
    reads: () => i,
    read: async (): Promise<PayoffOutcome> => {
      const step = steps[Math.min(i++, steps.length - 1)];
      if (step instanceof Error) throw step;
      return step;
    },
  };
};
const rpcDown = new Error("RPC unavailable");

test("two consecutive closed reads confirm closure and the notice is empty", async () => {
  const c = clock();
  const s = script([CLOSED, CLOSED]);
  const outcome = await confirmPayoffOutcome(s.read, waitForStable, c);
  assert.deepEqual(outcome, { kind: "closed" });
  assert.equal(payoffNotice(outcome, String), "");
  assert.equal(s.reads(), 2);
});

test("a lagging node (open, then closed twice) still confirms once the closed state is stable", async () => {
  const c = clock();
  const s = script([open(11n), CLOSED, CLOSED]);
  assert.deepEqual(await confirmPayoffOutcome(s.read, waitForStable, c), { kind: "closed" });
});

test("one closed read followed by RPC failures is unknown, never closed (Codex's reproduction)", async () => {
  const c = clock();
  const s = script([CLOSED, rpcDown]);
  const outcome = await confirmPayoffOutcome(s.read, waitForStable, { ...c, timeoutMs: 9_000, intervalMs: 1_500 });
  assert.deepEqual(outcome, { kind: "unknown" });
  assert.equal(s.reads(), 7, "one closed read, then six failures until the 9,000 ms timeout");
  assert.equal(c.elapsed(), 9_000);
  assert.notEqual(payoffNotice(outcome, String), "", "the borrower is told closure was not confirmed");
});

test("a closed read at the timeout, with no second closed read, is unknown", async () => {
  const c = clock();
  // open for every read until the last one before the timeout, which is closed once
  const s = script([open(5n), open(5n), open(5n), open(5n), open(5n), open(5n), CLOSED]);
  const outcome = await confirmPayoffOutcome(s.read, waitForStable, { ...c, timeoutMs: 9_000, intervalMs: 1_500 });
  assert.deepEqual(outcome, { kind: "unknown" });
});

test("a fresh open result at the timeout keeps its exact residual in base units", async () => {
  const c = clock();
  const s = script([open(883n)]);
  const outcome = await confirmPayoffOutcome(s.read, waitForStable, { ...c, timeoutMs: 9_000, intervalMs: 1_500 });
  assert.deepEqual(outcome, { kind: "open", owed: 883n });
  assert.match(payoffNotice(outcome, n => `$0.${String(n).padStart(6, "0")}`), /\$0\.000883 is still owed/);
});

test("open followed by RPC failures is unknown: a stale open result is not carried over a failed read", async () => {
  const c = clock();
  const s = script([open(883n), rpcDown]);
  const outcome = await confirmPayoffOutcome(s.read, waitForStable, { ...c, timeoutMs: 9_000, intervalMs: 1_500 });
  assert.deepEqual(outcome, { kind: "unknown" });
});

test("a flapping node (closed, open, closed, closed) confirms only after the streak", async () => {
  const c = clock();
  const s = script([CLOSED, open(9n), CLOSED, CLOSED]);
  assert.deepEqual(await confirmPayoffOutcome(s.read, waitForStable, c), { kind: "closed" });
  assert.equal(s.reads(), 4);
});

test("an inconsistent read (active with nothing owed) is unknown and does not confirm", async () => {
  const c = clock();
  const s = script([payoffOutcome(true, 0n)]);
  assert.deepEqual(await confirmPayoffOutcome(s.read, waitForStable, { ...c, timeoutMs: 3_000, intervalMs: 1_500 }), { kind: "unknown" });
});

test("every read that fails leaves unknown", async () => {
  const c = clock();
  const s = script([rpcDown]);
  assert.deepEqual(await confirmPayoffOutcome(s.read, waitForStable, { ...c, timeoutMs: 3_000, intervalMs: 1_500 }), { kind: "unknown" });
});
