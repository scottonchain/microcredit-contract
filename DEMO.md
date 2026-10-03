# Microcredit Protocol: Demo Walkthrough

Run the full demo with a single command:

```bash
yarn demo
```

`yarn demo --manual` starts everything but skips the scripted browser, so you can click through yourself. `yarn demo --reuse` reloads the previous chain state instead of deploying fresh.

---

## What the Demo Does

`scripts/demo.sh` starts a local Anvil chain, deploys the contracts with `yarn deploy`, starts the Next.js app in demo wallet mode, and then runs a Playwright script (`scripts/demo/lending-demo.mjs`) that walks through one lending scenario with three personas:

- **Alexis (admin)**, Anvil account 9: deployer, contract owner, oracle and score reporter. Everything Alexis does happens at deploy time, not in the UI.
- **Avery (backer)**, Anvil account 2: holds 92 USDC of granted credit, which she can back others with.
- **Brighton (borrower)**, Anvil account 3: holds a 25 USDC line of his own. It stands in for credit he earned from past activity or a line an institution gave him.

---

## What the Deploy Seeds

`packages/foundry/script/Deploy.s.sol` broadcasts with Anvil's published keys (local only) and:

- Deploys MockUSDC, unless `deployment-config.json` points at a USDC that still has code on the chain.
- Deploys `DecentralizedMicrocredit` with an EFFR of 4.33% and a risk premium of 5.00% (a fixed 9.33% APR) and a maximum loan of 100 USDC.
- Deploys `OracleScoreProvider` with Alexis as owner and reporter, scores that go stale after 7 days, and an issuance budget of 50 full lines (5,000 USDC at the 100 USDC maximum loan). It is set as the lending contract's score provider.
- Seeds the lending pool with 10,000 USDC from Alexis.
- Gives two background borrowers, Diana and Eve, full scores and opens loans of 6,500 and 2,399 USDC for them (the maximum loan is raised for this, then set back to 100). That puts 89% of the pool on loan, so the lender APY is about 8.3%.
- Grants credit with score overrides: Alexis 95 USDC, Avery 92 USDC, Brighton 25 USDC.
- Sets the display names "Avery" and "Brighton", and sends 10 ETH to three extra wallets for demos with a real browser wallet.

The protocol fee starts at 0 and the first-loss reserve share at 30% of interest, which covers expected loss at a 3% annual default rate, the most the 500 bps premium prices (`analysis/credit_risk`). The admin page (`/admin`) shows both the reserve and the oracle's issuance budget.

---

## Gasless Transactions

All user actions in the demo are meta-transactions: EIP-712 signed messages (or EIP-2612 USDC permits) that the relayer routes under `packages/nextjs/app/api/meta/` submit on-chain. Avery and Brighton never need ETH: the relayer pays for the backing, the loan and the repayment.

---

## Step by Step

- **Step 1: Brighton gets his backing link.** As Brighton, the script opens `/attest?borrower=<Brighton's address>`. Because the address is his own, the page shows "This is your backing link", and the script clicks *Copy Backing Link*. This is the link he would share with people who have credit.

- **Step 2: Avery backs Brighton with 50 USDC of her credit.** As Avery, the script opens the same link. The page shows "You are invited to back" Brighton, with his address filled in. It enters 50 and clicks *Back with $50.00*; Avery signs one message and the relayer calls `backMeta`. The 50 USDC comes out of Avery's free credit, so she needs no stake. Her limit falls from 92 to 42 USDC and Brighton's rises from 25 to 75 USDC. The page confirms with "Backing Recorded".

- **Step 3: Brighton borrows 40 USDC for 28 days.** As Brighton, the script opens `/borrower`, where his credit limit is 75 USDC. It picks the 28-day repayment period, enters 40 and clicks *One-Click Borrow*. One signed message lets the relayer call `borrowAndDisburseMeta`, which creates and pays out the loan from the pool in a single transaction.

- **Step 4: Brighton repays in full.** The script reloads `/borrower` and clicks the full-repayment button (*Pay $40.00*). Brighton signs a USDC permit, and the relayer calls `repayWithPermit`, which pulls exactly the outstanding balance and closes the loan. The *Loan Request* form reappears. No interest accrues in the first 24 hours, so he pays none, and his own credit stays at 25 USDC: on-chain history only adds the share of interest a borrower has paid into the first-loss reserve.

---

## Why Credit Cannot Be Manufactured

An account can borrow only against credit it holds, or credit that someone who holds credit backs it with from their own. Credit comes from three places: a line issued by the owner or the oracle (score times the maximum loan, with the oracle's total capped by its issuance budget), the share of its interest it has paid into the first-loss reserve, and USDC it has staked. Backing moves credit, it does not copy it: Avery's limit falls by exactly what Brighton's rises, and backing received cannot be passed on. A ring of fresh accounts has nothing issued, nothing paid and nothing staked, so it can borrow nothing however its members back each other. If a backed borrower defaults, the backers pay first (stake is slashed back to lenders, committed credit is burned), and the first-loss reserve pays what stake does not recover before lenders take a loss. The proofs are in [docs/CREDIT_MODEL.md](docs/CREDIT_MODEL.md).

---

## After the Demo

Servers (Anvil and Next.js) stop automatically when the Playwright script finishes. Logs are in `logs/`, and the chain state is saved to `chain-state-demo.json`. By default the next run deploys fresh; pass `--reuse` to reload the saved state instead.
