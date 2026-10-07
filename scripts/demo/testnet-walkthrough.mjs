#!/usr/bin/env node
/**
 * testnet-walkthrough.mjs
 *
 * Drives the released wallet-direct app on Base Sepolia through a real browser with a test wallet whose private key
 * stays on the machine that runs this script. The page gets an injected EIP-1193 provider whose every call is bridged
 * to this Node process, which signs with viem and sends to the RPC; nothing about the key reaches the page. Every
 * transaction hash and the before/after state go to a JSON file, so one run is a reproducible acceptance receipt.
 *
 * Needs: a little Base Sepolia ETH on the wallet (a few thousandths of an ETH); test USDC is minted in the app.
 * Run from the repository root (playwright comes from scripts/demo, viem from the workspace):
 *
 *   TESTNET_PRIVATE_KEY=0x... node scripts/demo/testnet-walkthrough.mjs [flags]
 *
 * Environment (optional): BACKER_PRIVATE_KEY (a second wallet that holds credit; it backs the borrower with BACK_AMOUNT
 * before the borrow step), APP_URL (default https://scottonchain.github.io/pool), RPC_URL (default
 * https://sepolia.base.org), OUT (default testnet-walkthrough-<time>.json), LEND_AMOUNT (20), BORROW_AMOUNT (5),
 * BACK_AMOUNT (10), SEND_SPACING_MS (5000: the public RPC lags on back-to-back sends).
 * Flags: --reject-disburse  the wallet rejects the first disburseLoan prompt; the page is reloaded while the loan is
 *                           requested and the recovery card's Disburse button is used (rejected second signature,
 *                           reload during recovery)
 *        --wrong-network    the wallet reports Ethereum Sepolia (11155111) and refuses to switch; the script asserts
 *                           the app sends nothing and shows its wrong-network state
 *        --headful          show the browser;  --skip-lend --skip-borrow --skip-withdraw --skip-back  skip steps
 *        --resume-pending   continue a borrow whose requestLoan was already mined (the loan is Requested)
 *        --repay-only / --withdraw-only  run only that part
 * Environment (browser): CHROMIUM_PATH, CHROMIUM_NO_SANDBOX=1.
 * Credit: the selectors and flags after the first live run are Hermes's (testbed a35802e, browser-run-f116695).
 * The JSON holds addresses, hashes and balances only; the key is never written.
 */
import fs from "node:fs";
import { createRequire } from "node:module";
import { chromium } from "playwright";

// viem is a dependency of the Next.js package, not of scripts/demo: load it from there (no extra install).
const requireFromNextjs = createRequire(new URL("../../packages/nextjs/package.json", import.meta.url));
const { createPublicClient, createWalletClient, formatUnits, http, parseAbi, parseEventLogs, toFunctionSelector } =
  requireFromNextjs("viem");
const { privateKeyToAccount } = requireFromNextjs("viem/accounts");
const { baseSepolia } = requireFromNextjs("viem/chains");

// ── Configuration ─────────────────────────────────────────────────────────────
const flags = new Set(process.argv.slice(2));
const APP_URL = (process.env.APP_URL || "https://scottonchain.github.io/pool").replace(/\/$/, "");
const RPC_URL = process.env.RPC_URL || "https://sepolia.base.org";
// The pool and its token: the public canonical-USDC pool by default (docs/TESTNET.md). Set POOL and USDC for another
// deployment, and USDC_IS_MOCK=1 when the token is a free-mint MockUSDC (the retired mock pool
// 0xa49B9352B2e8C2B79b58cb4C60dB43342e08Afa8 with 0x7C46870111257d8A3aaF846BC6D2F7DA7FBb76f1). With Circle's USDC the
// wallet must already hold enough: fund it from faucet.circle.com first.
const POOL = process.env.POOL || "0x73872B8fB7F1771C67911f03edc75aBdc9514973";
const USDC = process.env.USDC || "0x036CbD53842c5426634e7929541eC2318f3dCF7e";
const USDC_IS_MOCK = (process.env.USDC_IS_MOCK ?? "0") === "1";
const CHAIN_ID_HEX = "0x14a34"; // 84532
const WRONG_CHAIN_HEX = "0xaa36a7"; // 11155111, Ethereum Sepolia: the network the banner says this is not
const LEND_AMOUNT = process.env.LEND_AMOUNT || "20";
const BORROW_AMOUNT = process.env.BORROW_AMOUNT || "5";
const BACK_AMOUNT = process.env.BACK_AMOUNT || "10";
const SEND_SPACING_MS = Number(process.env.SEND_SPACING_MS || 5000);
const OUT = process.env.OUT || `testnet-walkthrough-${new Date().toISOString().replace(/[:.]/g, "-")}.json`;

const KEY = process.env.TESTNET_PRIVATE_KEY;
if (!KEY) {
  console.error("TESTNET_PRIVATE_KEY is required (a test wallet with a little Base Sepolia ETH)");
  process.exit(2);
}
const BACKER_KEY = process.env.BACKER_PRIVATE_KEY;

const ABI = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function lenderBalance(address) view returns (uint256)",
  "function getBorrowLimit(address) view returns (uint256 limit, uint256 available)",
  "function getBorrowerLoanIds(address) view returns (uint256[])",
  "function getLoanTerms(uint256) view returns (uint8 status, uint256 term, uint256 requestedAt, uint256 disbursedAt, uint256 dueAt)",
  "function getCurrentOutstandingAmount(uint256) view returns (uint256)",
  "event LoanRequested(address indexed borrower, uint256 indexed loanId, uint256 amount, uint256 interestRate)",
]);
const DISBURSE_SELECTOR = toFunctionSelector("function disburseLoan(uint256)");
const STATUS = ["None", "Requested", "Active", "Repaid", "Defaulted", "Cancelled"];

// ── Chain clients (this process holds the keys) ──────────────────────────────
const publicClient = createPublicClient({ chain: baseSepolia, transport: http(RPC_URL) });
const accounts = {
  borrower: privateKeyToAccount(KEY),
  backer: BACKER_KEY ? privateKeyToAccount(BACKER_KEY) : null,
};
const wallets = Object.fromEntries(
  Object.entries(accounts)
    .filter(([, a]) => a)
    .map(([k, a]) => [k, createWalletClient({ account: a, chain: baseSepolia, transport: http(RPC_URL) })]),
);

const bridge = {
  active: "borrower",
  wrongNetwork: false,
  rejectNextDisburse: false,
  sendCount: 0,
  lastSendAt: 0,
  calls: [],
  txs: [],
};

const sleep = ms => new Promise(r => setTimeout(r, ms));
const now = () => new Date().toISOString();

async function walletRequest(method, params) {
  const account = accounts[bridge.active];
  bridge.calls.push({ t: now(), who: bridge.active, method });
  switch (method) {
    case "eth_requestAccounts":
    case "eth_accounts":
      return [account.address];
    case "eth_chainId":
      return bridge.wrongNetwork ? WRONG_CHAIN_HEX : CHAIN_ID_HEX;
    case "net_version":
      return bridge.wrongNetwork ? "11155111" : "84532";
    case "wallet_switchEthereumChain":
    case "wallet_addEthereumChain":
      if (bridge.wrongNetwork) throw new Error("WALLET_ERROR:4001:User rejected the request.");
      return null;
    case "wallet_getPermissions":
    case "wallet_requestPermissions":
      return [{ parentCapability: "eth_accounts" }];
    case "personal_sign": {
      const [message] = params;
      return account.signMessage({ message: { raw: message } });
    }
    case "eth_signTypedData_v4": {
      const typed = JSON.parse(params[1]);
      return account.signTypedData({
        domain: typed.domain,
        types: typed.types,
        primaryType: typed.primaryType,
        message: typed.message,
      });
    }
    case "eth_sendTransaction": {
      const tx = params[0] || {};
      const selector = (tx.data || "0x").slice(0, 10);
      if (bridge.wrongNetwork) throw new Error("WALLET_ERROR:4901:The wallet is on another chain");
      if (bridge.rejectNextDisburse && selector === DISBURSE_SELECTOR) {
        bridge.rejectNextDisburse = false;
        bridge.calls.push({ t: now(), who: bridge.active, method: "eth_sendTransaction", rejected: "disburseLoan" });
        throw new Error("WALLET_ERROR:4001:User rejected the request.");
      }
      console.log(`    [${now()}] wallet got eth_sendTransaction ${selector} (page asked)`);
      const wait = bridge.lastSendAt + SEND_SPACING_MS - Date.now();
      if (wait > 0) await sleep(wait);
      let hash;
      try {
        hash = await wallets[bridge.active].sendTransaction({
          to: tx.to,
          data: tx.data,
          value: tx.value ? BigInt(tx.value) : 0n,
        });
      } catch (e) {
        console.log(`    SEND FAILED (${selector}): ${String((e && e.message) || e).split("\n").slice(0, 6).join(" | ").slice(0, 600)}`);
        bridge.calls.push({ t: now(), who: bridge.active, method: "eth_sendTransaction", sendError: String((e && e.shortMessage) || (e && e.message) || e).slice(0, 300) });
        throw e;
      }
      bridge.lastSendAt = Date.now();
      console.log(`    [${now()}] sent ${selector}`);
      bridge.sendCount += 1;
      bridge.txs.push({ t: now(), who: bridge.active, to: tx.to, selector, hash });
      console.log(`    tx ${selector} -> ${hash}`);
      return hash;
    }
    default:
      return publicClient.request({ method, params });
  }
}

// ── The provider the page sees: every call goes through the bridge ───────────
const PROVIDER_INIT_SCRIPT = `
(function () {
  const handlers = {};
  const provider = {
    isMetaMask: true,
    isConnected: () => true,
    _metamask: { isUnlocked: () => Promise.resolve(true) },
    request: async function ({ method, params = [] }) {
      try {
        return await window.__walletRequest(method, params);
      } catch (e) {
        const m = /WALLET_ERROR:(\\d+):(.*)$/.exec(String(e && e.message || e));
        const err = new Error(m ? m[2] : String(e && e.message || e));
        if (m) err.code = Number(m[1]);
        throw err;
      }
    },
    on(event, fn) { (handlers[event] = handlers[event] || []).push(fn); },
    removeListener(event, fn) { if (handlers[event]) handlers[event] = handlers[event].filter(h => h !== fn); },
  };
  window.ethereum = provider;
  const info = { uuid: 'testnet-walkthrough-0000-0000-000000000000', name: 'MetaMask', rdns: 'io.metamask',
    icon: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==' };
  const announce = () => window.dispatchEvent(new CustomEvent('eip6963:announceProvider', { detail: Object.freeze({ info, provider }) }));
  announce();
  window.addEventListener('eip6963:requestProvider', announce);
  window.dispatchEvent(new Event('ethereum#initialized'));
})();
`;

// ── Page helpers ──────────────────────────────────────────────────────────────
async function connectWallet(page) {
  const btn = page.getByRole("button", { name: "Connect Wallet" });
  if (!(await btn.isVisible({ timeout: 4000 }).catch(() => false))) return;
  await btn.click();
  await sleep(800);
  const mm = page.getByRole("button", { name: /MetaMask/ }).first();
  if (await mm.isVisible({ timeout: 3000 }).catch(() => false)) await mm.click();
  else await page.getByText(/browser wallet|injected/i).first().click({ timeout: 4000 });
  await page.waitForFunction(() => /0x[0-9a-fA-F]{4}/.test(document.body.innerText), { timeout: 20000 }).catch(() => {});
  await sleep(600);
}

async function goto(page, path) {
  await page.goto(APP_URL + path, { waitUntil: "domcontentloaded" });
  await sleep(1500);
  await connectWallet(page);
}

async function waitForText(page, pattern, timeoutMs) {
  return page
    .waitForFunction(p => new RegExp(p, "i").test(document.body.innerText), pattern, { timeout: timeoutMs })
    .then(() => true)
    .catch(() => false);
}

async function waitFor(predicate, timeoutMs, everyMs = 3000) {
  const until = Date.now() + timeoutMs;
  while (Date.now() < until) {
    if (await predicate()) return true;
    await sleep(everyMs);
  }
  return false;
}

// ── State reads (the evaluator's view, from the RPC, never from the page) ────
async function state(address) {
  const [eth, usdc, lender, limit, ids] = await Promise.all([
    publicClient.getBalance({ address }),
    publicClient.readContract({ address: USDC, abi: ABI, functionName: "balanceOf", args: [address] }),
    publicClient.readContract({ address: POOL, abi: ABI, functionName: "lenderBalance", args: [address] }),
    publicClient.readContract({ address: POOL, abi: ABI, functionName: "getBorrowLimit", args: [address] }),
    publicClient.readContract({ address: POOL, abi: ABI, functionName: "getBorrowerLoanIds", args: [address] }),
  ]);
  const loans = [];
  for (const id of ids) {
    const [terms, outstanding] = await Promise.all([
      publicClient.readContract({ address: POOL, abi: ABI, functionName: "getLoanTerms", args: [id] }),
      publicClient.readContract({ address: POOL, abi: ABI, functionName: "getCurrentOutstandingAmount", args: [id] }),
    ]);
    loans.push({ id: id.toString(), status: STATUS[Number(terms[0])] || String(terms[0]), outstanding: formatUnits(outstanding, 6) });
  }
  return {
    eth: formatUnits(eth, 18),
    usdc: formatUnits(usdc, 6),
    lenderBalance: formatUnits(lender, 6),
    limit: formatUnits(limit[0], 6),
    available: formatUnits(limit[1], 6),
    loans,
  };
}

const report = {
  app: APP_URL,
  rpc: RPC_URL,
  chainId: 84532,
  pool: POOL,
  usdc: USDC,
  buildCommit: null,
  flags: [...flags],
  borrower: accounts.borrower.address,
  backer: accounts.backer ? accounts.backer.address : null,
  startedAt: now(),
  steps: [],
};

// Console errors and warnings, kept for the failure dump: the page's own reason for a stopped step is shown in an alert
// box (role=alert) and written to the console, and Hermes's earlier runs could not see either. Any failed step dumps them.
let pageRef = null;
const consoleLog = [];
async function failureDump(label, chars = 2500) {
  if (!pageRef) return;
  try {
    console.log(`${label} PAGE TEXT AT FAILURE:`, (await pageRef.evaluate(() => document.body.innerText)).slice(0, chars));
    const alerts = await pageRef.evaluate(() => Array.from(document.querySelectorAll('[role="alert"]')).map(e => e.innerText.slice(0, 400)));
    console.log(`${label} ALERT BOXES:`, JSON.stringify(alerts));
  } catch (e) {
    console.log(`${label} (page not readable: ${String((e && e.message) || e).slice(0, 120)})`);
  }
  console.log(`${label} CONSOLE (last 10):`, JSON.stringify(consoleLog.slice(-10)));
  console.log(`${label} WALLET CALLS (last 12):`, JSON.stringify(bridge.calls.slice(-12)));
}

async function step(name, fn) {
  console.log(`\n== ${name}`);
  const before = await state(accounts.borrower.address);
  const txFrom = bridge.txs.length;
  const rec = { name, startedAt: now(), before, ok: false, note: "" };
  try {
    rec.note = (await fn()) || "";
    rec.ok = true;
  } catch (e) {
    rec.note = `failed: ${e && e.message ? e.message.slice(0, 300) : e}`;
    console.log(`   ${rec.note}`);
    await failureDump(name.toUpperCase());
  }
  rec.txs = bridge.txs.slice(txFrom);
  rec.after = await state(accounts.borrower.address);
  rec.finishedAt = now();
  report.steps.push(rec);
  console.log(`   ${rec.ok ? "ok" : "FAILED"}: ${rec.note}`);
  return rec;
}

// ── The walkthrough ───────────────────────────────────────────────────────────
async function main() {
  // CHROMIUM_PATH points at a browser binary when playwright's own download is not installed; CHROMIUM_NO_SANDBOX=1 for
  // containers that cannot run the sandbox.
  const browser = await chromium.launch({
    headless: !flags.has("--headful"),
    ...(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {}),
    ...(process.env.CHROMIUM_NO_SANDBOX === "1" ? { args: ["--no-sandbox"] } : {}),
  });
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  await ctx.exposeFunction("__walletRequest", walletRequest);
  await ctx.addInitScript(PROVIDER_INIT_SCRIPT);
  const page = await ctx.newPage();
  page.on("pageerror", e => console.log("   page error:", e.message.slice(0, 200)));
  pageRef = page;
  page.on("console", m => {
    if (m.type() === "error" || m.type() === "warning") consoleLog.push(`${now()} ${m.type()}: ${m.text().slice(0, 300)}`);
  });

  try {
    await step("open and connect", async () => {
      await goto(page, "/");
      const text = await page.evaluate(() => document.body.innerText);
      const m = /built from commit ([0-9a-f]{7,40})/.exec(text);
      report.buildCommit = m ? m[1] : null;
      if (!/Test network\./.test(text)) throw new Error("the test-network banner is not on the page");
      if (!text.includes(accounts.borrower.address.slice(0, 4))) throw new Error("the wallet did not connect");
      return `build commit ${report.buildCommit}; banner present; wallet connected`;
    });

    if (flags.has("--wrong-network")) {
      await step("wrong network: nothing is sent", async () => {
        bridge.wrongNetwork = true;
        const sends = bridge.sendCount;
        await page.reload({ waitUntil: "domcontentloaded" });
        await sleep(2500);
        await goto(page, "/lend/");
        const mint = page.getByRole("button", { name: /Get 100 test USDC/i });
        if (await mint.isVisible({ timeout: 5000 }).catch(() => false)) await mint.click();
        await sleep(4000);
        const text = await page.evaluate(() => document.body.innerText);
        bridge.wrongNetwork = false;
        if (bridge.sendCount !== sends) throw new Error("a transaction was sent while the wallet was on the wrong network");
        const shown = /wrong network|switch network/i.test(text);
        return `no transaction sent; wrong-network state shown: ${shown}`;
      });
      await page.reload({ waitUntil: "domcontentloaded" });
      await sleep(2000);
    }

    if (USDC_IS_MOCK) {
      await step("mint 100 test USDC", async () => {
        await goto(page, "/lend/");
        const before = (await state(accounts.borrower.address)).usdc;
        await page.getByRole("button", { name: /Get 100 test USDC/i }).click({ timeout: 15000 });
        const ok = await waitFor(async () => Number((await state(accounts.borrower.address)).usdc) >= Number(before) + 100, 120000);
        if (!ok) throw new Error("USDC balance did not rise by 100");
        return "balance rose by 100";
      });
    } else {
      await step("test USDC already held (no public mint on this token)", async () => {
        const s = await state(accounts.borrower.address);
        const need = Number(LEND_AMOUNT) + Number(BORROW_AMOUNT);
        if (Number(s.usdc) < need) {
          throw new Error(`the wallet holds ${s.usdc} USDC; it needs at least ${need} (lend plus repay): fund it from faucet.circle.com (Base Sepolia) first`);
        }
        return `wallet holds ${s.usdc} USDC`;
      });
    }

    if (!flags.has("--skip-lend") && !flags.has("--withdraw-only")) {
      await step(`lend ${LEND_AMOUNT} USDC (approve, depositFunds)`, async () => {
        await goto(page, "/lend/");
        const before = Number((await state(accounts.borrower.address)).lenderBalance);
        await page.getByPlaceholder("Enter amount in USDC").fill(LEND_AMOUNT);
        await page.getByRole("button", { name: /^Deposit$/ }).click({ timeout: 15000 });
        const confirmed = await waitForText(page, "Deposit confirmed", 90000);
        const ok = await waitFor(async () => Number((await state(accounts.borrower.address)).lenderBalance) >= before + Number(LEND_AMOUNT) - 0.01, 60000);
        if (!ok) throw new Error("lender balance did not rise");
        return `page said confirmed: ${confirmed}; lender balance rose`;
      });
    }

    if (accounts.backer && !flags.has("--skip-back") && !flags.has("--withdraw-only")) {
      await step(`backer backs the borrower with ${BACK_AMOUNT} USDC of credit`, async () => {
        bridge.active = "backer";
        await page.goto(APP_URL + `/attest/?borrower=${accounts.borrower.address}`, { waitUntil: "domcontentloaded" });
        await sleep(1500);
        await connectWallet(page);
        await page.locator('input[type="number"]').first().fill(BACK_AMOUNT);
        await page.getByRole("button", { name: /back with/i }).click({ timeout: 15000 });
        const recorded = await waitForText(page, "Backing Recorded", 240000);
        bridge.active = "borrower";
        const ok = await waitFor(async () => Number((await state(accounts.borrower.address)).available) >= Number(BACK_AMOUNT) - 0.01, 60000);
        if (!ok) throw new Error("the borrower's available credit did not rise");
        return `page said recorded: ${recorded}; borrower available credit rose`;
      });
      await page.reload({ waitUntil: "domcontentloaded" });
      await sleep(2000);
    }

    if (!flags.has("--skip-borrow")) {
      if (!flags.has("--repay-only")) await step(`borrow ${BORROW_AMOUNT} USDC (requestLoan, disburseLoan)${flags.has("--reject-disburse") ? " with the second prompt rejected once, then a reload" : ""}`, async () => {
        const s0 = await state(accounts.borrower.address);
        if (!flags.has("--resume-pending") && Number(s0.available) < Number(BORROW_AMOUNT)) {
          throw new Error(`available credit ${s0.available} is below ${BORROW_AMOUNT}: the wallet needs backing or an issued line first`);
        }
        await goto(page, "/borrower/");
        const borrowBtn = page.getByRole("button", { name: /Borrow \(two wallet transactions\)/i });
        try { if (!flags.has("--resume-pending")) await borrowBtn.waitFor({ state: "visible", timeout: 60000 }); }
        catch (e) { console.log("BORROWER PAGE TEXT:", (await page.evaluate(() => document.body.innerText)).slice(0, 1800)); console.log("BUTTONS", JSON.stringify(await page.evaluate(() => [...document.querySelectorAll("button")].map(x => x.innerText.trim()).filter(Boolean)))); throw e; }
        if (!flags.has("--resume-pending")) await page.locator('input[type="number"]').first().fill(BORROW_AMOUNT);
        bridge.rejectNextDisburse = flags.has("--reject-disburse");
        const idsBefore = new Set(s0.loans.filter(l => !(flags.has("--resume-pending") && l.status === "Requested")).map(l => l.id));
        const txBase = bridge.txs.length;
        let reqHash, loanId;
        if (flags.has("--resume-pending")) {
          const pend = s0.loans.find(l => l.status === "Requested");
          if (!pend) throw new Error("no pending requested loan to resume");
          loanId = BigInt(pend.id);
          reqHash = "(request made by the previous run of this script)";
        } else {
        await borrowBtn.click();
        const requestTx = await waitFor(async () => bridge.txs.slice(txBase).some(t => t.who === "borrower" && t.to.toLowerCase() === POOL.toLowerCase() && t.selector !== DISBURSE_SELECTOR), 120000);
        if (!requestTx) throw new Error("no requestLoan transaction was sent");
        reqHash = bridge.txs.slice(txBase).filter(t => t.who === "borrower" && t.to.toLowerCase() === POOL.toLowerCase() && t.selector !== DISBURSE_SELECTOR)[0].hash;
        const receipt = await publicClient.waitForTransactionReceipt({ hash: reqHash, timeout: 180000 });
        const events = parseEventLogs({ abi: ABI, eventName: "LoanRequested", logs: receipt.logs });
        const mine = events.filter(e => e.args.borrower.toLowerCase() === accounts.borrower.address.toLowerCase());
        if (mine.length !== 1) throw new Error(`expected one LoanRequested event of ours, found ${mine.length}`);
        loanId = mine[0].args.loanId;
        }
        let note0 = "";
        let note = `request ${reqHash} created loan #${loanId}`;
        if (flags.has("--reject-disburse") && flags.has("--resume-pending")) {
          await page.goto(APP_URL + "/borrower/", { waitUntil: "domcontentloaded" });
          await sleep(2500);
          await connectWallet(page);
          await waitForText(page, "Loan requested, not yet disbursed", 60000);
          const sendsBefore = bridge.txs.length;
          await page.getByRole("button", { name: /^Disburse$/ }).click({ timeout: 15000 });
          await sleep(5000);
          bridge.rejectNextDisburse = false;
          note0 = `Disburse clicked with the wallet rejecting it; new transactions sent: ${bridge.txs.length - sendsBefore}; `;
        }
        if (flags.has("--reject-disburse")) {
          const card = await waitForText(page, "Loan requested, not yet disbursed", 60000);
          note += `; ${note0}second prompt rejected; recovery card shown: ${card}`;
          await page.reload({ waitUntil: "domcontentloaded" });
          await sleep(2500);
          await connectWallet(page);
          const cardAgain = await waitForText(page, "Loan requested, not yet disbursed", 60000);
          const form = await page.getByRole("button", { name: /Borrow \(two wallet transactions\)/i }).isVisible().catch(() => false);
          note += `; after reload the card is shown: ${cardAgain}, the request form is hidden: ${!form}`;
          await page.getByRole("button", { name: /^Disburse$/ }).click({ timeout: 15000 });
        }
        const active = await waitFor(async () => (await state(accounts.borrower.address)).loans.some(l => l.id === loanId.toString() && l.status === "Active"), 240000);
        if (!active) throw new Error(`loan #${loanId} did not become Active`);
        const disb = bridge.txs.filter(t => t.selector === DISBURSE_SELECTOR).slice(-1)[0];
        const disbTx = disb ? await publicClient.getTransaction({ hash: disb.hash }) : null;
        const disbLoanId = disbTx ? BigInt("0x" + disbTx.input.slice(10)) : null;
        if (disbLoanId !== null && disbLoanId !== loanId) throw new Error(`the disbursement targeted loan #${disbLoanId}, not #${loanId}`);
        const newIds = (await state(accounts.borrower.address)).loans.filter(l => !idsBefore.has(l.id)).length;
        if (newIds !== 1) throw new Error(`${newIds} new loans appeared; expected exactly one`);
        return note + `; disbursed by ${disb ? disb.hash : "?"} for loan #${loanId}; exactly one new loan`;
      });

      await step("repay the loan in full (approve, repayLoan)", async () => {
        await goto(page, "/borrower/");
        const s0 = await state(accounts.borrower.address);
        const open = s0.loans.find(l => l.status === "Active");
        if (!open) throw new Error("no active loan to repay");
        const buttons = page.getByRole("button", { name: /^Pay\b/ });
        const n = await buttons.count();
        let clicked = false;
        for (let i = 0; i < n; i++) {
          const b = buttons.nth(i);
          const label = (await b.innerText()).trim();
          if (/^Pay\b/.test(label) && (await b.isEnabled())) {
            await b.click();
            clicked = true;
            break;
          }
        }
        if (!clicked && n > 0) {
          await buttons.first().click();
          clicked = true;
        }
        if (!clicked) { console.log("REPAY PAGE TEXT:", (await page.evaluate(() => document.body.innerText)).slice(0, 1800)); console.log("BUTTONS", JSON.stringify(await page.evaluate(() => [...document.querySelectorAll("button")].map(x => x.innerText.trim()).filter(Boolean)))); throw new Error("no repay button found"); }
        const repaid = await waitFor(async () => (await state(accounts.borrower.address)).loans.some(l => l.id === open.id && l.status === "Repaid"), 90000);
        if (!repaid) throw new Error(`loan #${open.id} did not become Repaid`);
        return `loan #${open.id} repaid`;
      });
    }

    if (!flags.has("--skip-lend") && !flags.has("--skip-withdraw")) {
      await step(`withdraw ${LEND_AMOUNT} USDC (withdrawFunds)`, async () => {
        await goto(page, "/lend/");
        const before = Number((await state(accounts.borrower.address)).usdc);
        await page.getByPlaceholder("Enter amount to withdraw").fill(LEND_AMOUNT);
        await page.getByRole("button", { name: /^Withdraw$/ }).click({ timeout: 15000 });
        const confirmed = await waitForText(page, "Withdrawal confirmed", 240000);
        const ok = await waitFor(async () => Number((await state(accounts.borrower.address)).usdc) >= before + Number(LEND_AMOUNT) - 0.01, 60000);
        if (!ok) throw new Error("USDC balance did not rise after the withdrawal");
        return `page said confirmed: ${confirmed}; balance rose`;
      });
    }
  } finally {
    report.finishedAt = now();
    report.transactions = bridge.txs;
    report.walletCalls = bridge.calls.length;
    fs.writeFileSync(OUT, JSON.stringify(report, null, 2) + "\n");
    await browser.close();
  }

  console.log(`\nwrote ${OUT}`);
  console.log("\n| step | ok | transactions | note |\n| --- | --- | --- | --- |");
  for (const s of report.steps) {
    console.log(`| ${s.name} | ${s.ok ? "yes" : "no"} | ${s.txs.map(t => t.hash).join("<br>") || "none"} | ${s.note.replace(/\|/g, "/")} |`);
  }
  process.exit(report.steps.every(s => s.ok) ? 0 : 1);
}

main().catch(e => {
  console.error(e);
  process.exit(1);
});
