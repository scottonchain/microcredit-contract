/**
 * Waiting for a mined write to be visible to reads, safely. A public RPC endpoint is often several nodes behind one
 * address: a receipt can be seen on one while an `eth_call` a moment later still reads the old state on another. The
 * two-step wallet flows (approve, then deposit, stake or repay) simulate their second step before sending it, so a
 * stale allowance reads as a revert and the second transaction is never sent while the first already was.
 *
 * `waitForStable` re-reads until the condition holds on `stableReads` consecutive reads (default 2, spaced by
 * `intervalMs`), tolerating read errors, and gives up with a typed error that says what is true: the earlier step is in
 * place, nothing further was sent, press the button again.
 */
export class NotVisibleYet extends Error {
  constructor(what: string, seconds: number) {
    super(
      `${what} is mined but not yet visible to the network after ${seconds} s; nothing further was sent. Wait a moment and press the button again: the earlier step is already in place.`,
    );
    this.name = "NotVisibleYet";
  }
}

export async function waitForStable<T>(
  read: () => Promise<T>,
  ok: (value: T) => boolean,
  opts: {
    what: string;
    timeoutMs?: number;
    intervalMs?: number;
    stableReads?: number;
    sleep?: (ms: number) => Promise<void>;
    now?: () => number;
  },
): Promise<T> {
  const timeoutMs = opts.timeoutMs ?? 30_000;
  const intervalMs = opts.intervalMs ?? 1_500;
  const stableReads = opts.stableReads ?? 2;
  const sleep = opts.sleep ?? ((ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms)));
  const now = opts.now ?? (() => Date.now());
  const deadline = now() + timeoutMs;
  let streak = 0;
  for (;;) {
    try {
      const value = await read();
      if (ok(value)) {
        streak += 1;
        if (streak >= stableReads) return value;
      } else {
        streak = 0;
      }
    } catch {
      streak = 0; // a failed read proves nothing either way
    }
    if (now() >= deadline) throw new NotVisibleYet(opts.what, Math.round(timeoutMs / 1000));
    await sleep(intervalMs);
  }
}
