import { BaseError, ContractFunctionRevertedError } from "viem";
import { MICROCREDIT_ABI } from "~~/utils/microcredit";

type MicrocreditErrorName = Extract<(typeof MICROCREDIT_ABI)[number], { type: "error" }>["name"];

/**
 * Plain-language text for every DecentralizedMicrocredit custom error. Typed against the ABI,
 * so adding an error to the contract without a message here fails `yarn next:check-types`.
 */
export const CONTRACT_ERROR_MESSAGES: Record<MicrocreditErrorName, string> = {
  // access & config
  NotOwner: "Only the protocol owner can do this.",
  NotOracle: "Only the oracle can do this.",
  NotOwnerOrOracle: "Only the protocol owner or the oracle can do this.",
  UnauthorizedRelayer: "This relayer is not on the allowed list.",
  ZeroAddress: "An address is missing.",
  ZeroAmount: "Enter an amount greater than zero.",
  AboveOneHundredPercent: "The value cannot be more than 100%.",
  FeeTooHigh: "The protocol fee is above its maximum.",
  ScoreTooHigh: "A score cannot be more than 100%.",
  AlreadyVerified: "This address is already KYC-verified.",
  NameTooLong: "Display names can be at most 32 characters.",
  ExceedsAccruedFees: "That is more than the protocol fees collected so far.",
  // meta-transactions & permits
  SignatureExpired: "The signed request expired. Please try again.",
  InvalidNonce: "The signed request is out of date. Please try again.",
  InvalidSignature: "The signature does not match your account.",
  PermitFailed: "The USDC approval signature was not accepted. Please sign again.",
  PermitValueTooLow: "The USDC approval does not cover the full amount.",
  // pool
  ZeroShares: "That deposit is too small.",
  InsufficientBalance: "That is more than your available balance.",
  InsufficientLiquidity:
    "The pool does not have enough free USDC right now. Withdrawal requests are queued and paid as loans are repaid.",
  // loans
  NoCreditScore:
    "You do not have a credit score yet. Ask someone trusted in the network to vouch for you on the Attest page.",
  BorrowLimitExceeded: "That is more than your credit score allows.",
  FirstLoanCapExceeded: "First loans are capped. Repay one loan in full to unlock your full limit.",
  BorrowerInDefault: "This account has a defaulted loan and cannot borrow.",
  UtilisationCapExceeded: "The pool has lent out as much as it allows right now. Try a smaller amount or try later.",
  InvalidTerm: "Choose a repayment period between 1 and 365 days.",
  AprChanged: "The interest rate changed after you signed. Please review and try again.",
  LoanNotRequested: "This loan is not waiting to be paid out.",
  LoanNotActive: "This loan is not active.",
  LoanClosed: "This loan is closed.",
  NotCancellableYet: "Only the borrower can cancel this loan for now.",
  NotYetDefaultable: "This loan is not overdue long enough to be marked defaulted.",
  NotBorrower: "Only the borrower can do this.",
  WrongBorrower: "This loan belongs to a different borrower.",
  MustSendToBorrower: "Loan funds can only go to the borrower.",
  NothingToRepay: "There is nothing left to repay.",
  OutstandingChanged: "Your balance changed after you signed. Please review and try again.",
  // attestations & stake
  WeightTooHigh: "Confidence cannot be more than 100%.",
  SelfAttestation: "You cannot vouch for yourself.",
  TooManyVouchers: "This borrower already has the maximum number of vouchers.",
  StakeRequired: "Stake more USDC to vouch for another person.",
  StakeLockedByVouches: "That stake backs your active vouches. Withdraw a vouch first.",
  InsufficientStake: "That is more than you have staked.",
  VouchLockedByActiveLoan: "You cannot lower or withdraw this vouch while the borrower has a loan out.",
  // inherited from OpenZeppelin
  SafeERC20FailedOperation: "The USDC transfer failed. Check your balance and approval.",
  InvalidShortString: "Unexpected contract error.",
  StringTooLong: "Unexpected contract error.",
};

/** The custom error a viem error carries, when the contract reverted with one. */
export function contractErrorName(error: unknown): string | undefined {
  if (!(error instanceof BaseError)) return undefined;
  const reverted = error.walk(e => e instanceof ContractFunctionRevertedError);
  return reverted instanceof ContractFunctionRevertedError ? reverted.data?.errorName : undefined;
}

/** Plain-language text for a contract revert, or undefined for anything else. */
export function describeContractError(error: unknown): string | undefined {
  const name = contractErrorName(error);
  return name ? CONTRACT_ERROR_MESSAGES[name as MicrocreditErrorName] : undefined;
}

/** The message from a failed relayer response (`{ error }` JSON, see app/api/meta/relayer.ts). */
export async function relayerErrorMessage(resp: Response): Promise<string> {
  const text = await resp.text();
  try {
    return JSON.parse(text).error ?? text;
  } catch {
    return text;
  }
}
