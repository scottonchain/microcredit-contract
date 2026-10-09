import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  availableKeystores,
  LOCAL_KEYSTORE,
  parseSelection,
  validateKeystoreName,
  walletFromJson,
} from "../keystores.js";
import {
  deployScriptTarget,
  parseDeployArgs,
  validateKeystore,
} from "../deployConfig.js";
import {
  readAccount,
  readRpcEndpoints,
  resolveRpcEndpoint,
} from "../foundryClient.js";

test("keystore discovery handles an empty install and returns sorted files only", () => {
  const dir = mkdtempSync(join(tmpdir(), "microcredit-keystores-"));
  try {
    assert.deepEqual(availableKeystores(join(dir, "missing")), []);
    for (const name of ["beta", "alpha", LOCAL_KEYSTORE])
      writeFileSync(join(dir, name), "{}");
    mkdirSync(join(dir, "nested"));
    assert.deepEqual(availableKeystores(dir), ["alpha", "beta"]);
    assert.equal(validateKeystore("alpha", dir), true);
    assert.equal(validateKeystore("missing", dir), false);
    assert.equal(validateKeystore("nested", dir), false);
    assert.equal(validateKeystore(LOCAL_KEYSTORE, dir), true);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("keystore names cannot escape the directory or become shell/CLI syntax", () => {
  assert.equal(
    validateKeystoreName("testnet-root_1.json"),
    "testnet-root_1.json"
  );
  for (const name of [
    "",
    "..",
    "../root",
    "/root",
    "two words",
    "name;echo",
    "$(echo)",
    "--interactive",
    LOCAL_KEYSTORE,
  ]) {
    assert.throws(() => validateKeystoreName(name), undefined, name);
  }
  assert.equal(
    validateKeystoreName(LOCAL_KEYSTORE, { allowLocal: true }),
    LOCAL_KEYSTORE
  );
});

test("selection requires one complete integer in range", () => {
  assert.equal(parseSelection(" 2 ", 2), 2);
  assert.equal(parseSelection("0", 0, { allowCreate: true }), 0);
  for (const answer of [
    "",
    "1 trailing",
    "1.5",
    "1e0",
    "-1",
    "0",
    "3",
    "99999999999999999999",
  ]) {
    assert.throws(
      () => parseSelection(answer, 2),
      /Invalid keystore selection/
    );
  }
});

test("wallet JSON supports both Foundry versions without echoing malformed data", () => {
  const wallet = {
    address: "0x" + "a".repeat(40),
    private_key: "0x" + "b".repeat(64),
  };
  for (const response of [
    [wallet],
    { schema_version: 1, success: true, data: [wallet] },
  ]) {
    assert.deepEqual(walletFromJson(JSON.stringify(response)), wallet);
  }
  for (const text of [
    wallet.private_key,
    "[]",
    "null",
    '{"private_key":"sensitive"}',
    JSON.stringify([{ ...wallet, address: "bad" }]),
  ]) {
    assert.throws(
      () => walletFromJson(text),
      (error) => error.message === "cast returned an invalid wallet response."
    );
  }
});

test("deploy defaults and every maintained deployment script resolve without a hard-coded contract name", () => {
  assert.deepEqual(parseDeployArgs([]), {
    fileName: "Deploy.s.sol",
    network: "localhost",
    keystoreArg: null,
  });
  for (const fileName of [
    "Deploy.s.sol",
    "DeployTestnet.s.sol",
    "DeployProduction.s.sol",
    "DeployBootstrapCandidate.s.sol",
  ]) {
    const options = parseDeployArgs([
      "--file",
      fileName,
      "--network",
      "baseSepolia",
      "--keystore",
      "testnet",
    ]);
    assert.equal(options.fileName, fileName);
    assert.equal(options.network, "baseSepolia");
    assert.equal(options.keystoreArg, "testnet");
    assert.equal(deployScriptTarget(fileName), `script/${fileName}`);
  }
});

test("deploy rejects typos, incomplete flags and script path escapes before running Forge", () => {
  for (const args of [
    ["--netwrok", "baseSepolia"],
    ["toString", "baseSepolia"],
    ["__proto__", "baseSepolia"],
    ["--network"],
    ["--file", "--network", "baseSepolia"],
    ["--file", "../elsewhere.s.sol"],
    ["--file", "/tmp/x.s.sol"],
    ["--file", "x.sol"],
    ["--keystore", "../a"],
  ]) {
    assert.throws(() => parseDeployArgs(args), undefined, args.join(" "));
  }
});

test("Forge is the canonical RPC configuration parser and failed output stays private", () => {
  const endpoints = {
    localhost: "http://127.0.0.1:8545",
    testnet: "https://rpc.invalid/${RPC_TOKEN}",
  };
  assert.deepEqual(
    readRpcEndpoints((binary, args) => {
      assert.equal(binary, "forge");
      assert.deepEqual(args, ["config", "--json"]);
      return JSON.stringify({ rpc_endpoints: endpoints });
    }),
    endpoints
  );
  for (const output of [
    "provider-secret",
    "null",
    "{}",
    '{"rpc_endpoints":[]}',
  ]) {
    assert.throws(
      () => readRpcEndpoints(() => output),
      (error) =>
        error.message ===
        "Cannot read RPC endpoints with forge config --json. Check Foundry and foundry.toml."
    );
  }
  assert.throws(
    () =>
      readRpcEndpoints(() => {
        throw new Error("provider-secret");
      }),
    (error) => !error.message.includes("provider-secret")
  );
});

test("only configured HTTP endpoints are read and balances retain exact precision", () => {
  assert.equal(
    resolveRpcEndpoint("https://rpc.invalid/${RPC_TOKEN}", {}),
    undefined
  );
  assert.equal(
    resolveRpcEndpoint("https://rpc.invalid/${RPC_TOKEN}", {
      RPC_TOKEN: "configured",
    }),
    "https://rpc.invalid/configured"
  );
  assert.equal(resolveRpcEndpoint("localhost"), undefined);
  assert.equal(resolveRpcEndpoint("file:///tmp/config"), undefined);
  const calls = [];
  assert.deepEqual(
    readAccount(
      "0x" + "a".repeat(40),
      "https://rpc.invalid",
      (binary, args, options) => {
        assert.equal(binary, "cast");
        assert.equal(options.env.ETH_RPC_URL, "https://rpc.invalid");
        assert.equal(args.includes("https://rpc.invalid"), false);
        calls.push(args);
        return args[0] === "balance"
          ? "1000000000000000000.000000000000000001\n"
          : "9007199254740993\n";
      }
    ),
    {
      balance: "1000000000000000000.000000000000000001",
      nonce: "9007199254740993",
    }
  );
  assert.deepEqual(
    calls.map((args) => args[0]),
    ["balance", "nonce"]
  );
  assert.throws(
    () =>
      readAccount("0x" + "a".repeat(40), "https://rpc.invalid", () => {
        throw new Error("provider-secret");
      }),
    (error) =>
      error.message === "Cannot read this account from the RPC endpoint."
  );
});
