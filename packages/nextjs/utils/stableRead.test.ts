import assert from "node:assert/strict";
import { test } from "node:test";
import { NotVisibleYet, waitForStable } from "./stableRead.ts";

const clock = () => {
  let t = 0;
  return { now: () => t, sleep: async (ms: number) => void (t += ms) };
};

test("stale reads, then fresh: returns only after two consecutive fresh reads", async () => {
  const c = clock();
  const reads = [0n, 0n, 20n, 20n];
  let i = 0;
  const v = await waitForStable(async () => reads[Math.min(i++, reads.length - 1)], x => x >= 20n, { what: "allowance", ...c });
  assert.equal(v, 20n);
  assert.equal(i, 4, "the first fresh read alone is not trusted");
});

test("a flapping node (fresh, stale, fresh) resets the streak", async () => {
  const c = clock();
  const reads = [20n, 0n, 20n, 20n];
  let i = 0;
  await waitForStable(async () => reads[Math.min(i++, reads.length - 1)], x => x >= 20n, { what: "allowance", ...c });
  assert.equal(i, 4);
});

test("read errors are tolerated and count as nothing", async () => {
  const c = clock();
  let i = 0;
  const v = await waitForStable(
    async () => {
      i += 1;
      if (i < 3) throw new Error("rpc 429");
      return 5n;
    },
    x => x >= 5n,
    { what: "allowance", ...c },
  );
  assert.equal(v, 5n);
});

test("never visible: gives up with a typed error that says nothing further was sent", async () => {
  const c = clock();
  await assert.rejects(
    waitForStable(async () => 0n, x => x > 0n, { what: "The approval", timeoutMs: 6_000, intervalMs: 1_500, ...c }),
    (e: any) => e instanceof NotVisibleYet && /nothing further was sent/.test(e.message) && /6 s/.test(e.message),
  );
});

test("already visible: two reads, no wait beyond one interval", async () => {
  const c = clock();
  await waitForStable(async () => 1n, x => x === 1n, { what: "x", ...c });
  assert.equal(c.now(), 1_500);
});
