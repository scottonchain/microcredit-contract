import { getAccount } from "wagmi/actions";
import { wagmiConfig } from "~~/services/web3/wagmiConfig";
import { CHAIN_ID, MICROCREDIT_ABI, MICROCREDIT_ADDRESS, USDC_ABI, USDC_ADDRESS } from "~~/utils/microcredit";
import { waitForStable } from "~~/utils/stableRead";

/**
 * Wallet-direct writes: scaffold's `writeContractAsync` and `useTransactor` resolve `undefined` (after showing a
 * notification) when the contract is not deployed on the selected chain, no wallet is connected, the wallet is on
 * another chain or the wallet client is unavailable. A caller that continues after `await` would then report success
 * for a transaction that was never sent. `requireHash` turns that into a thrown, typed failure, so every multi-step
 * flow stops at the step that did not happen and shows no success message.
 */
export class WalletWriteNotSent extends Error {
  constructor(what: string) {
    super(`${what} was not sent: connect a wallet on the right network and try again`);
    this.name = "WalletWriteNotSent";
  }
}

export class SignerChanged extends Error {
  constructor(detail: string) {
    super(`The connected wallet changed between steps (${detail}); nothing further was sent`);
    this.name = "SignerChanged";
  }
}

export function requireHash(hash: `0x${string}` | undefined | void, what: string): `0x${string}` {
  if (!hash) throw new WalletWriteNotSent(what);
  return hash;
}

export type Signer = { address: `0x${string}`; chainId: number };

/** The connected account and chain at this moment, or a thrown failure if none is connected on the app's chain. */
export function captureSigner(what: string): Signer {
  const account = getAccount(wagmiConfig);
  if (!account.address || account.chainId === undefined) throw new WalletWriteNotSent(what);
  if (account.chainId !== CHAIN_ID) throw new WalletWriteNotSent(what);
  return { address: account.address as `0x${string}`, chainId: account.chainId };
}

/** Before the second transaction of a flow: the same account on the same chain as at the first, or stop. */
export function assertSameSigner(expected: Signer): void {
  const account = getAccount(wagmiConfig);
  if (account.address?.toLowerCase() !== expected.address.toLowerCase()) {
    throw new SignerChanged(`account ${account.address ?? "none"} is not ${expected.address}`);
  }
  if (account.chainId !== expected.chainId) {
    throw new SignerChanged(`chain ${account.chainId ?? "none"} is not ${expected.chainId}`);
  }
}

/**
 * After an `approve` was mined and before the step that spends it: wait until the allowance is visible to reads on two
 * consecutive reads (see stableRead.ts). A public RPC can serve the next pre-send simulation from a node that has not
 * seen the approval yet, which would otherwise stop the flow after the first transaction.
 */
export async function waitForAllowance(
  publicClient: { readContract: (args: any) => Promise<unknown> },
  owner: `0x${string}`,
  spender: `0x${string}`,
  amount: bigint,
): Promise<void> {
  if (!USDC_ADDRESS) throw new Error("USDC address is not configured for this chain");
  await waitForStable(
    async () =>
      (await publicClient.readContract({
        address: USDC_ADDRESS,
        abi: USDC_ABI,
        functionName: "allowance",
        args: [owner, spender],
      })) as bigint,
    allowance => allowance >= amount,
    { what: "The approval" },
  );
}

/**
 * After `requestLoan` was mined and before `disburseLoan` is simulated: wait until the loan exists for reads, on two
 * consecutive reads. A public RPC can serve the pre-send simulation from a node that has not seen the request yet, which
 * reverts before the wallet is ever asked and leaves the request undisbursed. Any status other than "none" counts as
 * visible: a loan that is no longer requested then fails the simulation with its real reason, not with a timeout.
 */
export async function waitForLoanVisible(
  publicClient: { readContract: (args: any) => Promise<unknown> },
  loanId: bigint,
): Promise<void> {
  await waitForStable(
    async () =>
      (await publicClient.readContract({
        address: MICROCREDIT_ADDRESS,
        abi: MICROCREDIT_ABI,
        functionName: "getLoanTerms",
        args: [loanId],
      })) as readonly unknown[],
    terms => Number(terms[0]) !== 0,
    { what: "The loan request" },
  );
}
