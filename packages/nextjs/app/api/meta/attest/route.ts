import { relay, relayerRoute, requireFields, txResponse } from "../relayer";

/** Gasless attestation: relays an AttestRequest signed by the attester. */
export const POST = relayerRoute(async body => {
  requireFields(body, "chainId", "contractAddress", "req", "signature");
  const { chainId, contractAddress, req, signature } = body;

  const result = await relay({
    chainId,
    contractAddress,
    functionName: "attestMeta",
    args: [
      {
        attester: req.attester,
        borrower: req.borrower,
        weight: BigInt(req.weight),
        nonce: BigInt(req.nonce),
        deadline: BigInt(req.deadline),
      },
      signature,
    ],
  });
  return txResponse(result);
});
