// EIP-712 / EIP-2612 typed-data definitions shared by the signing UI flows.
// Field order must match the typehashes in DecentralizedMicrocredit.sol and ERC20Permit.

export const MICRO_DOMAIN = (chainId: number, verifyingContract: `0x${string}`) => ({
  name: "DecentralizedMicrocredit",
  version: "1",
  chainId,
  verifyingContract,
});

export const USDC_PERMIT_DOMAIN = (chainId: number, verifyingContract: `0x${string}`, tokenName = "USD Coin") => ({
  name: tokenName,
  version: "1",
  chainId,
  verifyingContract,
});

export const TYPES = {
  BorrowAndDisburse: [
    { name: "borrower", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "to", type: "address" },
    { name: "repaymentPeriod", type: "uint256" },
    { name: "maxAprBps", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  RequestWithdrawal: [
    { name: "lender", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "to", type: "address" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  AttestRequest: [
    { name: "attester", type: "address" },
    { name: "borrower", type: "address" },
    { name: "weight", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  Permit: [
    { name: "owner", type: "address" },
    { name: "spender", type: "address" },
    { name: "value", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

export type AttestRequest = {
  attester: `0x${string}`;
  borrower: `0x${string}`;
  weight: bigint; // scaled by 1e6 (SCALE)
  nonce: bigint;
  deadline: bigint;
};

/** Splits a 65-byte signature into the (v, r, s) form ERC-2612 `permit` expects. */
export const splitSignature = (sig: `0x${string}`) => {
  const hex = sig.slice(2);
  const r = ("0x" + hex.slice(0, 64)) as `0x${string}`;
  const s = ("0x" + hex.slice(64, 128)) as `0x${string}`;
  const v = Number("0x" + hex.slice(128, 130));
  return { v, r, s } as const;
};

export const roundDownToCent = (amount: bigint) => (amount / 10_000n) * 10_000n; // 0.01 USDC
