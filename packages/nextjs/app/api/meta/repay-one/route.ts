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
 * `amount: "0"` repays the cent-rounded outstanding balance, capped at the permit value.
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
