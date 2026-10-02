# Microcredit Protocol: Demo Walkthrough

Run the full demo with a single command:

```bash
yarn demo
```

`yarn demo --manual` starts everything but skips the scripted browser, so you can click through yourself. `yarn demo --reuse` reloads the previous chain state instead of deploying fresh.

---

## What the Demo Does

`scripts/demo.sh` starts a local Anvil chain, deploys the contracts with `yarn deploy`, starts the Next.js app in demo wallet mode, and then runs a Playwright script (`scripts/demo/lending-demo.mjs`) that walks through a complete lending scenario with two on-screen personas:

- **Avery (Attester)**: community member with an established credit score who vouches for borrowers (Anvil account 2)
- **Brighton (Borrower)**: loan applicant (Anvil account 3)

**Alexis** (Anvil account 9) is the platform admin and deployer. Alexis's setup happens at deploy time, not through the UI:

- Seeds the lending pool with 10,000 USDC.
- Opens loans for two background borrowers, Diana and Eve, bringing pool utilisation to 89% (lender APY about 8.3%).
- Assigns score overrides of 95% to Alexis and 92% to Avery, so Avery's attestation carries real weight in PageRank.

---

## The Chain of Trust

Credit scores are computed by on-chain PageRank over a directed attestation graph. Avery's admin-assigned 92% score anchors trust in the graph, and the demo shows that trust flowing to Brighton:

```
Avery (92% score) --80%--> Brighton
```

PageRank is computed **automatically** by the contract each time an attestation is recorded; there is no separate admin step.

---

## Gasless Transactions

All user-facing transactions are **meta-transactions**: EIP-712 signed messages (or EIP-2612 USDC permits) submitted by the relayer routes under `packages/nextjs/app/api/meta/`. Brighton never needs ETH: the attestation, the loan and the repayment are all paid for by the relayer.

---

## Step-by-Step

- **Step 1: Brighton gets an attestation link.** Brighton opens `/attest?borrower=<Brighton's address>` and sees "This is your attestation link" with a copy button, ready to share with people who can vouch.

- **Step 2: Avery attests to Brighton with 80% confidence.** Avery opens the same link; Brighton's address is pre-filled. Avery sets the confidence slider to 80% and submits, gasless via the relayer. PageRank recomputes on-chain and Brighton gets a credit score (about 89%, so a maximum loan of about 89 USDC).

- **Step 3: Brighton requests a 50 USDC loan (28-day term).** On `/borrower`, Brighton picks a 28-day repayment period, enters 50 USDC and clicks *One-Click Borrow*. One signed EIP-712 message lets the relayer create and disburse the loan in a single transaction, drawing from the pre-seeded pool.

- **Step 4: Brighton repays in full.** Back on `/borrower`, Brighton clicks the full-repayment button (*Pay $50.00*), signs a USDC EIP-2612 permit, and the relayer pulls exactly the outstanding balance and closes the loan. The *Loan Request* form reappears, confirming the loan is closed.

---

## After the Demo

Servers (Anvil + Next.js) are stopped automatically when the Playwright script finishes. Logs are in `logs/`, and the chain state is saved to `chain-state-demo.json`. By default the next run deploys fresh; pass `--reuse` to reload the saved state instead.
