import { type PermitPayload, relay, relayerRoute, requireFields, toPermitArg, txResponse } from "../relayer";

/** Gasless deposit authorized by an EIP-2612 permit alone. */
export const POST = relayerRoute(async body => {
  requireFields(body, "chainId", "contractAddress", "lender", "permit");
  const { chainId, contractAddress, lender, permit } = body;

  const result = await relay({
    chainId,
    contractAddress,
    functionName: "depositPermitOnlyMeta",
    args: [lender, toPermitArg(permit as PermitPayload)],
  });
  return txResponse(result);
});
