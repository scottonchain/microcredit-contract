import {
  type PermitPayload,
  RelayerError,
  findEvent,
  relay,
  relayerRoute,
  requireFields,
  txResponse,
} from "../relayer";

/**
 * Gasless repayment authorized by a single EIP-2612 permit (no separate EIP-712 request).
 * `amount: "0"` repays the outstanding balance, capped at the permit value. A loan closes only when its whole balance is
 * paid and interest keeps accruing until the transaction is mined, so a permit for exactly the quoted balance can leave
 * a sliver owed and the loan open. Callers permit the cent-rounded quote plus headroom (`payoffAmount` in
 * `utils/repayAmount.ts`, sized from the loan's original principal because interest accrues on it even after partial
 * repayments); the pool pulls only what is owed, so the headroom is never taken.
 *
 * `amountUsed` is the amount the pool actually pulled, read from `LoanRepaid`. That event also fires for a partial
 * repayment, and a mined success is not proof of closure: read `getLoan` and `getCurrentOutstandingAmount` afterwards
 * (`payoffOutcome` in `utils/repayAmount.ts`; the borrower page does) and treat a failed or stale read as unknown.
 */
export const POST = relayerRoute(async body => {
  if (body.signature || body.req) {
    throw new RelayerError("RepayRequest/meta signature is not allowed; use permit-only", 400);
  }
  requireFields(body, "chainId", "contractAddress", "borrower", "loanId", "amount", "permit");
  const { chainId, contractAddress, borrower, loanId, amount } = body;
  const permit = body.permit as PermitPayload;

  const result = await relay({
    chainId,
    contractAddress,
    intent: { signer: borrower },
    functionName: "repayWithPermit",
    args: [
      borrower,
      BigInt(loanId),
      BigInt(amount),
      BigInt(permit.value),
      BigInt(permit.deadline),
      Number(permit.v),
      permit.r,
      permit.s,
    ],
  });

  const repaid = findEvent(result, "LoanRepaid");
  const amountUsed = repaid ? String(repaid.args.amount) : undefined;
  return { ...txResponse(result), amountUsed };
});
