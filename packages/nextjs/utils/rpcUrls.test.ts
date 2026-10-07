import assert from "node:assert/strict";
import { test } from "node:test";
import { parseRpcUrls } from "./rpcUrls.ts";

test("a comma-separated list keeps its order", () => {
  assert.deepEqual(parseRpcUrls("https://a.example,https://b.example, https://c.example"), [
    "https://a.example",
    "https://b.example",
    "https://c.example",
  ]);
});

test("a single URL, as before, is one entry", () => {
  assert.deepEqual(parseRpcUrls("https://sepolia.base.org"), ["https://sepolia.base.org"]);
});

test("blank entries, non-URLs and repeats are dropped; a trailing slash is the same endpoint", () => {
  assert.deepEqual(parseRpcUrls(" ,ftp://x.example,not a url,https://a.example,https://a.example/,HTTPS://A.EXAMPLE"), ["https://a.example"]);
});

test("unset or empty gives none", () => {
  assert.deepEqual(parseRpcUrls(undefined), []);
  assert.deepEqual(parseRpcUrls(""), []);
});
