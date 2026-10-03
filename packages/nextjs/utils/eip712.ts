// EIP-712 / EIP-2612 typed-data definitions shared by the signing UI flows.
// Field order must match the typehashes in DecentralizedMicrocredit.sol and ERC20Permit.
import { type PublicClient, domainSeparator } from "viem";
import { USDC_ABI } from "./usdcAbi";

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
  version = "1",
) => ({
  name: tokenName,
  version,
  chainId,
  verifyingContract,
});

export type PermitDomain = ReturnType<typeof USDC_PERMIT_DOMAIN>;

/**
 * The EIP-2612 domain `token` verifies permits against. MockUSDC (OpenZeppelin) uses
 * ("USD Coin", "1"); Circle's USDC on Base Sepolia uses ("USDC", "2"). The name and version are
 * read from the token (`version()` on Circle's FiatToken, `eip712Domain()` on OpenZeppelin tokens)
 * and the result is checked against the token's DOMAIN_SEPARATOR, so a wrong domain fails here
 * rather than as a rejected permit on-chain.
 */
export async function readPermitDomain(
  client: Pick<PublicClient, "readContract">,
  token: `0x${string}`,
  chainId: number,
): Promise<PermitDomain> {
  const [name, separator] = await Promise.all([
    client.readContract({ address: token, abi: USDC_ABI, functionName: "name" }),
    client.readContract({ address: token, abi: USDC_ABI, functionName: "DOMAIN_SEPARATOR" }),
  ]);
  const versions: string[] = [];
  try {
    versions.push(await client.readContract({ address: token, abi: USDC_ABI, functionName: "version" }));
  } catch {}
  try {
    versions.push((await client.readContract({ address: token, abi: USDC_ABI, functionName: "eip712Domain" }))[2]);
  } catch {}
  versions.push("1", "2");
  for (const version of versions) {
    const domain = USDC_PERMIT_DOMAIN(chainId, token, name, version);
    if (domainSeparator({ domain }).toLowerCase() === separator.toLowerCase()) return domain;
  }
  throw new Error(`Could not match the permit domain of ${name} at ${token}; a permit signed now would be rejected.`);
}

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
  BackRequest: [
    { name: "backer", type: "address" },
    { name: "borrower", type: "address" },
    { name: "amount", type: "uint256" },
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

export type BackRequest = {
  backer: `0x${string}`;
  borrower: `0x${string}`;
  amount: bigint; // USDC (6 decimals) of the backer's own credit
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
