# Decentralized Microcredit Platform

![Frontend Vision](front_end_vision.png)

> **New here or looking for updates?** Read [Credit Among Strangers](https://github.com/scottonchain/microcredit-vision), the project's blog: the newest post in full, earlier posts by date, and [VERIFY.md](https://github.com/scottonchain/microcredit-vision/blob/main/VERIFY.md) to recompute every figure. The plain-language overview is the post [Live AI agents, working toward human benefit](https://github.com/scottonchain/microcredit-vision/blob/main/posts/2026-10-06-live-ai-agents-working-toward-human-benefit.md). The technical guide to the contract and the app follows below.

## Introduction

This project prototypes a full-stack **peer-to-peer micro-lending application** on an EVM network.  
Lenders earn yield on USDC deposits while borrowers obtain collateral-free loans backed by **credit**: their own, or credit that people who trust them commit from theirs.

Key ideas for crypto-aware readers:

1. **Credit is conserved, never manufactured**: an account borrows only against credit it holds (a line granted from its history or by an institution, through an admin override or the credit oracle) or credit someone else backs it with from their own. Backing moves credit; it never copies it, so Sybil accounts vouching for each other gain nothing. See `docs/CREDIT_INTEGRITY_ISSUES.md`.
2. **Fixed-rate loans**: the APR is the Effective Federal Funds Rate (EFFR) plus a configurable risk premium, fixed when the loan is created.
3. **Single liquidity pool**: deposits are pooled; liquidity is reserved when a loan is approved and released when repaid, balancing lender withdrawals with borrower demand.
4. **Gasless by default**: every user action can be signed as an EIP-712 message (or an EIP-2612 permit) and submitted by a relayer, so borrowers never need ETH.

---

## Feature Highlights

• Social backing: people with credit back borrowers from their own credit or staked USDC, and pay first if the borrower defaults  
• Credit scores published by an oracle through a swappable `IScoreProvider` (Chainlink CRE ready)  
• Unified lending pool with utilisation cap, liquidity buffer and a FIFO withdrawal queue  
• Meta-transactions for borrowing, repaying, depositing, withdrawing and backing  
• Admin panel to update EFFR, risk premium and other parameters  
• Next.js 15 front-end with live pool statistics and user dashboards

---

## Architecture & Tech Stack

| Layer           | Technology |
| --------------- | ---------- |
| Smart contracts | Solidity 0.8.x, Foundry, OpenZeppelin |
| Front-end       | Next.js 15 App Router, Tailwind CSS, daisyUI |
| Wallet / Web3   | Wagmi, RainbowKit, Viem |
| Local dev       | Anvil, Forge scripts, Playwright (demo) |

```
packages/foundry/
  contracts/   DecentralizedMicrocredit.sol, OracleScoreProvider.sol, MockUSDC.sol, interfaces/
  script/      Deploy.s.sol (local deploy + demo seed), VerifyAll.s.sol, UpdateOracle.s.sol
  scripts-js/  `yarn deploy` and keystore helpers, ABI generator
  test/        Forge tests (shared fixture in test/utils/)
packages/nextjs/
  app/         pages; app/api/meta/* are the gasless relayer routes
  utils/       microcredit.ts (deployment constants), eip712.ts (typed data)
scripts/       start-anvil.sh, demo.sh, restart.sh, demo/ (Playwright walkthrough)
lib/           OpenZeppelin submodule (forge-std is vendored inside it)
```

---

## Quick Start (local sandbox)

Prerequisites: `git`, `node >=22.18.0`, `yarn`, and Foundry (`curl -L https://foundry.paradigm.xyz | bash`).

1. **Clone & install**
```bash
git clone --recurse-submodules <repository-url>
cd microcredit-contract
yarn install
```
Already cloned without submodules? Run `git submodule update --init --recursive`.

2. **Run a local chain**
```bash
yarn chain
```
3. **Deploy contracts & seed demo users**
```bash
yarn deploy
```
This deploys MockUSDC and `DecentralizedMicrocredit`, seeds a 10,000 USDC pool and the demo personas, and regenerates `packages/nextjs/contracts/deployedContracts.ts`.

4. **Launch the front-end**
```bash
yarn start
```
Visit http://localhost:3000

Or run `yarn demo` to do all of the above and play the scripted walkthrough in a browser (see [DEMO.md](DEMO.md)). `yarn demo --manual` stops after starting the servers.

### Environment variables
The front-end reads contract addresses and ABIs from `packages/nextjs/contracts/deployedContracts.ts`. Optional overrides go in `packages/nextjs/.env.local`:
```env
NEXT_PUBLIC_DEMO_WALLET=true               # see "Wallet modes" below
NEXT_PUBLIC_ALCHEMY_API_KEY=<key>
NEXT_PUBLIC_WALLET_CONNECT_PROJECT_ID=<id>
# Server-side relayer used by app/api/meta/*
RELAYER_PRIVATE_KEY=<key>                  # optional on Anvil: the first unlocked account pays gas
RPC_URL=<url>                              # non-local chains (LOCAL_RPC_URL overrides localhost:8545)
```

---

## Wallet modes

### Normal mode (default)
The app uses the browser's injected wallet (MetaMask, Rabby, Coinbase Wallet) or the built-in burner wallet for local development.  No extra configuration needed.

```
# packages/nextjs/.env.local: omit this line entirely, or set it to false
NEXT_PUBLIC_DEMO_WALLET=false
```

### Demo wallet mode
A fake `window.ethereum` provider is injected that proxies all signing to the local Anvil node (which auto-signs with its unlocked accounts). A **DEMO** badge and a persona dropdown appear in the header so you can instantly switch between the seeded personas: **Alexis** (admin), **Avery** (backer) and **Brighton** (borrower), without touching MetaMask or triggering any wallet pop-ups. `yarn demo` turns this on automatically.

**Enable:**
```
# packages/nextjs/.env.local
NEXT_PUBLIC_DEMO_WALLET=true
```
Then restart the dev server (`yarn start`). `NEXT_PUBLIC_*` variables are baked in at build time.

**Disable / return to normal MetaMask:**
```
# packages/nextjs/.env.local
NEXT_PUBLIC_DEMO_WALLET=false   # or delete the line
```
Restart the dev server. MetaMask and all real wallet paths are completely unchanged when the flag is off.

> **Note:** Demo wallet mode requires a running Anvil node (`yarn chain`). The provider proxies every RPC call to `http://127.0.0.1:8545`.

---

## Interest and Repayment

The contract stores two basis-point values:
- `effrRate`: Effective Federal Funds Rate, intended to come from the Pyth Network oracle in production (set manually during local testing).
- `riskPremium`: additional spread to cover platform risk.

The borrower's APR is `effrRate + riskPremium`, fixed when the loan is created. Simple interest accrues on the principal from disbursement, with none during the first 24 hours. Partial repayments reduce the outstanding balance, a repayment never pulls more than is owed, and once every unit of principal is paid any interest under one cent is forgiven and the loan closes; a payment short of the principal leaves it open.

## User Guides

### Borrowers
1. Start from the credit you have: a line from your history or one an institution extends to you.  
2. Share your backing link (*Borrower* page) with people who have credit. What they back you with is added to your limit.  
3. Check the *Scores* page for your own credit, your backers and your limit.  
4. Submit a loan request on the *Borrower* page; the UI previews repayments.  
5. Repay in full or in part from the *Borrower* page before the due date shown there. Repayments are gasless: you sign one USDC permit.
6. A loan unpaid 30 days after its due date can be marked defaulted by anyone: your backers pay for it and you cannot borrow again.

### Lenders
1. Deposit USDC through the *Lend* page.  
2. Your deposit buys pool shares. Interest borrowers repay (less the protocol fee) raises the share price, so every lender earns pro rata; the *Lend* page shows deposits, interest earned and current balance.  
3. Withdraw whenever liquidity is available. The *Lend* page shows what you can withdraw now, and *Max* takes that amount; requests that cannot be paid immediately are queued, keep earning, and are filled as liquidity returns.

### Backers
1. On the *Back* page (`/attest`), back a borrower with an amount of your own credit. Your free credit line is used first; if you have none (or not enough), stake USDC to back with money instead.  
2. Your own limit falls by exactly what the borrower gains. You can lower or withdraw the backing, but not below what the borrower currently owes.  
3. If the borrower defaults, your backing pays first: staked USDC is slashed back to the lenders and committed credit is burned from your line.

### Oracle / Admin
1. Grant credit lines with score overrides, or publish scores through `OracleScoreProvider` (a Chainlink CRE workflow via `onReport`, or a reporter account). Scores go stale after `maxScoreAge` without a report.  
2. Update `effrRate`, `riskPremium`, `maxLoanAmount`, the utilisation cap and liquidity limits as needed.  
3. Monitor pool metrics and reserved liquidity.

---

## Development

• Smart-contract sources: `packages/foundry/contracts/`  
• Tests: `packages/foundry/test/`  
• Front-end code: `packages/nextjs/`  

Common tasks:
```bash
yarn foundry:test                          # Forge tests
yarn foundry:lint                          # forge fmt --check + prettier on scripts-js
yarn next:lint && yarn next:check-types    # front-end lint and types
yarn next:build                            # production build
yarn restart                               # restart chain + app and redeploy (flags in scripts/restart.sh)
```

---

## Contributing
See `CONTRIBUTING.md` for guidelines.  Pull requests are welcome.

---

© 2026 · Licensed under the MIT License

## Maintaining this repository

The [team operating guide](https://github.com/scottonchain/microcredit-agent-testbed/blob/main/coordination/README.md)
identifies each repository's maintained source. The compact local command and
architecture map is [CLAUDE.md](CLAUDE.md). Run `yarn test:all`, `yarn lint`,
`yarn next:check-types`, and `yarn next:build` when changing the app or tooling.
Generated deployments and historical evidence retain their original identities;
new code is checked on its own revision.
