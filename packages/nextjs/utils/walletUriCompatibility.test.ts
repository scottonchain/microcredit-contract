import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import { test } from "node:test";

const require = createRequire(import.meta.url);
const queryString = require("query-string");

test("wallet URI queries preserve encoded keys, Unicode, spaces and repeated values", () => {
  assert.deepEqual(
    { ...queryString.parse("relay-protocol=irn&symKey=%2B%2F%3D&label=caf%C3%A9+%E2%82%AC&a=1&a=2&empty=&missing") },
    { "relay-protocol": "irn", symKey: "+/=", label: "café €", a: ["1", "2"], empty: "", missing: null },
  );
  const fields = { uri: "wc:topic@2?relay-protocol=irn&symKey=abc", label: "space + plus" };
  assert.deepEqual({ ...queryString.parse(queryString.stringify(fields)) }, fields);
});

test("wallet URI parsing retains recoverable malformed encodings without changing its CommonJS API", () => {
  const parsed = queryString.parseUrl("wc:topic@2?relay-protocol=irn&symKey=abc#ignored");
  assert.equal(parsed.url, "wc:topic@2");
  assert.deepEqual({ ...parsed.query }, { "relay-protocol": "irn", symKey: "abc" });
  assert.deepEqual(
    { ...queryString.parse("bom=%FE%FF&text=%41%C3%A9&partial=%E0%A4%A&literal=%G0&byte=%C2") },
    { bom: "��", text: "Aé", partial: "%E0%A4%A", literal: "%G0", byte: "�" },
  );
});

test("malformed percent-encoded wallet input completes in a bounded process", () => {
  // GHSA-vcc3-ghjq-m6fr: the old recursive decoder hangs or exhausts its stack on this
  // small input. A child process bounds time and memory if vulnerable decoding is reintroduced.
  const script = `
    const assert = require("node:assert/strict");
    const queryString = require(${JSON.stringify(require.resolve("query-string"))});
    const encoded = "%FF".repeat(8192);
    assert.equal(queryString.parse("input=" + encoded).input, encoded);
  `;
  const result = spawnSync(process.execPath, ["--max-old-space-size=64", "-e", script], {
    encoding: "utf8",
    timeout: 3000,
    maxBuffer: 16384,
  });
  assert.equal(result.error, undefined, result.error?.message);
  assert.equal(result.status, 0, result.stderr);
});
