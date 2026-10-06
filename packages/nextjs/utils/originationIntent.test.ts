import assert from "node:assert/strict";
import { test } from "node:test";
import { encodeAbiParameters, encodeEventTopics } from "viem";
import {
  LOAN_REQUESTED_ABI,
  LoanStatus,
  MATCH_SKEW_MS,
  NoMatchingLoanRequested,
  type OriginationIntent,
  UNRESOLVED_DISMISS_AFTER_MS,
  clearIntent,
  decideOrigination,
  intentKey,
  isUserRejection,
  loadIntent,
  matchRequestedLoan,
  newIntent,
  reconcileIntent,
  saveIntent,
} from "./originationIntent.ts";

const POOL = "0xa49B9352B2e8C2B79b58cb4C60dB43342e08Afa8" as const;
const ME = "0x1111111111111111111111111111111111111111" as const;
const OTHER = "0x2222222222222222222222222222222222222222" as const;
const AMOUNT = 5_000_000n;

const requestedLog = (args: { address?: string; borrower?: string; loanId: bigint; amount?: bigint }) => ({
  address: args.address ?? POOL,
  topics: encodeEventTopics({
    abi: LOAN_REQUESTED_ABI,
    eventName: "LoanRequested",
    args: { borrower: (args.borrower ?? ME) as `0x${string}`, loanId: args.loanId },
  }),
  data: encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }], [args.amount ?? AMOUNT, 933n]),
});

const memoryStorage = () => {
  const m = new Map<string, string>();
  return {
    getItem: (k: string) => m.get(k) ?? null,
    setItem: (k: string, v: string) => void m.set(k, v),
    removeItem: (k: string) => void m.delete(k),
  };
};

const T0 = 1_760_000_000_000;
const base = (): OriginationIntent => newIntent({ chainId: 84532, pool: POOL, borrower: ME, amount: AMOUNT, idsBefore: [3n], now: T0 });

test("the receipt identifies the loan: pool, borrower and amount must all match", () => {
  const exp = { pool: POOL, borrower: ME, amount: AMOUNT };
  assert.equal(matchRequestedLoan([requestedLog({ loanId: 7n })], exp), 7n);
  assert.throws(() => matchRequestedLoan([], exp), NoMatchingLoanRequested);
  assert.throws(() => matchRequestedLoan([requestedLog({ loanId: 7n, borrower: OTHER })], exp), NoMatchingLoanRequested);
  assert.throws(() => matchRequestedLoan([requestedLog({ loanId: 7n, amount: 4_000_000n })], exp), NoMatchingLoanRequested);
  assert.throws(() => matchRequestedLoan([requestedLog({ loanId: 7n, address: OTHER })], exp), NoMatchingLoanRequested);
  assert.throws(() => matchRequestedLoan([requestedLog({ loanId: 7n }), requestedLog({ loanId: 8n })], exp), NoMatchingLoanRequested);
  // another borrower's request in the same block is ignored, ours is found
  assert.equal(matchRequestedLoan([requestedLog({ loanId: 9n, borrower: OTHER }), requestedLog({ loanId: 10n })], exp), 10n);
});

test("unloaded reads are never 'no loan'; an intent always wins; a Requested loan on chain is offered, never ignored", () => {
  assert.deepEqual(decideOrigination(null, { loanIds: undefined, newestLoanStatus: undefined }), { kind: "loading" });
  assert.deepEqual(decideOrigination(null, { loanIds: [3n], newestLoanStatus: undefined }), { kind: "loading" });
  assert.deepEqual(decideOrigination(null, { loanIds: [], newestLoanStatus: undefined }), { kind: "allow_new_request" });
  assert.deepEqual(decideOrigination(null, { loanIds: [3n, 5n], newestLoanStatus: LoanStatus.Requested }), { kind: "requested_on_chain", loanId: 5n });
  assert.deepEqual(decideOrigination(null, { loanIds: [5n, 3n], newestLoanStatus: LoanStatus.Active }), { kind: "active_loan", loanId: 5n });
  assert.deepEqual(decideOrigination(null, { loanIds: [3n], newestLoanStatus: LoanStatus.Repaid }), { kind: "allow_new_request" });
  const i = base();
  assert.deepEqual(decideOrigination(i, { loanIds: [], newestLoanStatus: undefined }), { kind: "reconcile", intent: i });
  assert.deepEqual(decideOrigination(i, { loanIds: undefined, newestLoanStatus: undefined }), { kind: "reconcile", intent: i });
});

test("receipt timeout: the hash was persisted, so a reload waits for the receipt and then adopts the loan it names", () => {
  const i = { ...base(), requestTxHash: "0xabc" as `0x${string}` };
  assert.deepEqual(reconcileIntent(i, {}, T0 + 1).kind, "wait");
  assert.deepEqual(reconcileIntent(i, { requestReceipt: null }, T0 + 1).kind, "wait");
  assert.deepEqual(reconcileIntent(i, { requestReceipt: { status: "success", logs: [requestedLog({ loanId: 7n })] } }, T0 + 1), { kind: "adopt", loanId: 7n });
  assert.equal(reconcileIntent(i, { requestReceipt: { status: "reverted", logs: [] } }, T0 + 1).kind, "clear");
  // a successful receipt that names no loan of ours is not adopted and does not free the form
  assert.equal(reconcileIntent(i, { requestReceipt: { status: "success", logs: [requestedLog({ loanId: 7n, borrower: OTHER })] } }, T0 + 1).kind, "wait");
});

test("no hash: a stale or lagging read never identifies the loan; only a new loan with our amount after the intent does", () => {
  const i = base();
  // nothing new yet: wait, then after the window the borrower may dismiss (never an automatic new request)
  assert.equal(reconcileIntent(i, { candidates: [] }, T0 + 1000).kind, "wait");
  assert.equal(reconcileIntent(i, { candidates: [] }, T0 + UNRESOLVED_DISMISS_AFTER_MS).kind, "may_dismiss");
  // a loan that was already there (idsBefore) is not ours even if it matches
  const old = { loanId: 3n, status: LoanStatus.Requested, amount: AMOUNT, requestedAtMs: T0 + 10 };
  assert.equal(reconcileIntent(i, { candidates: [old] }, T0 + 1000).kind, "wait");
  // a new loan from before the intent (another tab's request) is not ours
  const earlier = { loanId: 6n, status: LoanStatus.Requested, amount: AMOUNT, requestedAtMs: T0 - MATCH_SKEW_MS - 1 };
  assert.equal(reconcileIntent(i, { candidates: [earlier] }, T0 + 1000).kind, "wait");
  // a new loan with another amount is not ours
  const other = { loanId: 6n, status: LoanStatus.Requested, amount: 4_000_000n, requestedAtMs: T0 + 10 };
  assert.equal(reconcileIntent(i, { candidates: [other] }, T0 + 1000).kind, "wait");
  // exactly one new matching loan: adopt
  const mine = { loanId: 7n, status: LoanStatus.Requested, amount: AMOUNT, requestedAtMs: T0 + 10 };
  assert.deepEqual(reconcileIntent(i, { candidates: [mine] }, T0 + 1000), { kind: "adopt", loanId: 7n });
  // two matching new loans (two tabs sent the same request): never guess
  const twin = { ...mine, loanId: 8n };
  assert.equal(reconcileIntent(i, { candidates: [mine, twin] }, T0 + 1000).kind, "wait");
});

test("rejected second signature: the loan stays requested and is offered for disbursement by its own id", () => {
  const i = { ...base(), stage: "requested" as const, loanId: "7", requestTxHash: "0xabc" as `0x${string}` };
  assert.equal(reconcileIntent(i, {}, T0).kind, "wait");
  assert.deepEqual(reconcileIntent(i, { loanStatus: LoanStatus.Requested }, T0), { kind: "offer_disburse", loanId: 7n });
  assert.equal(reconcileIntent(i, { loanStatus: LoanStatus.Active }, T0).kind, "clear");
  assert.equal(reconcileIntent(i, { loanStatus: LoanStatus.Cancelled }, T0).kind, "clear");
  const d = { ...i, stage: "disbursing" as const, disburseTxHash: "0xdef" as `0x${string}` };
  assert.equal(reconcileIntent(d, {}, T0).kind, "wait");
  assert.equal(reconcileIntent(d, { disburseReceipt: null }, T0).kind, "wait");
  assert.deepEqual(reconcileIntent(d, { disburseReceipt: { status: "reverted" } }, T0), { kind: "offer_disburse", loanId: 7n });
  assert.equal(reconcileIntent(d, { disburseReceipt: { status: "success" } }, T0).kind, "clear");
});

test("two tabs: the intent is keyed by chain, pool and borrower, so the second tab sees the first tab's intent", () => {
  const s = memoryStorage();
  const key = intentKey(84532, POOL, ME);
  assert.equal(intentKey(84532, POOL.toLowerCase() as `0x${string}`, ME), key);
  assert.equal(loadIntent(s, key), null);
  const i = base();
  saveIntent(s, key, i);
  const seen = loadIntent(s, key);
  assert.ok(seen);
  assert.deepEqual(decideOrigination(seen, { loanIds: [], newestLoanStatus: undefined }).kind, "reconcile");
  // a broken or foreign record is ignored, not trusted
  s.setItem(key, "{\"version\":99}");
  assert.equal(loadIntent(s, key), null);
  s.setItem(key, "not json");
  assert.equal(loadIntent(s, key), null);
  clearIntent(s, key);
  assert.equal(loadIntent(s, key), null);
});

test("only a wallet rejection drops an intent before a hash exists", () => {
  assert.equal(isUserRejection({ code: 4001 }), true);
  assert.equal(isUserRejection({ name: "UserRejectedRequestError" }), true);
  assert.equal(isUserRejection({ cause: { name: "UserRejectedRequestError" } }), true);
  assert.equal(isUserRejection(new Error("User rejected the request.")), true);
  assert.equal(isUserRejection(new Error("Failed to fetch")), false);
  assert.equal(isUserRejection(new Error("timeout waiting for receipt")), false);
  assert.equal(isUserRejection(undefined), false);
});
