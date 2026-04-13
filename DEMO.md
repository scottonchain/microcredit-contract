# Microcredit Protocol — Demo Walkthrough

Run the full demo with a single command:

```bash
bash demo.sh
```

---

## What the Demo Does

The demo starts a local Anvil blockchain, deploys the contracts, boots the Next.js frontend, and then runs a Playwright browser script that walks through a complete end-to-end lending scenario with three personas:

- **Alice** — Lender (Anvil account 1)
- **Bob** — Attester / voucher (Anvil account 2)
- **Charlie** — Borrower (Anvil account 3)
- **Admin** — Contract owner / oracle (Anvil account 9, the deployer)

---

## Step-by-Step

- **Step 0 — Home page**: Opens the app home page so the viewer sees the protocol overview before any actions are taken.

- **Step 1 — Fund Alice with ETH + USDC**: Navigates to `/fund` as Alice, clicks *Fund 1 ETH* to give her gas money, then clicks *Mint 10,000 USDC* so she has stablecoin to deposit.

- **Step 2 — Alice deposits 1,000 USDC into the lending pool**: Navigates to `/lend`, fills in 1,000 USDC, and clicks *Deposit*. The deposit is gasless — Alice signs an EIP-712 message and the relayer submits it on-chain.

- **Step 3 — Bob attests to Charlie with 80% confidence**: Navigates to `/attest?borrower=<Charlie's address>` (the borrower field is pre-filled via URL). Bob sets the confidence slider to 80% and clicks *Submit Attestation*, also gasless via relayer.

- **Step 4 — Admin computes on-chain PageRank credit scores**: Navigates to `/admin` as the contract owner (Admin) and clicks *Compute PageRank*. The contract runs an on-chain iterative PageRank over the attestation graph to assign Charlie a credit score.

- **Step 5 — View Charlie's credit score**: Navigates to `/scores` as Charlie and displays the computed PageRank-based credit score, which determines the maximum loan amount.

- **Step 6 — Fund Charlie with ETH**: Navigates to `/fund` as Charlie and clicks *Fund 1 ETH* so he has gas for any direct transactions.

- **Step 7 — Charlie requests a 50 USDC loan (28-day term)**: Navigates to `/borrower`, enters 50 USDC, selects a 28-day repayment period, and clicks *One-Click Borrow*. This sends a signed EIP-712 meta-transaction to the relayer, which both requests and disburses the loan atomically in one transaction.

- **Step 8 — View active loan details**: Navigates back to `/borrower` to show the active loan summary — principal, outstanding balance, and payment schedule.

- **Step 9 — Charlie repays in full**: Still on `/borrower`, clicks the full-repayment button (*Pay $XX.XX*). Charlie signs a USDC EIP-2612 permit; the relayer pulls the exact outstanding balance from Charlie's wallet and closes the loan. The *Loan Request* form reappears, confirming the loan is closed.

---

## After the Demo

Servers (Anvil + Next.js) are stopped automatically when the Playwright script finishes. The final chain state is saved to `chain-state-demo.json` and will be reloaded on the next run (use `bash demo.sh --fresh` to start clean).
