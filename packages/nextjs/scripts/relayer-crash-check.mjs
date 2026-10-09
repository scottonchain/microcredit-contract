#!/usr/bin/env node

/**
 * Repeatable check of the relayer journal through the real API route, on a throwaway local chain.
 *
 *   yarn workspace @se-2/nextjs relayer:crash-check
 *
 * It starts Anvil on 8545 and the Next dev server on 3055, deploys the local contracts with `yarn deploy`, then:
 *   A. a request relays once, with the transaction hash minted before the broadcast (hash-first);
 *      the same request again is answered from the journal, a different request under the same nonce is refused;
 *   B. a request is sent with mining off, the server process is killed with SIGKILL after the broadcast, the server is
 *      restarted, and the same request is sent again while the transaction is still unmined (202, the identical bytes are
 *      rebroadcast, no second transaction) and once more after a block is mined (200, one transaction in all).
 *
 * No key is read from or written to a file: Anvil prints its own keys at start-up (the relayer key is taken from that
 * output into the child's environment), and the backer's EIP-712 signature comes from Anvil's unlocked account. Needs
 * `anvil` and `yarn` on PATH, ports 8545 and 3055 free, and the dependencies installed. Takes about two minutes.
 * Exit code 0 means every check passed. The local chain only: it says nothing about a public RPC endpoint.
 */
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { createPublicClient, createWalletClient, defineChain, http, keccak256, parseAbi } from "viem";

const here = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const nextjsDir = path.resolve(here, "..");
const repoDir = path.resolve(nextjsDir, "../..");
const RPC = "http://127.0.0.1:8545";
const API = "http://127.0.0.1:3055/api/meta/back";
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "relayer-crash-check-"));
const JOURNAL = path.join(tmp, "journal.jsonl");

const results = [];
const check = (name, ok, detail = "") => {
  results.push(ok);
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? `  (${detail})` : ""}`);
};
const sleep = ms => new Promise(r => setTimeout(r, ms));

const children = new Set();
function start(cmd, args, opts) {
  const child = spawn(cmd, args, { detached: true, ...opts });
  children.add(child);
  child.on("exit", () => children.delete(child));
  return child;
}
const killGroup = child => {
  try {
    process.kill(-child.pid, "SIGKILL");
  } catch {}
};
async function waitFor(readyOf, what, ms = 60_000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    if (readyOf()) return;
    await sleep(200);
  }
  throw new Error(`timed out waiting for ${what}`);
}

async function portFree(port) {
  try {
    await fetch(`http://127.0.0.1:${port}/`, { signal: AbortSignal.timeout(1000) });
    return false;
  } catch (e) {
    return e?.cause?.code === "ECONNREFUSED" || e?.name === "TypeError";
  }
}

let anvil;
let server;
async function main() {
  for (const port of [8545, 3055]) {
    if (!(await portFree(port))) throw new Error(`port ${port} is in use; stop whatever holds it and run again`);
  }

  // Anvil, printing its own keys to a file (not a pipe: the synchronous deploy below would stop a pipe being drained).
  const anvilLog = path.join(tmp, "anvil.log");
  const anvilFd = fs.openSync(anvilLog, "w");
  anvil = start("anvil", ["--port", "8545"], { stdio: ["ignore", anvilFd, anvilFd] });
  await waitFor(() => /Listening on/.test(fs.readFileSync(anvilLog, "utf8")), "anvil");
  const anvilOut = fs.readFileSync(anvilLog, "utf8");
  const keysBlock = anvilOut.split("Private Keys")[1] ?? "";
  const keyOf = i => keysBlock.match(new RegExp(`\\(${i}\\) (0x[0-9a-fA-F]{64})`))?.[1];
  const relayerKey = keyOf(5);
  if (!relayerKey) throw new Error("could not read the relayer key from anvil's output");

  console.log("deploying the local contracts (yarn deploy) ...");
  const deployed = spawnSync("yarn", ["deploy"], { cwd: repoDir, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (deployed.status !== 0)
    throw new Error("yarn deploy failed:\n" + (deployed.stdout + deployed.stderr).slice(-1500));
  const drift = spawnSync("git", ["diff", "--quiet", "--", "packages/nextjs/contracts/deployedContracts.ts"], {
    cwd: repoDir,
  });
  if (drift.status !== 0)
    console.log("note: deployedContracts.ts changed on disk; run `git checkout` on it before committing");
  const deployedTs = fs.readFileSync(path.join(nextjsDir, "contracts/deployedContracts.ts"), "utf8");
  const pool = deployedTs
    .slice(deployedTs.indexOf("31337"))
    .match(/DecentralizedMicrocredit: \{\s*address: "(0x[0-9a-fA-F]{40})"/)?.[1];
  if (!pool) throw new Error("no local DecentralizedMicrocredit address in deployedContracts.ts");

  const chain = defineChain({
    id: 31337,
    name: "local",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [RPC] } },
  });
  const pub = createPublicClient({ chain, transport: http(RPC) });
  const rpc = async (method, params = []) =>
    (
      await (
        await fetch(RPC, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
        })
      ).json()
    ).result;
  const [, , backer, borrower] = await rpc("eth_accounts");
  const wallet = createWalletClient({ account: backer, chain, transport: http(RPC) });
  const relayerAddress = (await pub.request({ method: "eth_accounts" }))[5];
  const abi = parseAbi(["function nonces(address) view returns (uint256)"]);
  const poolNonce = () => pub.readContract({ address: pool, abi, functionName: "nonces", args: [backer] });
  const relayerTxs = async tag => BigInt(await rpc("eth_getTransactionCount", [relayerAddress, tag]));

  const TYPES = {
    BackRequest: [
      { name: "backer", type: "address" },
      { name: "borrower", type: "address" },
      { name: "amount", type: "uint256" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" },
    ],
  };
  const signed = async (nonce, amount) => {
    const req = {
      backer,
      borrower,
      amount,
      nonce: BigInt(nonce),
      deadline: BigInt(Math.floor(Date.now() / 1000) + 3600),
    };
    const signature = await wallet.signTypedData({
      domain: { name: "DecentralizedMicrocredit", version: "1", chainId: 31337, verifyingContract: pool },
      types: TYPES,
      primaryType: "BackRequest",
      message: req,
    });
    return {
      chainId: 31337,
      contractAddress: pool,
      req: { ...req, amount: String(amount), nonce: String(nonce), deadline: String(req.deadline) },
      signature,
    };
  };
  const post = async body => {
    const r = await fetch(API, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(60_000),
    });
    return { status: r.status, body: await r.json() };
  };
  const journal = () =>
    fs.existsSync(JOURNAL)
      ? fs
          .readFileSync(JOURNAL, "utf8")
          .split("\n")
          .filter(Boolean)
          .map(l => JSON.parse(l))
      : [];
  const statesFor = nonce =>
    journal()
      .filter(e => e.key.nonce === String(nonce))
      .map(e => e.state);

  async function startServer() {
    let out = "";
    server = start(process.execPath, [require.resolve("next/dist/bin/next"), "dev", "--hostname", "127.0.0.1", "-p", "3055"], {
      cwd: nextjsDir,
      env: {
        ...process.env,
        LOCAL_RPC_URL: RPC,
        RELAYER_PRIVATE_KEY: relayerKey,
        RELAYER_JOURNAL_PATH: JOURNAL,
        NEXT_TELEMETRY_DISABLED: "1",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    server.stdout.on("data", d => (out += d));
    server.stderr.on("data", d => (out += d));
    try {
      await waitFor(() => {
        if (server.exitCode !== null) throw new Error(`Next dev server exited ${server.exitCode}`);
        return /Ready in/.test(out);
      }, "the Next dev server", 120_000);
    } catch (error) {
      throw new Error(`${error.message}\n${out.slice(-2000)}`);
    }
  }
  await startServer();

  // ---- A: one request, replayed, and a conflicting one --------------------------------------------------------------
  console.log("\nA. a request, its replay and a conflicting request");
  const n0 = await poolNonce();
  const txs0 = await relayerTxs("latest");
  const first = await signed(n0, 1_000_000n);
  const r1 = await post(first);
  check("the request relays and is mined", r1.status === 200 && r1.body.status === "mined", `HTTP ${r1.status}`);
  if (r1.status !== 200 || r1.body.status !== "mined") {
    throw new Error(`The initial relay failed: ${String(r1.body.error ?? r1.body.status ?? "no error detail").slice(0, 300)}`);
  }
  const entry = journal().find(e => e.state === "submitted" && e.key.nonce === String(n0));
  check(
    "the journal holds the hash and the signed bytes, and the hash is keccak256 of those bytes",
    !!entry && keccak256(entry.raw) === r1.body.txHash,
  );
  check(
    "the journal went intent, submitted, mined (no duplicate line)",
    statesFor(n0).join(",") === "intent,submitted,mined",
    statesFor(n0).join(","),
  );
  const r2 = await post(first);
  check(
    "the same request again is answered from the journal",
    r2.status === 200 && r2.body.replayed === true,
    `HTTP ${r2.status}`,
  );
  check("and no second transaction was made", (await relayerTxs("latest")) - txs0 === 1n);
  const r3 = await post(await signed(n0, 2_000_000n));
  check("a different request under the same nonce is refused", r3.status === 409, `HTTP ${r3.status}`);
  check("the signer's pool nonce moved once", (await poolNonce()) === n0 + 1n);

  // ---- B: crash between the broadcast and the receipt -----------------------------------------------------------------
  console.log("\nB. the process is killed after the broadcast, before the receipt");
  const n1 = await poolNonce();
  const before = await relayerTxs("latest");
  const body = await signed(n1, 3_000_000n);
  await rpc("evm_setAutomine", [false]);
  post(body).catch(() => {}); // never answered: the server is killed while it waits for the receipt
  await waitFor(() => statesFor(n1).includes("submitted"), "the submitted entry").catch(() => {});
  check(
    "the hash and bytes were journaled while the transaction is pending",
    statesFor(n1).join(",") === "intent,submitted",
    statesFor(n1).join(","),
  );
  check(
    "one relayer transaction is pending and the signer's pool nonce is not consumed",
    (await relayerTxs("pending")) - before === 1n && (await poolNonce()) === n1,
  );
  killGroup(server);
  await sleep(1500);
  await startServer();
  const t0 = Date.now();
  const r4 = await post(body);
  check(
    "after the restart the same request is answered 202, not abandoned and not sent again",
    r4.status === 202,
    `HTTP ${r4.status} after ${Math.round((Date.now() - t0) / 1000)} s`,
  );
  check("the journal entry is still submitted", statesFor(n1).at(-1) === "submitted", statesFor(n1).join(","));
  const conflictingPending = await post(await signed(n1, 4_000_000n));
  check(
    "a different request under the pending nonce is refused without reporting the original request as success",
    conflictingPending.status === 409,
    `HTTP ${conflictingPending.status}`,
  );
  check(
    "still exactly one relayer transaction (the identical bytes, no second one)",
    (await relayerTxs("pending")) - before === 1n,
  );
  await rpc("evm_setAutomine", [true]);
  await rpc("evm_mine");
  const r5 = await post(body);
  check(
    "once the block is mined the same request is answered 200",
    r5.status === 200 && r5.body.status === "mined",
    `HTTP ${r5.status}`,
  );
  check(
    "one transaction in all, the signer's pool nonce moved once",
    (await relayerTxs("latest")) - before === 1n && (await poolNonce()) === n1 + 1n,
  );
  check("the journal ends mined", statesFor(n1).at(-1) === "mined", statesFor(n1).join(","));
}

let failed = true;
try {
  await main();
  failed = results.length === 0 || results.some(ok => !ok);
} catch (e) {
  console.error("\nerror:", e?.message ?? e);
} finally {
  for (const c of children) killGroup(c);
  fs.rmSync(tmp, { recursive: true, force: true });
}
console.log(`\n${results.filter(Boolean).length} of ${results.length} checks passed`);
process.exit(failed ? 1 : 0);
