import { findEvent, relay, relayerRoute, requireFields, txResponse } from "../relayer";

/** One-click borrow: relays a BorrowAndDisburse request signed by the borrower. */
export const POST = relayerRoute(async body => {
  requireFields(body, "chainId", "contractAddress", "req", "signature");
  const { chainId, contractAddress, req, signature } = body;

  const result = await relay({
    chainId,
    contractAddress,
    functionName: "borrowAndDisburseMeta",
    intent: { signer: req.borrower, poolNonce: String(req.nonce) },
    args: [
      {
        borrower: req.borrower,
        amount: BigInt(req.amount),
        to: req.to,
        repaymentPeriod: BigInt(req.repaymentPeriod),
        maxAprBps: BigInt(req.maxAprBps),
        nonce: BigInt(req.nonce),
        deadline: BigInt(req.deadline),
      },
      signature,
    ],
  });

  const created = findEvent(result, "MetaLoanCreated");
  const loanId = created ? String(created.args.loanId) : null;
  return { ...txResponse(result), loanId };
});
