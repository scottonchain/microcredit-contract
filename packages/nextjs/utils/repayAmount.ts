/**
 * Amounts a caller approves, permits or passes when paying a loan off.
 *
 * The pool no longer forgives a balance under a cent: a loan closes only when its whole balance is paid, and the
 * balance keeps growing until the payment is mined. A payoff quoted to the cent (`getOutstandingRoundedToCent`) and
 * then approved or permitted for exactly that amount can fall short by the interest that accrued in between, which
 * leaves the loan open with a sliver owed, its credit usage held and no completed-loan credit. The pool pulls
 * `min(amount, owed)`, so a little headroom over the quote costs nothing: it is never taken, only allowed.
 *
 * Every approved, permitted or passed payoff amount in the app, the relayer callers and any agent script comes from
 * `payoffAmount`.
 */
export const CENT = 10_000n; // 0.01 USDC (6 decimals)
export const SECONDS_PER_YEAR = 365n * 24n * 60n * 60n;
/** Delay the headroom must cover between the quote and the payment being mined: signing, relaying, congestion. */
export const PAYOFF_HEADROOM_SECONDS = 600n;
/** Upper bound on the pool's APR, in basis points: the contract rejects effr + premium above 100%. */
export const MAX_RATE_BPS = 10_000n;

const ceilToCent = (amount: bigint): bigint => ((amount + CENT - 1n) / CENT) * CENT;

/**
 * Headroom over a payoff quote: at least one cent, and enough to cover `PAYOFF_HEADROOM_SECONDS` of interest at the
 * highest rate the pool allows, so it is sufficient for any loan whose quote is `quote`. For a 100 USDC loan that is
 * one cent; for a 10,000 USDC loan it is about 1.9 cents at a 10% APR and about 19 cents at the 100% ceiling.
 */
export const payoffHeadroom = (quote: bigint): bigint => {
  if (quote < 0n) throw new Error("quote must not be negative");
  const accruing = (quote * MAX_RATE_BPS * PAYOFF_HEADROOM_SECONDS) / (10_000n * SECONDS_PER_YEAR);
  const bound = ceilToCent(accruing + 1n);
  return bound > CENT ? bound : CENT;
};

/** The amount to approve, permit or pass to pay a loan off: the cent-rounded quote plus headroom. */
export const payoffAmount = (quote: bigint): bigint => (quote === 0n ? 0n : quote + payoffHeadroom(quote));

/**
 * What the pool says once a payoff is mined. A mined success, and the `LoanRepaid` event with its `amountUsed`, prove a
 * payment and the amount actually pulled; the event also fires for partial repayments, so neither proves the loan
 * closed. Only the loan's own state does: closed means not active with nothing owed; open means still active with a
 * balance left, shown in base units; anything else (a missing or inconsistent read) is unknown and never reported as
 * closed. A caller's entered amount for a partial payment is a cap and is never raised by this module.
 */
export type PayoffOutcome = { kind: "closed" } | { kind: "open"; owed: bigint } | { kind: "unknown" };

export const payoffOutcome = (active: boolean | undefined, owed: bigint | undefined): PayoffOutcome => {
  if (active === undefined || owed === undefined) return { kind: "unknown" };
  if (!active) return owed === 0n ? { kind: "closed" } : { kind: "unknown" };
  return owed > 0n ? { kind: "open", owed } : { kind: "unknown" };
};

/**
 * A loan that is still active with less than a cent owed: the state a short payoff leaves behind. The page shows it
 * with the exact amount so the borrower sees what remains and can pay it in one step.
 */
export const isResidualDebt = (active: boolean, exactOutstanding: bigint | undefined): boolean =>
  active && exactOutstanding !== undefined && exactOutstanding > 0n && exactOutstanding < CENT;
