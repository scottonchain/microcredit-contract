type Hash = `0x${string}`;
export type MinedRelayResponse = {
  txHash: Hash;
  hash: Hash;
  status: "mined";
  receiptStatus: "success";
  loanId?: string | null;
  amountUsed?: string;
  queueId?: string | null;
  amountQueued?: string | null;
  amountFilledNow?: string;
};

/** A 202 means unresolved, even though fetch labels it `ok`. Never report it as a completed payment. */
export async function readRelayerResponse(response: Response): Promise<MinedRelayResponse> {
  const text = await response.text();
  let body: Record<string, unknown>;
  try {
    body = JSON.parse(text);
  } catch {
    throw new Error(`The relayer returned an invalid response (HTTP ${response.status})`);
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) throw new Error("Invalid relayer response");
  if (response.status !== 200) {
    throw new Error(typeof body.error === "string" ? body.error : response.status === 202
      ? "This transaction is not yet confirmed. Check its status before signing another request."
      : `The relayer rejected the request (HTTP ${response.status})`);
  }
  if (body.status !== "mined" || body.receiptStatus !== "success" || typeof body.txHash !== "string" || !/^0x[0-9a-f]{64}$/i.test(body.txHash))
    throw new Error("The relayer has not confirmed a successful transaction");
  return body as MinedRelayResponse;
}
