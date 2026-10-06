import { relay, relayerRoute, requireFields, txResponse } from "../relayer";

/** Gasless withdrawal: queues a RequestWithdrawal signed by the lender and fills what it can. */
export const POST = relayerRoute(async body => {
  requireFields(body, "chainId", "contractAddress", "req", "signature");
  const { chainId, contractAddress, req, signature } = body;

  const result = await relay({
    chainId,
    contractAddress,
    functionName: "requestWithdrawalMeta",
    intent: { signer: req.lender, poolNonce: String(req.nonce) },
    args: [
      {
        lender: req.lender,
        amount: BigInt(req.amount),
        to: req.to,
        nonce: BigInt(req.nonce),
        deadline: BigInt(req.deadline),
      },
      signature,
    ],
  });

  let queueId: string | null = null;
  let amountQueued: string | null = null;
  let amountFilledNow = 0n;
  for (const { eventName, args } of result.events) {
    if (eventName === "MetaWithdrawalRequested") {
      queueId = String(args.queueId);
      amountQueued = String(args.amount);
    } else if (eventName === "MetaWithdrawalFilled") {
      amountFilledNow += BigInt(args.amountFilled as bigint);
    }
  }
  return { ...txResponse(result), queueId, amountQueued, amountFilledNow: amountFilledNow.toString() };
});
