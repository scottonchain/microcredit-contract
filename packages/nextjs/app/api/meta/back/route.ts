import { signature as parseSignature, typedRequest } from "~~/utils/relayerRequest";
import { relay, relayerRoute, requireFields, txResponse } from "../relayer";

/** Gasless backing: relays a BackRequest signed by the backer. */
export const POST = relayerRoute(async body => {
  requireFields(body, "chainId", "contractAddress", "req", "signature");
  const { chainId, contractAddress } = body;
  const req = typedRequest("BackRequest", body.req);
  const signature = parseSignature(body.signature);

  const result = await relay({
    chainId,
    contractAddress,
    functionName: "backMeta",
    intent: { signer: req.backer, poolNonce: String(req.nonce) },
    args: [req, signature],
  });
  return txResponse(result);
});
