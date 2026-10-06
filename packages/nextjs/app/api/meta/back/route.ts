import { relay, relayerRoute, requireFields, txResponse } from "../relayer";

/** Gasless backing: relays a BackRequest signed by the backer. */
export const POST = relayerRoute(async body => {
  requireFields(body, "chainId", "contractAddress", "req", "signature");
  const { chainId, contractAddress, req, signature } = body;

  const result = await relay({
    chainId,
    contractAddress,
    functionName: "backMeta",
    intent: { signer: req.backer, poolNonce: String(req.nonce) },
    args: [
      {
        backer: req.backer,
        borrower: req.borrower,
        amount: BigInt(req.amount),
        nonce: BigInt(req.nonce),
        deadline: BigInt(req.deadline),
      },
      signature,
    ],
  });
  return txResponse(result);
});
