/** Exact USDC arithmetic shared by borrowing, lending and backing. */
export const USDC_SCALE = 1_000_000n;
export const CENT = 10_000n;
export const MAX_UINT256 = (1n << 256n) - 1n;

/** Plain decimal input only: never round a number the wallet is about to sign. */
export function parseUsdc(value: string): bigint | null {
  const text = value.trim();
  if (text.length > 85 || !/^(?:\d+(?:\.\d{0,6})?|\.\d{1,6})$/.test(text)) return null;
  const [whole, fraction = ""] = text.split(".");
  const amount = BigInt(whole || "0") * USDC_SCALE + BigInt(fraction.padEnd(6, "0"));
  return amount <= MAX_UINT256 ? amount : null;
}

export const roundDownToCent = (amount: bigint) => (amount / CENT) * CENT;
export const roundUpToCent = (amount: bigint) => ((amount + CENT - 1n) / CENT) * CENT;
export const roundToCentHalfUp = (amount: bigint) => ((amount + CENT / 2n) / CENT) * CENT;

/** Existing loan/deposit/withdrawal inputs use whole cents and a positive amount. */
export function parsePositiveCents(value: string): bigint | null {
  const amount = parseUsdc(value);
  if (amount === null) return null;
  const cents = roundDownToCent(amount);
  return cents > 0n ? cents : null;
}

/** Fixed two-decimal display without converting large token balances to a floating point number. */
export function formatUsdcDecimal(amount: bigint): string {
  const negative = amount < 0n;
  const cents = ((negative ? -amount : amount) + CENT / 2n) / CENT;
  return `${negative && cents > 0n ? "-" : ""}${cents / 100n}.${(cents % 100n).toString().padStart(2, "0")}`;
}
