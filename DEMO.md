# Microcredit Protocol — Demo Walkthrough

Run the full demo with a single command:

```bash
bash demo.sh
```

---

## What the Demo Does

The demo starts a local Anvil blockchain, deploys the contracts (including pre-seeding the lending pool with 10,000 USDC), boots the Next.js frontend, and then runs a Playwright browser script that walks through a complete end-to-end lending scenario with three personas:

- **Alice (Admin)** — Platform admin and trusted anchor of the reputation graph (Anvil account 9, the deployer). The pool is pre-funded by Alice at deploy time so the demo stays focused on credit and reputation.
- **Bob (Attester)** — Community member who vouches for borrowers (Anvil account 2)
- **Charlie (Borrower)** — Loan applicant (Anvil account 3)

---

## The Chain of Trust

Credit scores are computed by on-chain PageRank over a directed attestation graph. For an attestation to carry weight, the attester must themselves have reputation. The demo establishes trust like this:

```
Alice (Admin, trusted anchor) → Bob → Charlie
```

Alice is the trusted seed. When she vouches for Bob, Bob earns reputation. When Bob vouches for Charlie, that trust carries real weight through the graph — giving Charlie a meaningful credit score and loan eligibility.

PageRank is computed **automatically** by the contract each time an attestation is recorded. There is no separate admin step.

---

## Gasless Transactions

All user-facing transactions are **meta-transactions** (EIP-712 signed messages submitted by the relayer). Charlie never needs ETH — loan requests, disbursements, and repayments are all paid by the relayer pool.

---

## Step-by-Step

- **Step 1 — Alice (Admin) vouches for Bob with 90% confidence**: Alice navigates to `/attest?borrower=<Bob's address>` and submits an attestation at 90% confidence. This anchors the reputation graph — without Alice's vouching, Bob's later attestation to Charlie would propagate no credit. PageRank is auto-computed on-chain immediately.

- **Step 2 — Bob attests to Charlie with 80% confidence**: Bob navigates to `/attest?borrower=<Charlie's address>`. The borrower field is pre-filled via URL param. Bob submits at 80% confidence, gasless via relayer. PageRank is auto-computed on-chain, assigning Charlie a credit score proportional to the trust flowing through Alice → Bob → Charlie.

- **Step 3 — View Charlie's credit score**: Navigates to `/scores` as Charlie and displays the computed PageRank-based credit score, which determines the maximum loan amount.

- **Step 4 — Charlie requests a 50 USDC loan (28-day term)**: Navigates to `/borrower`, enters 50 USDC, selects a 28-day repayment period, and clicks *One-Click Borrow*. This sends a signed EIP-712 meta-transaction to the relayer, which both requests and disburses the loan atomically in one transaction — drawing from Alice's pre-seeded pool. Charlie pays no gas.

- **Step 5 — View active loan details**: Navigates back to `/borrower` to show the active loan summary — principal, outstanding balance, and payment schedule.

- **Step 6 — Charlie repays in full**: Still on `/borrower`, clicks the full-repayment button (*Pay $XX.XX*). Charlie signs a USDC EIP-2612 permit; the relayer pulls the exact outstanding balance from Charlie's wallet and closes the loan. The *Loan Request* form reappears, confirming the loan is closed.

---

## After the Demo

Servers (Anvil + Next.js) are stopped automatically when the Playwright script finishes. The final chain state is saved to `chain-state-demo.json` and will be reloaded on the next run (use `bash demo.sh --fresh` to start clean).
