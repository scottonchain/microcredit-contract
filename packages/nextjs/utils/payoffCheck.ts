import type { PayoffOutcome } from "./repayAmount.ts";

/**
 * The check the borrower page runs after a full payoff is mined: did the loan close? It is its own module, with the
 * stability helper injected, so the page and its tests run the same orchestration.
 *
 * A mined success proves a payment, not closure. Closure is confirmed only when the stability check itself resolves,
 * that is when the loan read closed on consecutive successful reads (a node can lag a receipt, so one read is not
 * enough). A closed read that the stability check did not confirm (one closed read followed by errors, or a closed
 * read at the timeout) is unknown, never closed. A failed read leaves nothing fresh behind: an earlier open result is
 * not carried over a later failure, so an exact residual is reported only when the last read succeeded.
 */
export type StableWaiter = <T>(
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
) => Promise<T>;

export type PayoffCheckTiming = {
  timeoutMs?: number;
  intervalMs?: number;
  stableReads?: number;
  sleep?: (ms: number) => Promise<void>;
  now?: () => number;
};

export async function confirmPayoffOutcome(
  readOutcome: () => Promise<PayoffOutcome>,
  waitForStable: StableWaiter,
  timing: PayoffCheckTiming = {},
): Promise<PayoffOutcome> {
  // `as` keeps TypeScript from narrowing `last` to its initial value: it is assigned inside the read closure below.
  let last = { kind: "unknown" } as PayoffOutcome;
  const read = async (): Promise<PayoffOutcome> => {
    last = { kind: "unknown" }; // a failed read leaves nothing fresh behind
    last = await readOutcome();
    return last;
  };
  try {
    await waitForStable(read, o => o.kind === "closed", {
      what: "The loan status",
      timeoutMs: timing.timeoutMs ?? 9_000,
      intervalMs: timing.intervalMs ?? 1_500,
      stableReads: timing.stableReads,
      sleep: timing.sleep,
      now: timing.now,
    });
    return { kind: "closed" }; // only a resolved stability check confirms closure
  } catch {
    // Not confirmed. A fresh open result keeps its exact residual; closed-but-unconfirmed and failed reads are unknown.
    return last.kind === "open" ? last : { kind: "unknown" };
  }
}

/** The notice for an outcome, in the borrower's terms. Empty when the loan is confirmed closed. */
export function payoffNotice(outcome: PayoffOutcome, formatExact: (amount: bigint) => string): string {
  if (outcome.kind === "closed") return "";
  if (outcome.kind === "open") {
    return `The payment went through, but the loan is still open: ${formatExact(outcome.owed)} is still owed. Interest accrued while the payment was being mined. Pay the full balance again to close it.`;
  }
  return "The payment went through, but I could not confirm that the loan is closed. Check the balance shown below before relying on it.";
}
