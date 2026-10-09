import { address, permitArg, uint } from "~~/utils/relayerRequest";
import {
  RelayerError,
  findEvent,
  relay,
  relayerRoute,
  requireFields,
  txResponse,
} from "../relayer";

/**
 * Gasless repayment authorized by a single EIP-2612 permit (no separate EIP-712 request).
 * `amount: "0"` repays the outstanding balance, capped at the permit value (the UI permits the balance rounded up to the cent).
 */
export const POST = relayerRoute(async body => {
  if (body.signature || body.req) {
    throw new RelayerError("RepayRequest/meta signature is not allowed; use permit-only", 400);
  }
  requireFields(body, "chainId", "contractAddress", "borrower", "loanId", "amount", "permit");
  const { chainId, contractAddress } = body;
  const borrower = address(body.borrower, "borrower");
  const loanId = uint(body.loanId, "loanId");
  const amount = uint(body.amount, "amount");
  const permit = permitArg(body.permit);

  const result = await relay({
    chainId,
    contractAddress,
    intent: { signer: borrower },
    functionName: "repayWithPermit",
    args: [
      borrower,
      loanId,
      amount,
      permit.value,
      permit.deadline,
      permit.v,
      permit.r,
      permit.s,
    ],
  });

  const repaid = findEvent(result, "LoanRepaid");
  const amountUsed = repaid ? String(repaid.args.amount) : undefined;
  return { ...txResponse(result), amountUsed };
});
