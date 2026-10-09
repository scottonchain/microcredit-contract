import assert from "node:assert/strict";
import { test } from "node:test";
import { TYPES } from "./metaTypes.ts";
import { RelayerError, address, permitArg, relayerRpcUrl, requestBody, signature, typedRequest, uint } from "./relayerRequest.ts";
import { readRelayerResponse } from "./relayerResponse.ts";
import { IntentFlights } from "./relayerConcurrency.ts";

const account = "0x" + "11".repeat(20);
const hash = "0x" + "ab".repeat(32);
const invalid = (operation: () => unknown) => assert.throws(operation, error => error instanceof RelayerError && error.status === 400);

test("every meta request is parsed from the same fields the wallet signs", () => {
  for (const kind of ["BorrowAndDisburse", "BackRequest", "RequestWithdrawal"] as const) {
    const body = Object.fromEntries(TYPES[kind].map(f => [f.name, f.type === "address" ? account : "0"]));
    const parsed = typedRequest(kind, body);
    for (const field of TYPES[kind]) assert.equal(parsed[field.name as keyof typeof parsed], field.type === "address" ? account : 0n);
    for (const field of TYPES[kind]) {
      const missing = { ...body }; delete missing[field.name];
      invalid(() => typedRequest(kind, missing));
    }
  }
});

test("envelopes and unsigned integers reject malformed and lossy JSON values before relaying", () => {
  for (const body of [null, [], "text", {}, { chainId: false, contractAddress: account }]) invalid(() => requestBody(body));
  assert.equal(requestBody({ chainId: 84532, contractAddress: account }).chainId, 84532);
  for (const value of [undefined, null, true, {}, [], -1, 1.5, Number.MAX_SAFE_INTEGER + 1, "-1", "1e6", "0x10", (1n << 256n).toString()]) invalid(() => uint(value, "value"));
  assert.equal(uint("9007199254740993", "value"), 9007199254740993n);
  assert.equal(uint(0, "value"), 0n);
  invalid(() => address("0x1", "address"));
});

test("permit parsing validates every component and keeps contract-wallet signatures possible", () => {
  const permit = { value: "0", deadline: "1", v: 27, r: hash, s: hash };
  assert.equal(permitArg(permit).value, 0n);
  invalid(() => permitArg({ ...permit, v: 29 }));
  invalid(() => permitArg({ ...permit, r: "0x01" }));
  invalid(() => permitArg(null));
  assert.equal(signature("0x"), "0x");
  assert.equal(signature("0xaabb"), "0xaabb");
  invalid(() => signature("0xabc"));
});

test("a public-chain relayer cannot silently fall back to localhost", () => {
  assert.equal(relayerRpcUrl(31337, {}), "http://127.0.0.1:8545");
  assert.throws(() => relayerRpcUrl(84532, {}), /RPC_URL is required/);
  assert.throws(() => relayerRpcUrl(84532, { RPC_URL: "file:///tmp/rpc" }), /HTTP or HTTPS/);
  assert.equal(relayerRpcUrl(84532, { RPC_URL: "https://example.test/rpc" }), "https://example.test/rpc");
});

test("clients accept only a confirmed successful relayer receipt, never HTTP 202", async () => {
  const mined = { status: "mined", receiptStatus: "success", txHash: hash, hash };
  assert.equal((await readRelayerResponse(Response.json(mined))).txHash, hash);
  await assert.rejects(readRelayerResponse(Response.json({ error: "Submitted but not yet confirmed" }, { status: 202 })), /not yet confirmed/);
  await assert.rejects(readRelayerResponse(Response.json({ ...mined, receiptStatus: "reverted" })), /not confirmed/);
  await assert.rejects(readRelayerResponse(Response.json({ status: "mined" })), /not confirmed/);
  await assert.rejects(readRelayerResponse(new Response("gateway unavailable", { status: 502 })), /invalid response/);
});

test("concurrent retries share one signing operation while competing intents are refused", async () => {
  const flights = new IntentFlights<string>();
  let release!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; });
  let sends = 0;
  const send = async () => { sends++; await gate; return hash; };
  const conflict = () => new RelayerError("nonce in flight", 409);
  const a = flights.run("key", "digest", send, conflict);
  const b = flights.run("key", "digest", send, conflict);
  assert.equal(a, b);
  assert.equal(flights.has("key"), true);
  await assert.rejects(flights.run("key", "other", send, conflict), /nonce in flight/);
  await Promise.resolve();
  assert.equal(sends, 1);
  release();
  assert.deepEqual(await Promise.all([a, b]), [hash, hash]);
  assert.equal(flights.has("key"), false);
});

test("failed operations release their in-flight slot without masking the failure", async () => {
  const flights = new IntentFlights<string>();
  await assert.rejects(flights.run("key", "digest", async () => { throw new Error("offline"); }, () => new Error("conflict")), /offline/);
  assert.equal(flights.has("key"), false);
  assert.equal(await flights.run("key", "digest", async () => "retry", () => new Error("conflict")), "retry");
});
