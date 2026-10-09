import assert from "node:assert/strict";
import { test } from "node:test";
import { MAX_UINT256, formatUsdcDecimal, parsePositiveCents, parseUsdc, roundUpToCent } from "./amounts.ts";

test("USDC parsing preserves the exact smallest units and large balances", () => {
  assert.equal(parseUsdc("0.000001"), 1n);
  assert.equal(parseUsdc(".01"), 10_000n);
  assert.equal(parseUsdc("9007199254740993.123456"), 9_007_199_254_740_993_123_456n);
  assert.equal(parseUsdc(" 1. "), 1_000_000n);
  assert.equal(parseUsdc("0"), 0n); // clearing backing is allowed
});

test("malformed, fractional-unit and overflowing inputs never become signed amounts", () => {
  for (const input of ["", " ", "Infinity", "NaN", "1e3", "1x", "1.2.3", "-1", "0x10", "1.0000001", "1,000"])
    assert.equal(parseUsdc(input), null, input);
  assert.equal(parseUsdc((MAX_UINT256 / 1_000_000n + 1n).toString()), null);
});

test("cent inputs cannot round up beyond the entered amount or become zero-value loans", () => {
  assert.equal(parsePositiveCents("1.239999"), 1_230_000n);
  assert.equal(parsePositiveCents("0.009999"), null);
  assert.equal(parsePositiveCents("0"), null);
  assert.equal(roundUpToCent(1_230_001n), 1_240_000n);
});

test("formatting keeps cents exact beyond the safe-integer range", () => {
  assert.equal(formatUsdcDecimal(9_007_199_254_740_993_123_456n), "9007199254740993.12");
  assert.equal(formatUsdcDecimal(1_005_000n), "1.01");
  assert.equal(formatUsdcDecimal(-1_005_000n), "-1.01");
  assert.equal(formatUsdcDecimal(-1n), "0.00");
});
