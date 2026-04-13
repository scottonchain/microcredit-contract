# Microcredit Protocol — Demo Walkthrough

Run the full demo with a single command:

```bash
bash demo.sh
```

---

## What the Demo Does

The demo starts a local Anvil blockchain, deploys the contracts, boots the Next.js frontend, and then runs a Playwright browser script that walks through a complete end-to-end lending scenario with four personas:

- **Alice** — Lender (Anvil account 1)
- **Bob** — Attester / voucher (Anvil account 2)
- **Charlie** — Borrower (Anvil account 3)
- **Admin** — Contract owner / oracle (Anvil account 9, the deployer)

---

## The Chain of Trust

Credit scores are computed by on-chain PageRank over a directed attestation graph. For an attestation to carry weight, the attester must themselves have reputation — otherwise the score propagates nothing. The demo establishes trust like this:

```
Admin (trusted anchor) → Bob → Charlie
```

The Admin is the trusted seed: as the contract deployer they hold the anchor position. Bob earns reputation by receiving the Admin's attestation, so when Bob vouches for Charlie, that trust carries real weight through the graph.

---

## Step-by-Step

- **Step 0 — Home page**: Opens the app home page so the viewer sees the protocol overview before any actions are taken.

- **Step 1 — Fund Alice with ETH + USDC**: Navigates to `/fund` as Alice, clicks *Fund 1 ETH* to give her gas money, then clicks *Mint 10,000 USDC* so she has stablecoin to deposit.

- **Step 2 — Alice deposits 1,000 USDC into the lending pool**: Navigates to `/lend`, fills in 1,000 USDC, and clicks *Deposit*. The deposit is gasless — Alice signs an EIP-712 message and the relayer submits it on-chain.

- **Step 3 — Admin vouches for Bob with 90% confidence**: Navigates to `/attest?borrower=<Bob's address>` as the Admin. The Admin sets confidence to 90% and submits. This is the trust anchor: without this step Bob's later attestation to Charlie would carry no weight.

- **Step 4 — Bob attests to Charlie with 80% confidence**: Navigates to `/attest?borrower=<Charlie's address>` as Bob. The borrower field is pre-filled via URL param. Bob sets confidence to 80% and submits, also gasless.

- **Step 5 — Admin computes on-chain PageRank credit scores**: Navigates to `/admin` as the contract owner and clicks *Compute PageRank*. The contract runs iterative PageRank over the attestation graph (Admin → Bob → Charlie), giving Charlie a meaningful credit score derived from the chain of trust.

- **Step 6 — View Charlie's credit score**: Navigates to `/scores` as Charlie and displays the computed PageRank-based credit score, which determines the maximum loan amount.

- **Step 7 — Fund Charlie with ETH**: Navigates to `/fund` as Charlie and clicks *Fund 1 ETH* so he has gas for any direct transactions.

- **Step 8 — Charlie requests a 50 USDC loan (28-day term)**: Navigates to `/borrower`, enters 50 USDC, selects a 28-day repayment period, and clicks *One-Click Borrow*. This sends a signed EIP-712 meta-transaction to the relayer, which both requests and disburses the loan atomically in one transaction.

- **Step 9 — View active loan details**: Navigates back to `/borrower` to show the active loan summary — principal, outstanding balance, and payment schedule.

- **Step 10 — Charlie repays in full**: Still on `/borrower`, clicks the full-repayment button (*Pay $XX.XX*). Charlie signs a USDC EIP-2612 permit; the relayer pulls the exact outstanding balance from Charlie's wallet and closes the loan. The *Loan Request* form reappears, confirming the loan is closed.

---

## After the Demo

Servers (Anvil + Next.js) are stopped automatically when the Playwright script finishes. The final chain state is saved to `chain-state-demo.json` and will be reloaded on the next run (use `bash demo.sh --fresh` to start clean).
