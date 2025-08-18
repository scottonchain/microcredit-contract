// Shared EIP-712 typed data builders for the Next.js frontend
// Keeps UI flows consistent with contract structs & API expectations

export const MICRO_DOMAIN = (chainId: number, verifyingContract: `0x${string}`) => ({
  name: "DecentralizedMicrocredit",
  version: "1",
  chainId,
  verifyingContract,
});

export const USDC_PERMIT_DOMAIN = (
  chainId: number,
  verifyingContract: `0x${string}`,
  tokenName = "USD Coin",
) => ({
  name: tokenName,
  version: "1",
  chainId,
  verifyingContract,
});

export const TYPES = {
  DepositRequest: [
    { name: "lender", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "receiver", type: "address" },
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

export type DepositRequest = {
  lender: `0x${string}`;
  amount: bigint;
  receiver: `0x${string}`;
  nonce: bigint;
  deadline: bigint;
};

export type RequestWithdrawal = {
  lender: `0x${string}`;
  amount: bigint;
  to: `0x${string}`;
  nonce: bigint;
  deadline: bigint;
};

export type AttestRequest = {
  attester: `0x${string}`;
  borrower: `0x${string}`;
  weight: bigint; // scaled by 1e6 (SCALE)
  nonce: bigint;
  deadline: bigint;
};

export type PermitMessage = {
  owner: `0x${string}`;
  spender: `0x${string}`;
  value: bigint;
  nonce: bigint;
  deadline: bigint;
};

export const splitSignature = (sig: `0x${string}`) => {
  const hex = sig.slice(2);
  const r = ("0x" + hex.slice(0, 64)) as `0x${string}`;
  const s = ("0x" + hex.slice(64, 128)) as `0x${string}`;
  const v = Number("0x" + hex.slice(128, 130));
  return { v, r, s } as const;
};

export const roundDownToCent = (amount: bigint) => (amount / 10_000n) * 10_000n; // 0.01 USDC
