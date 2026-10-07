import assert from "node:assert/strict";
import { test } from "node:test";
import { networkHint, stopMessage } from "./stopMessage.ts";

test("a rate limit from the RPC endpoint is named, with what to do", () => {
  const m = stopMessage("The repayment stopped", "HTTP request failed.", "HTTP request failed. Status: 429 URL: https://rpc.example");
  assert.match(m, /^The repayment stopped: HTTP request failed\./);
  assert.match(m, /limiting requests/);
  assert.match(m, /nothing was sent/);
});

test("a timeout says to check the wallet before pressing again, because it may have been sent", () => {
  const m = stopMessage("Borrowing stopped", "The request timed out.");
  assert.match(m, /wallet's activity/);
  assert.match(m, /may or may not have been sent/);
});

test("an ordinary error gets no hint and is shown as it is", () => {
  assert.equal(stopMessage("The disbursement stopped", "Insufficient allowance"), "The disbursement stopped: Insufficient allowance");
  assert.equal(networkHint("User rejected the request."), undefined);
});

test("a long error is cut so a request body never lands on the page", () => {
  const long = "x".repeat(2000);
  const m = stopMessage("The deposit stopped", long);
  assert.ok(m.length < 400);
  assert.match(m, /\.\.\.$/);
});

test("the not-yet-visible message from the stable read passes through untouched", () => {
  const msg =
    "The approval is mined but not yet visible to the network after 30 s; nothing further was sent. Wait a moment and press the button again: the earlier step is already in place.";
  assert.equal(stopMessage("The repayment stopped", msg), `The repayment stopped: ${msg}`);
});

test("viem's endpoint URL and request body are dropped, the status stays", () => {
  const parsed = 'HTTP request failed. Status: 429 URL: https://rpc.example/key-123 Request body: {"method":"eth_sendRawTransaction","params":["0x02f8b1"]} Details: too many requests Version: viem@2';
  const m = stopMessage("The repayment stopped", parsed);
  assert.match(m, /^The repayment stopped: HTTP request failed\. Status: 429 /);
  assert.ok(!/key-123|eth_sendRawTransaction|viem@2/.test(m));
  assert.match(m, /limiting requests/);
});
