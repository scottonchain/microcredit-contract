/**
 * Wallet-direct loan origination as a two-step intent (requestLoan, then disburseLoan) that is bound to its own
 * receipts and fails closed while an outcome is unknown.
 *
 * The borrower page persists an intent (chain, pool, borrower, amount, the loan ids seen before the request and the
 * transaction hash as soon as the wallet returns one) before it awaits confirmation. The loan that the request
 * created is identified from the LoanRequested event in that transaction's receipt, never from the length of the
 * borrower's id array. While an intent is unresolved the page shows reconciliation and permits no new request; a
 * reload, a rejected second signature, a receipt timeout, a stale read or a second tab all land in `reconcileIntent`.
 *
 * Pure functions only (viem for decoding); the page supplies storage and chain reads. Tested in originationIntent.test.ts.
 */
import { type Address, type Hex, type Log, parseAbi, parseEventLogs } from "viem";

export const INTENT_VERSION = 1 as const;
/** An intent that has no transaction hash and matches no loan on chain may be dismissed by the borrower after this long. */
export const UNRESOLVED_DISMISS_AFTER_MS = 10 * 60 * 1000;
/** Clock skew tolerated between the browser and the chain when matching a loan to an intent without a hash. */
export const MATCH_SKEW_MS = 2 * 60 * 1000;

/** LoanStatus of DecentralizedMicrocredit. */
export const LoanStatus = { None: 0, Requested: 1, Active: 2, Repaid: 3, Defaulted: 4, Cancelled: 5 } as const;

export const LOAN_REQUESTED_ABI = parseAbi([
  "event LoanRequested(address indexed borrower, uint256 indexed loanId, uint256 amount, uint256 interestRate)",
]);

export type IntentStage = "requesting" | "requested" | "disbursing";

export type OriginationIntent = {
  version: typeof INTENT_VERSION;
  chainId: number;
  pool: Address;
  borrower: Address;
  /** Principal in micro-USDC, as a decimal string (bigint does not survive JSON). */
  amount: string;
  /** Milliseconds since the epoch, taken before the wallet was asked to sign. */
  createdAt: number;
  /** The borrower's loan ids read before the request was sent, as decimal strings. */
  idsBefore: string[];
  stage: IntentStage;
  requestTxHash?: Hex;
  /** Known once the request's receipt was decoded, or a matching loan was adopted. */
  loanId?: string;
  disburseTxHash?: Hex;
};

export type StorageLike = {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
};

export const intentKey = (chainId: number, pool: Address, borrower: Address) =>
  `microcredit:origination:v${INTENT_VERSION}:${chainId}:${pool.toLowerCase()}:${borrower.toLowerCase()}`;

export function loadIntent(storage: StorageLike | undefined, key: string): OriginationIntent | null {
  try {
    const raw = storage?.getItem(key);
    if (!raw) return null;
    const value = JSON.parse(raw);
    if (!value || value.version !== INTENT_VERSION || typeof value.stage !== "string" || typeof value.amount !== "string") {
      return null;
    }
    return value as OriginationIntent;
  } catch {
    return null;
  }
}

export function saveIntent(storage: StorageLike | undefined, key: string, intent: OriginationIntent): void {
  try {
    storage?.setItem(key, JSON.stringify(intent));
  } catch {
    /* storage unavailable: the in-memory copy still gates this tab */
  }
}

export function clearIntent(storage: StorageLike | undefined, key: string): void {
  try {
    storage?.removeItem(key);
  } catch {
    /* noop */
  }
}

export function newIntent(args: {
  chainId: number;
  pool: Address;
  borrower: Address;
  amount: bigint;
  idsBefore: readonly bigint[];
  now: number;
}): OriginationIntent {
  return {
    version: INTENT_VERSION,
    chainId: args.chainId,
    pool: args.pool,
    borrower: args.borrower,
    amount: args.amount.toString(),
    createdAt: args.now,
    idsBefore: args.idsBefore.map(id => id.toString()),
    stage: "requesting",
  };
}

// ---- what the page may show ------------------------------------------------------------------------------------

export type ChainFacts = {
  /** The borrower's loan ids; undefined while the read has not completed. */
  loanIds: readonly bigint[] | undefined;
  /** LoanStatus of the newest id; undefined while that read has not completed (or there are no loans). */
  newestLoanStatus: number | undefined;
};

export type OriginationDecision =
  | { kind: "loading" }
  | { kind: "reconcile"; intent: OriginationIntent }
  | { kind: "requested_on_chain"; loanId: bigint }
  | { kind: "active_loan"; loanId: bigint }
  | { kind: "allow_new_request" };

/**
 * Whether the page may offer a new loan request. An unresolved intent always wins; unloaded reads are never read as
 * "no loan"; a Requested loan on chain (from this page or anywhere else) is offered for disbursement or cancellation.
 */
export function decideOrigination(intent: OriginationIntent | null, facts: ChainFacts): OriginationDecision {
  if (intent) return { kind: "reconcile", intent };
  if (facts.loanIds === undefined) return { kind: "loading" };
  if (facts.loanIds.length === 0) return { kind: "allow_new_request" };
  const newest = facts.loanIds.reduce((a, b) => (a > b ? a : b));
  if (facts.newestLoanStatus === undefined) return { kind: "loading" };
  if (facts.newestLoanStatus === LoanStatus.Requested) return { kind: "requested_on_chain", loanId: newest };
  if (facts.newestLoanStatus === LoanStatus.Active) return { kind: "active_loan", loanId: newest };
  return { kind: "allow_new_request" };
}

// ---- binding a request to its receipt ---------------------------------------------------------------------------

export class NoMatchingLoanRequested extends Error {
  constructor(message: string) {
    super(message);
    this.name = "NoMatchingLoanRequested";
  }
}

/**
 * The loan id that this request created: the one LoanRequested event in the receipt, emitted by the pool, for this
 * borrower and this amount. Anything else (none, another borrower's, another amount, two of them) is an error, not a
 * guess.
 */
export function matchRequestedLoan(
  logs: readonly Pick<Log, "address" | "topics" | "data">[],
  expected: { pool: Address; borrower: Address; amount: bigint },
): bigint {
  const fromPool = logs.filter(l => l.address.toLowerCase() === expected.pool.toLowerCase());
  const events = parseEventLogs({ abi: LOAN_REQUESTED_ABI, eventName: "LoanRequested", logs: fromPool as Log[] });
  const mine = events.filter(
    e => e.args.borrower.toLowerCase() === expected.borrower.toLowerCase() && e.args.amount === expected.amount,
  );
  if (mine.length !== 1) {
    throw new NoMatchingLoanRequested(
      mine.length === 0
        ? "the receipt carries no LoanRequested event from the pool for this borrower and amount"
        : "the receipt carries more than one matching LoanRequested event",
    );
  }
  return mine[0].args.loanId;
}

// ---- reconciliation ---------------------------------------------------------------------------------------------

export type ReceiptFacts = { status: "success" | "reverted"; logs: readonly Pick<Log, "address" | "topics" | "data">[] };

export type ReconcileFacts = {
  /** Receipt of intent.requestTxHash: undefined = not looked up (no hash), null = not found yet. */
  requestReceipt?: ReceiptFacts | null;
  /** LoanStatus of intent.loanId, once known. */
  loanStatus?: number;
  /** Receipt of intent.disburseTxHash: undefined = not looked up, null = not found yet. */
  disburseReceipt?: Pick<ReceiptFacts, "status"> | null;
  /** For an intent without a hash: the borrower's loans whose ids were not in idsBefore, with their facts. */
  candidates?: { loanId: bigint; status: number; amount: bigint; requestedAtMs: number }[];
};

export type ReconcileOutcome =
  | { kind: "wait"; reason: string }
  | { kind: "adopt"; loanId: bigint }
  | { kind: "offer_disburse"; loanId: bigint }
  | { kind: "clear"; reason: string }
  | { kind: "may_dismiss"; reason: string };

/**
 * What to do with a persisted intent given what the chain says now. Never returns a decision that allows a new
 * request while the outcome is unknown: "wait" keeps checking, "may_dismiss" needs the borrower's explicit act after
 * UNRESOLVED_DISMISS_AFTER_MS with no hash and no matching loan.
 */
export function reconcileIntent(intent: OriginationIntent, facts: ReconcileFacts, now: number): ReconcileOutcome {
  const expected = { pool: intent.pool, borrower: intent.borrower, amount: BigInt(intent.amount) };
  if (intent.stage === "requesting") {
    if (intent.requestTxHash) {
      if (facts.requestReceipt === undefined || facts.requestReceipt === null) {
        return { kind: "wait", reason: "waiting for the loan request's receipt" };
      }
      if (facts.requestReceipt.status === "reverted") {
        return { kind: "clear", reason: "the loan request reverted: nothing was reserved" };
      }
      try {
        return { kind: "adopt", loanId: matchRequestedLoan(facts.requestReceipt.logs, expected) };
      } catch (e: any) {
        return { kind: "wait", reason: "the request's receipt did not identify a loan: " + (e?.message ?? String(e)) };
      }
    }
    const since = intent.createdAt - MATCH_SKEW_MS;
    const matches = (facts.candidates ?? []).filter(
      c =>
        c.amount === expected.amount &&
        c.requestedAtMs >= since &&
        !intent.idsBefore.includes(c.loanId.toString()) &&
        (c.status === LoanStatus.Requested || c.status === LoanStatus.Active),
    );
    if (matches.length === 1) return { kind: "adopt", loanId: matches[0].loanId };
    if (matches.length > 1) return { kind: "wait", reason: "more than one loan matches this request; review your loans" };
    if (now - intent.createdAt >= UNRESOLVED_DISMISS_AFTER_MS) {
      return {
        kind: "may_dismiss",
        reason: "no transaction hash was returned and no matching loan appeared within 10 minutes",
      };
    }
    return { kind: "wait", reason: "no transaction hash was returned; checking whether the request landed" };
  }
  if (intent.stage === "requested") {
    if (facts.loanStatus === undefined) return { kind: "wait", reason: "reading the requested loan" };
    if (facts.loanStatus === LoanStatus.Requested) return { kind: "offer_disburse", loanId: BigInt(intent.loanId ?? "0") };
    if (facts.loanStatus === LoanStatus.Active) return { kind: "clear", reason: "the loan is disbursed" };
    if (facts.loanStatus === LoanStatus.Cancelled) return { kind: "clear", reason: "the request was cancelled" };
    return { kind: "clear", reason: "the loan is closed" };
  }
  // disbursing
  if (facts.disburseReceipt === undefined || facts.disburseReceipt === null) {
    return { kind: "wait", reason: "waiting for the disbursement's receipt" };
  }
  if (facts.disburseReceipt.status === "reverted") return { kind: "offer_disburse", loanId: BigInt(intent.loanId ?? "0") };
  return { kind: "clear", reason: "the loan is disbursed" };
}

/** True when a wallet error means nothing was broadcast (the user rejected the prompt), so an intent can be dropped. */
export function isUserRejection(error: unknown): boolean {
  const e = error as any;
  const code = e?.code ?? e?.cause?.code ?? e?.cause?.cause?.code;
  if (code === 4001) return true;
  const name = e?.name ?? e?.cause?.name;
  if (name === "UserRejectedRequestError" || e?.cause?.name === "UserRejectedRequestError") return true;
  const msg = String(e?.shortMessage ?? e?.message ?? "").toLowerCase();
  return msg.includes("user rejected") || msg.includes("user denied");
}
