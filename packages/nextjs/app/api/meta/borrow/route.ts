import { signature as parseSignature, typedRequest } from "~~/utils/relayerRequest";
import { findEvent, relay, relayerRoute, requireFields, txResponse } from "../relayer";

/** One-click borrow: relays a BorrowAndDisburse request signed by the borrower. */
export const POST = relayerRoute(async body => {
  requireFields(body, "chainId", "contractAddress", "req", "signature");
  const { chainId, contractAddress } = body;
  const req = typedRequest("BorrowAndDisburse", body.req);
  const signature = parseSignature(body.signature);

  const result = await relay({
    chainId,
    contractAddress,
    functionName: "borrowAndDisburseMeta",
    intent: { signer: req.borrower, poolNonce: String(req.nonce) },
    args: [req, signature],
  });

  const created = findEvent(result, "MetaLoanCreated");
  const loanId = created ? String(created.args.loanId) : null;
  return { ...txResponse(result), loanId };
});
