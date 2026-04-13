# Microcredit Protocol — Demo Walkthrough

Run the full demo with a single command:

```bash
bash demo.sh
```

---

## What the Demo Does

The demo starts a local Anvil blockchain, deploys the contracts (including pre-seeding the lending pool with 10,000 USDC and pre-establishing Bob's credit score), boots the Next.js frontend, and then runs a Playwright browser script that walks through a complete end-to-end lending scenario with two on-screen personas:

- **Bob (Attester)** — Community member with an established credit score who vouches for borrowers (Anvil account 2)
- **Charlie (Borrower)** — Loan applicant (Anvil account 3)

Alice is the platform admin. Her actions (funding the pool, assigning Bob KYC status, and attesting to Bob) happen at deploy time — not through the UI.

---

## The Chain of Trust

Credit scores are computed by on-chain PageRank over a directed attestation graph. At deploy time, Alice gives Bob KYC status and attests to him at 95% confidence, establishing his score before the demo begins. The demo then shows:

```
Alice (Admin, off-screen) → Bob (>90% score) → Charlie
```

Bob's existing reputation is what makes his attestation to Charlie meaningful.

PageRank is computed **automatically** by the contract each time an attestation is recorded — there is no separate admin step.

---

## Gasless Transactions

All user-facing transactions are **meta-transactions** (EIP-712 signed messages submitted by the relayer). Charlie never needs ETH — loan requests, disbursements, and repayments are all paid by the relayer pool.

---

## Step-by-Step

- **Step 1 — Bob attests to Charlie with 80% confidence**: Bob navigates to `/attest?borrower=<Charlie's address>`. The attest page shows Bob his own credit score (>90%, pre-established at deploy time) before he vouches. The borrower field is pre-filled via URL param. Bob submits at 80% confidence, gasless via relayer. PageRank is auto-computed on-chain, giving Charlie a meaningful score based on the trust flowing through Bob.

- **Step 2 — View Charlie's credit score**: Navigates to `/scores` as Charlie and displays the computed PageRank-based credit score, which determines the maximum loan amount.

- **Step 3 — Charlie requests a 50 USDC loan (28-day term)**: Navigates to `/borrower`, enters 50 USDC, selects a 28-day repayment period, and clicks *One-Click Borrow*. This sends a signed EIP-712 meta-transaction to the relayer, which both requests and disburses the loan atomically in one transaction — drawing from the pre-seeded pool. Charlie pays no gas.

- **Step 4 — View active loan details**: Navigates back to `/borrower` to show the active loan summary — principal, outstanding balance, and payment schedule.

- **Step 5 — Charlie repays in full**: Still on `/borrower`, clicks the full-repayment button (*Pay $XX.XX*). Charlie signs a USDC EIP-2612 permit; the relayer pulls the exact outstanding balance from Charlie's wallet and closes the loan. The *Loan Request* form reappears, confirming the loan is closed.

---

## After the Demo

Servers (Anvil + Next.js) are stopped automatically when the Playwright script finishes. The final chain state is saved to `chain-state-demo.json` and will be reloaded on the next run (use `bash demo.sh --fresh` to start clean).
