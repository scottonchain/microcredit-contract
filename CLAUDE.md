# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Decentralized microcredit lending protocol built with Solidity (Foundry) and Next.js. Borrowers obtain collateral-free USDC loans backed by social reputation, computed via an on-chain PageRank algorithm over weighted attestation graphs. Lenders deposit to a shared pool. Meta-transactions (EIP-712) enable gasless operations via relayers.

## Monorepo Structure

Two packages managed via yarn workspaces:
- `packages/foundry` — Solidity contracts, Forge tests, deployment scripts
- `packages/nextjs` — Next.js 15 frontend with App Router

## Commands

Run from the repo root:

```bash
yarn chain          # Start local Anvil node (localhost:8545)
yarn deploy         # Deploy contracts to local Anvil
yarn start          # Start Next.js dev server
yarn foundry:test   # Run all Forge tests
yarn next:lint      # Lint the Next.js package
```

Run from `packages/foundry`:

```bash
forge test                                        # Run all tests
forge test --match-test testRequestLoan           # Run a single test
forge test --match-contract MetaTransactions      # Run a specific test contract
forge test --gas-report                           # With gas reporting
forge build                                       # Compile contracts
```

Node >= 20.18.3 and Foundry are required.

## Smart Contract Architecture

### Core Contract: `DecentralizedMicrocredit.sol`

**Single pool lending model**: All lenders deposit USDC to one shared pool; all borrowers draw from the same pool.

**Key state variables for liquidity:**
- `totalDeposits` — cumulative USDC deposited by lenders
- `totalLentOut` — principal currently held by active borrowers
- `reservedLiquidity` — USDC committed to approved but undisbursed loans
- `lendingUtilizationCap` — max fraction of pool that can be lent (default 90%)

**Loan lifecycle:**
1. `requestLoan()` — reserves liquidity, creates loan record
2. `disburseLoan()` — owner/oracle moves USDC from reserved to borrower; starts interest accrual
3. `repayLoan()` / `repayLoanMeta()` — borrower repays principal + accrued interest

**Interest accrual:** Fixed APR = EFFR + riskPremium (basis points, 10000 = 100%). 24-hour grace period; no interest in first day. `getCurrentOutstandingAmount()` calculates dynamically. Balances < 1 cent (10,000 in 6-decimal USDC) are forgiven.

**Credit score gating:** Max borrow = `creditScore × maxLoanAmount / SCALE`. Credit score comes from PageRank.

### PageRank-Based Credit Scores

Attesters create weighted directed edges (0–100% confidence) to borrowers. The on-chain PageRank algorithm (alpha=0.85, tolerance=1e-6, max 100 iterations) computes scores. The personalization vector combines:
- `basePersonalization` — baseline weight for all addresses
- `kycBonus` — extra weight for KYC-verified users
- Deposit-based component (capped at `personalizationCap`)

Scores are scaled to `SCALE = 1e6` internally; `PR_SCALE = 100000` for PageRank output. `computePageRank()` is called by the owner/oracle and is gas-intensive.

### Meta-Transactions (EIP-712)

Borrowers/lenders sign typed messages; relayers submit on-chain. Supported operations: `requestLoanMeta`, `disburseLoanMeta`, `repayLoanMeta`, `depositFundsMeta`, `withdrawFundsMeta`, `recordAttestationMeta`. Nonces prevent replay. Optional relayer whitelist via `setRelayerWhitelistEnabled()`.

The Next.js API routes at `packages/nextjs/app/api/meta/*` act as relayers — they receive signed messages from the frontend and submit them to the contract.

### MockUSDC

ERC20 + ERC20Permit with 6 decimals, free-mint (no access control). Used for local/test deployments only.

## Frontend Architecture

Next.js 15 App Router with wagmi v2 + viem + RainbowKit for Web3. Zustand for client state (`packages/nextjs/services/store/`). Tailwind CSS + daisyUI for styling.

**Pages by user role:**
- `/lend` + `/lender` — deposit USDC, view position
- `/borrower` — request loans, repay
- `/attest` — create attestations for other addresses
- `/scores` — view PageRank credit scores
- `/admin` — set rates, trigger PageRank computation, manage relayers
- `/oracle-setup` — configure oracle parameters
- `/fund` — fund test addresses with ETH/USDC (dev only)

Scaffold-ETH hooks in `packages/nextjs/hooks/scaffold-eth/` provide contract reading/writing utilities. Custom hooks in `packages/nextjs/hooks/` include `useActiveLoanId`, `useIsAdmin`, `useUserRole`.

## Deployment

`packages/foundry/script/Deploy.s.sol` deploys MockUSDC (if needed) and `DecentralizedMicrocredit`, sets initial rates (EFFR=433 bps, risk premium=500 bps, maxLoan=100 USDC), provisions ETH to three demo addresses, and writes `deployment.json`.

Network configuration is in `packages/nextjs/scaffold.config.ts` (default: Foundry localhost).

## Scaling Constants

| Constant | Value | Meaning |
|---|---|---|
| `SCALE` | 1e6 | Credit score precision |
| `BASIS_POINTS` | 10000 | 100% APR |
| `PR_SCALE` | 100000 | PageRank score precision |
| `CENT` | 10_000 | 0.01 USDC (6 decimals) |

## Testing Notes

Three test contracts:
- `DecentralizedMicrocredit.t.sol` — core lending, liquidity, PageRank
- `MetaTransactions.t.sol` — EIP-712 signature flows
- `PageRankVerification.t.sol` — verifies Solidity PageRank matches Python NetworkX baseline (tolerance: 2,000 = 0.2% of PR_SCALE)

PageRank tests use hardcoded expected values from NetworkX. If the algorithm changes, update both.
