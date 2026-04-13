/**
 * lending-demo.mjs
 *
 * Playwright script that walks through a complete microcredit lending scenario:
 *
 *   Step 1  — Brighton attests to Casey with 80% confidence (/attest)
 *             (Brighton's score is shown on the attest page; PageRank auto-computed)
 *   Step 2  — View Casey's credit score (/scores)
 *   Step 3  — Casey requests a 50 USDC loan, 28-day term (/borrower)
 *             (gasless meta-transaction — Casey needs no ETH)
 *   Step 4  — View active loan details (/borrower)
 *   Step 5  — Casey repays the loan in full (/borrower)
 *
 * How wallet injection works
 * ──────────────────────────
 * We inject a fake window.ethereum before every page load that:
 *   • Identifies as MetaMask (so RainbowKit's MetaMask connector picks it up)
 *   • Returns the "current demo account" from localStorage['__demoAccount']
 *   • Proxies ALL signing / transaction calls to Anvil's JSON-RPC, which
 *     automatically signs with its unlocked accounts — no pop-ups needed.
 *
 * To switch roles, we write the new address to localStorage then navigate.
 */

import { chromium } from 'playwright';

// ── Constants ─────────────────────────────────────────────────────────────────

const RPC_URL = 'http://127.0.0.1:8545';
const APP_URL = 'http://localhost:3000';

/**
 * Standard Anvil deterministic test accounts.
 * Account 0 is the deployer/admin (set in Deploy.s.sol via private key
 * 0x2a871d...  which corresponds to address 0xa0Ee7A…)
 *
 * We use accounts 1–4 for the demo roles so they have no prior state.
 */
const ACCOUNTS = {
  admin: {
    name: 'Avery (Admin)',
    // Anvil account 9 — the deployer (pk 0x2a871d…) that owns the contract
    // and seeded the pool with 10,000 USDC at deploy time.
    address: '0xa0Ee7A142d267C1f36714E4a8F75612F20a79720',
  },
  attester: {
    name: 'Brighton (Attester)',
    address: '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC', // Anvil account 2
  },
  borrower: {
    name: 'Casey (Borrower)',
    address: '0x90F79bf6EB2c4f870365E785982E1f101E93b906', // Anvil account 3
  },
};

// Milliseconds to pause between major steps so the viewer can read the UI
const STEP_PAUSE = 2500;

// ── Provider injection script ─────────────────────────────────────────────────
//
// This string is evaluated inside the browser before any page scripts run.
// It creates a minimal EIP-1193 ethereum provider that:
//   • reads the active demo address from localStorage (set by the test runner)
//   • auto-approves eth_requestAccounts (no MetaMask popup)
//   • proxies every other call (signTypedData, sendTransaction, …) to Anvil,
//     which signs with its unlocked accounts
//
const PROVIDER_INIT_SCRIPT = `
(function () {
  // Read the account we set in localStorage before navigating
  let addr;
  try { addr = localStorage.getItem('__demoAccount'); } catch (_) {}
  addr = addr || '${ACCOUNTS.admin.address}';

  const _handlers = {};

  window.ethereum = {
    isMetaMask: true,
    isConnected: () => true,
    chainId: '0x7a69',          // 31337
    networkVersion: '31337',
    selectedAddress: addr,

    // MetaMask exposes this object; some connectors check it
    _metamask: {
      isUnlocked: () => Promise.resolve(true),
    },

    request: async function ({ method, params = [] }) {
      // ── Handled locally ───────────────────────────────────────────────
      if (method === 'eth_requestAccounts' || method === 'eth_accounts') {
        return [addr];
      }
      if (method === 'eth_chainId')   return '0x7a69';
      if (method === 'net_version')   return '31337';

      // Chain-switching calls — always say we're already on the right chain
      if (method === 'wallet_switchEthereumChain') return null;
      if (method === 'wallet_addEthereumChain')    return null;

      // Permissions — tell the dapp it already has everything
      if (method === 'wallet_getPermissions') {
        return [{ parentCapability: 'eth_accounts' }];
      }
      if (method === 'wallet_requestPermissions') {
        return [{ parentCapability: 'eth_accounts' }];
      }

      // ── Proxy everything else to Anvil ────────────────────────────────
      // Anvil signs eth_sign / personal_sign / eth_signTypedData_v4 /
      // eth_sendTransaction with its unlocked accounts automatically.
      const body = JSON.stringify({
        jsonrpc: '2.0',
        id: Date.now(),
        method,
        params,
      });

      const resp = await fetch('${RPC_URL}', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body,
      });

      const data = await resp.json();

      if (data.error) {
        const err = new Error(data.error.message || 'JSON-RPC error');
        err.code = data.error.code;
        throw err;
      }

      return data.result;
    },

    // Event emitter (minimal — wagmi uses these)
    on (event, fn) {
      (_handlers[event] = _handlers[event] || []).push(fn);
    },
    removeListener (event, fn) {
      if (_handlers[event])
        _handlers[event] = _handlers[event].filter(h => h !== fn);
    },
    _emit (event, ...args) {
      (_handlers[event] || []).forEach(fn => fn(...args));
    },
  };

  // Announce the provider via EIP-6963 as well (wagmi v2 prefers this)
  const info = {
    uuid: 'demo-wallet-0000-0000-0000-000000000000',
    name: 'MetaMask',
    icon: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
    rdns: 'io.metamask',
  };
  window.dispatchEvent(
    new CustomEvent('eip6963:announceProvider', {
      detail: Object.freeze({ info, provider: window.ethereum }),
    })
  );
  window.addEventListener('eip6963:requestProvider', () => {
    window.dispatchEvent(
      new CustomEvent('eip6963:announceProvider', {
        detail: Object.freeze({ info, provider: window.ethereum }),
      })
    );
  });
  window.dispatchEvent(new Event('ethereum#initialized'));
})();
`;

// ── Helpers ───────────────────────────────────────────────────────────────────

function banner(step, title) {
  const line = '─'.repeat(58);
  console.log(`\n┌${line}┐`);
  const label = `  STEP ${step}: ${title}`;
  console.log(`│${label.padEnd(line.length)}│`);
  console.log(`└${line}┘`);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * Navigate to path as the given account.
 * Sets localStorage so the provider init script picks up the right address.
 */
async function gotoAs(page, path, account) {
  console.log(`  → navigating to ${path} as ${account.name}`);
  // localStorage is inaccessible on about:blank; ensure we're on a real page first.
  if (!page.url().startsWith(APP_URL)) {
    await page.goto(APP_URL, { waitUntil: 'domcontentloaded' });
  }
  await page.evaluate(
    (addr) => localStorage.setItem('__demoAccount', addr),
    account.address,
  );
  await page.goto(APP_URL + path, { waitUntil: 'domcontentloaded' });
  await sleep(1200);
}

/**
 * Connect the wallet by clicking "Connect Wallet" → "MetaMask" in the
 * RainbowKit modal.  Does nothing if already connected.
 */
async function connectWallet(page) {
  const btn = page.getByRole('button', { name: 'Connect Wallet' });
  const isVisible = await btn.isVisible({ timeout: 3000 }).catch(() => false);
  if (!isVisible) return; // already connected

  console.log('  → clicking Connect Wallet');
  await btn.click();
  await sleep(800);

  // RainbowKit modal — try MetaMask first, then any injected wallet fallback
  const mmBtn = page.getByText('MetaMask').first();
  if (await mmBtn.isVisible({ timeout: 3000 }).catch(() => false)) {
    await mmBtn.click();
  } else {
    // Some versions label it "Browser Wallet" or "Injected"
    const fallback = page.getByText(/browser wallet|injected/i).first();
    await fallback.click({ timeout: 4000 });
  }

  // Wait until an address is shown in the header (truncated 0x…)
  await page
    .waitForFunction(
      () => document.body.innerText.match(/0x[0-9a-fA-F]{4}/),
      { timeout: 15000 },
    )
    .catch(() => console.log('  (wallet may not have shown address yet)'));

  await sleep(600);
}

/**
 * Wait for a status string matching `pattern` to appear anywhere on the page.
 */
async function waitForStatus(page, pattern, timeoutMs = 30000) {
  await page
    .waitForFunction(
      (pat) => document.body.innerText.match(new RegExp(pat, 'i')),
      pattern,
      { timeout: timeoutMs },
    )
    .catch((e) => console.log(`  (timed out waiting for "${pattern}": ${e.message})`));
}

// ── Demo ──────────────────────────────────────────────────────────────────────

async function main() {
  console.log('\n  Launching Chromium…\n');

  const browser = await chromium.launch({
    headless: false,
    slowMo: 500,
    args: [
      '--window-size=1280,900',
      '--window-position=100,50',
      '--disable-web-security', // allow fetch to localhost:8545 from localhost:3000
    ],
  });

  const ctx = await browser.newContext({
    viewport: { width: 1280, height: 900 },
  });

  const page = await ctx.newPage();

  // Inject the provider on every page load (addInitScript persists for the context)
  await ctx.addInitScript(PROVIDER_INIT_SCRIPT);

  try {
    // Clear any stale __demoAccount from a previous run before the first step.
    // gotoAs boots the page to APP_URL when on about:blank, and we don't want
    // stale localStorage showing the wrong account's score during that flash.
    await page.goto(APP_URL, { waitUntil: 'domcontentloaded' });
    await page.evaluate(() => localStorage.removeItem('__demoAccount'));

    // ── STEP 1: Brighton attests to Casey ────────────────────────────────────
    // Brighton already has a >90% credit score from deploy time (Avery gave him KYC
    // and attested to him at 95%). The attest page shows Brighton his score.
    banner(1, `${ACCOUNTS.attester.name} attests to Casey with 80% confidence`);
    // Pass borrower address via query param so the /attest page pre-fills it
    await gotoAs(page, `/attest?borrower=${ACCOUNTS.borrower.address}`, ACCOUNTS.attester);
    await connectWallet(page);
    await sleep(600);

    console.log('  → borrower address (Casey) pre-filled via URL param');
    await sleep(400);

    console.log('  → setting confidence slider to 80');
    await page.locator('input[type="range"]').evaluate((el) => {
      el.value = '80';
      el.dispatchEvent(new Event('input',  { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await sleep(400);

    console.log('  → clicking Submit Attestation');
    await page.getByRole('button', { name: 'Submit Attestation' }).click();
    await waitForStatus(page, 'success|submitted|attested|0x[0-9a-f]{10}', 35000);
    await sleep(STEP_PAUSE);

    // ── STEP 2: View credit scores ────────────────────────────────────────
    // PageRank is computed automatically by the contract when each attestation
    // is recorded — no separate admin step required.
    banner(2, `View ${ACCOUNTS.borrower.name}'s credit score on /scores`);
    await gotoAs(page, '/scores', ACCOUNTS.borrower);
    await connectWallet(page);
    await sleep(800);

    // Search for Casey's address to show their score
    const searchInput = page.locator('input').first();
    if (await searchInput.isVisible({ timeout: 3000 }).catch(() => false)) {
      await searchInput.fill(ACCOUNTS.borrower.address);
      await page.getByRole('button', { name: /search/i }).click().catch(() => {});
    }
    await sleep(STEP_PAUSE);

    // ── STEP 3: Casey requests a 50 USDC loan ───────────────────────────
    // All transactions are gasless meta-transactions paid by the relayer —
    // Casey does not need ETH.
    banner(3, `${ACCOUNTS.borrower.name} requests a 50 USDC loan — 28-day term`);
    await gotoAs(page, '/borrower', ACCOUNTS.borrower);
    await connectWallet(page);

    // Wait for the loan form to appear — it only renders once getCreditScore
    // resolves and confirms Casey has a non-zero credit score.
    console.log('  → waiting for loan form to load…');
    const borrowBtn = page.getByRole('button', { name: /one.click borrow/i });
    await borrowBtn.waitFor({ state: 'visible', timeout: 30000 });

    // Fill the loan amount (number input)
    console.log('  → entering loan amount: 50');
    await page.locator('input[type="number"]').first().fill('50');
    await sleep(400);

    // Select 28-day repayment period (option value is the number of days)
    console.log('  → selecting 28-day repayment period');
    const periodSelect = page.locator('select').first();
    if (await periodSelect.isVisible({ timeout: 3000 }).catch(() => false)) {
      await periodSelect.selectOption('28');
    }
    await sleep(400);

    console.log('  → clicking One-Click Borrow');
    await borrowBtn.click();
    await waitForStatus(page, 'active|disbursed|success|✅|processing', 45000);
    await sleep(STEP_PAUSE);

    // ── STEP 4: Show active loan ──────────────────────────────────────────
    banner(4, 'Active loan — outstanding balance and payment schedule');
    await gotoAs(page, '/borrower', ACCOUNTS.borrower);
    await connectWallet(page);
    // Just pause here so the viewer can read the loan details
    await sleep(STEP_PAUSE * 1.5);

    // ── STEP 5: Casey repays in full ────────────────────────────────────
    banner(5, `${ACCOUNTS.borrower.name} repays the loan in full`);

    // The full-repayment button text is "Pay XX.XX USDC" (dynamic)
    const repayBtn = page.getByRole('button', { name: /^Pay / }).first();
    const repayVisible = await repayBtn.isVisible({ timeout: 5000 }).catch(() => false);

    if (repayVisible) {
      const btnText = await repayBtn.textContent();
      console.log(`  → clicking "${btnText?.trim()}"`);
      await repayBtn.click();
      // After repayment, the active loan section disappears and the
      // "Loan Request" form reappears. Wait for that or any success signal.
      await waitForStatus(page, 'Loan Request|repaid|no active|success|✅', 60000);
      await sleep(STEP_PAUSE);
    } else {
      console.log('  (repay button not visible — loan may still be processing from step 6)');
    }

    // ── DONE ──────────────────────────────────────────────────────────────
    banner('✓', 'Demo complete — all steps finished!');
    await sleep(STEP_PAUSE);

  } catch (err) {
    console.error('\n❌  Demo error:', err.message);
    console.error(err.stack);
  }

  await browser.close();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
