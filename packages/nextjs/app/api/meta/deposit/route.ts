import { address } from "~~/utils/relayerRequest";
import { relay, relayerRoute, requireFields, toPermitArg, txResponse } from "../relayer";

/** Gasless deposit authorized by an EIP-2612 permit alone. */
export const POST = relayerRoute(async body => {
  requireFields(body, "chainId", "contractAddress", "lender", "permit");
  const { chainId, contractAddress, permit } = body;
  const lender = address(body.lender, "lender");

  const result = await relay({
    chainId,
    contractAddress,
    intent: { signer: lender },
    functionName: "depositPermitOnlyMeta",
    args: [lender, toPermitArg(permit)],
  });
  return txResponse(result);
});
