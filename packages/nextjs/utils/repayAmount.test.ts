import assert from "node:assert/strict";
import { test } from "node:test";
import { CENT, SECONDS_PER_YEAR, isResidualDebt, payoffAmount, payoffHeadroom, repaymentAmount } from "./repayAmount.ts";
import { formatUSDCExact } from "./format.ts";

const usdc = (whole: bigint) => whole * 1_000_000n;

// The pool's accrual: simple interest on the original principal, floor-divided like the contract.
const owedAfter = (principal: bigint, rateBps: bigint, seconds: bigint): bigint =>
  principal + (((principal * rateBps) / 10_000n) * seconds) / SECONDS_PER_YEAR;
const ceilToCent = (a: bigint): bigint => ((a + CENT - 1n) / CENT) * CENT;

test("headroom is one cent for ordinary loans and grows with the quote", () => {
  assert.equal(payoffHeadroom(usdc(1n)), CENT);
  assert.equal(payoffHeadroom(usdc(100n)), CENT);
  assert.equal(payoffHeadroom(usdc(500n)), CENT);
  assert.ok(payoffHeadroom(usdc(10_000n)) > CENT, "a large loan accrues more than a cent in ten minutes at 100% APR");
  assert.equal(payoffHeadroom(usdc(10_000n)) % CENT, 0n, "whole cents");
});

test("the stale-quote regression: a cent-rounded quote alone falls short after a delay, the payoff amount does not", () => {
  // Matches the Foundry measurement: 500 USDC at 10% APR, quote taken, payment mined 600 s later.
  const principal = usdc(500n);
  const rate = 1_000n;
  const quote = ceilToCent(owedAfter(principal, rate, 0n));
  const owedWhenMined = owedAfter(principal, rate, 600n);
  assert.ok(owedWhenMined > quote, "interest accrued since the quote exceeds the cent rounding");
  assert.ok(quote < owedWhenMined, "paying the bare quote leaves the loan open");
  assert.ok(payoffAmount(quote) >= owedWhenMined, "the payoff amount covers the same delay and closes it");
});

test("headroom covers ten minutes of interest at the highest rate the pool allows, at any size", () => {
  for (const principal of [usdc(1n), usdc(40n), usdc(500n), usdc(5_000n), usdc(100_000n)]) {
    for (const rate of [250n, 1_000n, 2_500n, 10_000n]) {
      const quote = ceilToCent(owedAfter(principal, rate, 0n));
      assert.ok(
        payoffAmount(quote) >= owedAfter(principal, rate, 600n),
        `principal ${principal} at ${rate} bps stays covered for 600 s`,
      );
    }
  }
});

test("a zero quote needs nothing", () => {
  assert.equal(payoffAmount(0n), 0n);
});

test("repaymentAmount: partial amounts are used as typed, a typed balance becomes a payoff", () => {
  const quote = 12_340_000n;
  assert.deepEqual(repaymentAmount(5_000_000n, quote), { amount: 5_000_000n, isPayoff: false });
  assert.deepEqual(repaymentAmount(quote - 1n, quote), { amount: quote - 1n, isPayoff: false });
  const atQuote = repaymentAmount(quote, quote);
  assert.equal(atQuote.isPayoff, true);
  assert.equal(atQuote.amount, quote + payoffHeadroom(quote));
  assert.equal(repaymentAmount(quote + 1_000_000n, quote).isPayoff, true);
  assert.throws(() => repaymentAmount(0n, quote));
});

test("isResidualDebt flags an active loan with under a cent owed, and nothing else", () => {
  assert.equal(isResidualDebt(true, 11n), true);
  assert.equal(isResidualDebt(true, CENT - 1n), true);
  assert.equal(isResidualDebt(true, CENT), false);
  assert.equal(isResidualDebt(true, 0n), false);
  assert.equal(isResidualDebt(false, 11n), false);
  assert.equal(isResidualDebt(true, undefined), false);
});

test("formatUSDCExact shows sub-cent balances that formatUSDC rounds to $0.00", () => {
  assert.equal(formatUSDCExact(11n), "$0.000011");
  assert.equal(formatUSDCExact(9_999n), "$0.009999");
  assert.equal(formatUSDCExact(10_000n), "$0.01");
  assert.equal(formatUSDCExact(1_000_000n), "$1.00");
  assert.equal(formatUSDCExact(12_345_600n), "$12.3456");
});
