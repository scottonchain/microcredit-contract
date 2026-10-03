# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Decentralized microcredit lending protocol built with Solidity (Foundry) and Next.js. Borrowers obtain collateral-free USDC loans backed by social reputation, computed via an on-chain PageRank algorithm over weighted attestation graphs. Lenders deposit to a shared pool. Meta-transactions (EIP-712) and EIP-2612 permits enable gasless operations via relayers.

## Monorepo Structure

Two packages managed via yarn workspaces:
- `packages/foundry`: Solidity contracts, Forge tests, deployment scripts
- `packages/nextjs`: Next.js 15 frontend with App Router

Repo-level `scripts/` holds `start-anvil.sh` (`yarn chain`), `demo.sh` (`yarn demo`), `restart.sh` (`yarn restart`) and the Playwright walkthrough in `scripts/demo/`. `lib/openzeppelin-contracts` is a git submodule and also vendors forge-std (`git submodule update --init --recursive`).

## Commands

Run from the repo root:

```bash
yarn chain          # Start local Anvil node (localhost:8545), state persisted to chain-state.json
yarn deploy         # Deploy contracts to local Anvil and regenerate deployedContracts.ts
yarn start          # Start Next.js dev server
yarn demo           # Chain + deploy + app + scripted Playwright walkthrough (--manual skips the browser)
yarn restart        # Kill servers, reset chain state, restart and redeploy
yarn foundry:test   # Run all Forge tests
yarn foundry:lint   # forge fmt --check + prettier on scripts-js
yarn next:lint      # Lint the Next.js package (CI uses --max-warnings=0)
yarn next:check-types
yarn next:build     # Production build (catches prerender errors lint/types miss)
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

Inherits `PageRank` (graph + computation) and OpenZeppelin `EIP712`. The file is grouped into constants, types, state, events, admin, lending pool, loans, credit, meta-transactions, views and internals.

**Single pool lending model**: All lenders deposit USDC to one shared pool; all borrowers draw from the same pool.

**Key state variables for liquidity:**
- `totalDeposits`: principal deposited by lenders, net of withdrawals
- `totalLentOut`: principal currently held by active borrowers
- `reservedLiquidity`: USDC committed to approved but undisbursed loans
- `lendingUtilizationCap`: max fraction of pool that can be lent or reserved (default 90%)
- `liquidityBuffer` / `liquidityThreshold`: share of deposits / absolute USDC kept liquid (default 5% / 0)
- `totalQueuedWithdrawals`: USDC owed to the FIFO withdrawal queue (`requestWithdrawalMeta`); held back from loans and direct withdrawals. Each deposit, repayment or withdrawal pays at most `QUEUE_FILLS_PER_CALL` (10) queued requests; anyone can call `processWithdrawalQueue(maxItems)` to drain the rest

**Loan lifecycle:**
1. `requestLoan()` / `requestLoanMeta()`: validate and reserve liquidity, create the loan record; interest accrues from here
2. `disburseLoan()` / `disburseLoanMeta()`: move principal from reserved to the borrower (only once per loan)
3. `borrowAndDisburseMeta()`: steps 1 and 2 in one relayed transaction (what the borrower UI uses)
4. `repayLoan()` / `repayWithPermit()` (UI) / `repayLoanMeta()`: repay; partial repayments reduce the balance

Every origination path goes through `_originateLoan` (score limit across active loans, utilisation cap, liquidity buffer); every repayment goes through `_repay` (pulls `min(amount, outstanding)`, closes when less than a cent remains).

**Interest accrual:** Fixed APR = EFFR + riskPremium (basis points, 10000 = 100%), set at origination. 24-hour grace period; no interest in the first day. `getCurrentOutstandingAmount()` = principal + simple interest − `repaid`. Interest accrues on the original principal until the loan closes. Balances < 1 cent (10,000 in 6-decimal USDC) are forgiven.

**Credit score gating:** Max borrow = `creditScore × maxLoanAmount / SCALE` (`Math.mulDiv`), summed across the borrower's active loans. Credit score is an admin override (`setScoreOverride`) if set, otherwise derived from PageRank.

### PageRank-Based Credit Scores (`PageRank.sol`)

Attesters create weighted directed edges (0–100% confidence) to borrowers; re-attesting replaces the edge weight. The on-chain PageRank (alpha=0.85, max 100 iterations, per-node convergence threshold 1e-3) runs after every attestation (demo only). The personalization vector comes from the `_personalizationWeight` hook:
- Admin score override, if set; otherwise
- `basePersonalization` + deposits (capped at `personalizationCap`) + `kycBonus` for KYC-verified users

Scores are scaled to `PR_SCALE = 100000`; credit score = `SCALE * x / (x + 100)` with `x = 1000 * PR / max(PR)`. `computePageRank()` is callable by anyone and is gas-intensive; `clearPageRankState()` is owner/oracle only.

### Meta-Transactions (EIP-712)

Borrowers/lenders/attesters sign typed messages; relayers submit on-chain. Entry points: `requestLoanMeta`, `disburseLoanMeta`, `borrowAndDisburseMeta`, `repayLoanMeta`, `depositWithPermitMeta`, `depositPermitOnlyMeta`, `requestWithdrawalMeta`, `attestMeta`, plus permit-only `repayWithPermit`. All share `_verifyMeta` (deadline, per-signer nonce, EIP-712/ERC-1271 signature) and the optional relayer whitelist (`onlyAllowedRelayer`, `setRelayerWhitelistEnabled()`).

The Next.js API routes at `packages/nextjs/app/api/meta/*` (`attest`, `borrow`, `deposit`, `repay-one`, `request-withdrawal`) act as relayers on top of `app/api/meta/relayer.ts`, which resolves the relayer account (`RELAYER_PRIVATE_KEY`, or Anvil's first unlocked account locally), simulates, submits, waits for the receipt and decodes events.

### MockUSDC

ERC20 + ERC20Permit with 6 decimals, free-mint (no access control). Used for local/test deployments only.

## Frontend Architecture

Next.js 15 App Router with wagmi v2 + viem + RainbowKit for Web3. Zustand for client state (`packages/nextjs/services/store/`). Tailwind CSS + daisyUI for styling.

**Pages by user role:**
- `/lend` + `/lender` (alias): deposit USDC, view position
- `/borrower`: request loans, repay
- `/attest`: create attestations for other addresses
- `/scores`: view PageRank credit scores
- `/admin`: set rates, trigger PageRank computation, manage relayers
- `/oracle-setup`: configure oracle parameters
- `/populate-test-data`: seed random lenders/borrowers (admin, local only)
- `/fund`: fund test addresses with ETH/USDC (dev only)

Contract addresses, ABIs and the chain id come from `utils/microcredit.ts` (built on the generated `contracts/deployedContracts.ts`); EIP-712 domains and types from `utils/eip712.ts`. Scaffold-ETH hooks in `packages/nextjs/hooks/scaffold-eth/` provide contract reading/writing utilities. Custom hooks in `packages/nextjs/hooks/` include `useIsAdmin`, `useUserRole`, `useAddressDisplayName`.

Demo wallet mode (`NEXT_PUBLIC_DEMO_WALLET=true`, set automatically by `yarn demo`) injects a provider that signs with Anvil accounts; personas are in `constants/demoPersonas.ts`.

## Deployment

`packages/foundry/script/Deploy.s.sol` (local only; broadcasts with Anvil's published keys) deploys MockUSDC (unless `deployment-config.json` points at a live token) and `DecentralizedMicrocredit` with EFFR=433 bps, risk premium=500 bps, maxLoan=100 USDC. It seeds a 10,000 USDC pool, opens background loans for Diana and Eve (89% utilisation), sets score overrides for Alexis (admin, account 9, 95%) and Avery (attester, account 2, 92%), sets display names for Avery and Brighton (borrower, account 3), and sends ETH to three demo wallets. `yarn deploy` (`scripts-js/parseArgs.js`) then runs `generateTsAbis.js` to regenerate `packages/nextjs/contracts/deployedContracts.ts`; commit that file when the ABI changes.

Network configuration is in `packages/nextjs/scaffold.config.ts` (default: Foundry localhost).

## Scaling Constants

| Constant | Value | Meaning |
|---|---|---|
| `SCALE` | 1e6 | Credit score / attestation weight precision |
| `BASIS_POINTS` | 10000 | 100% APR |
| `PR_SCALE` | 100000 | PageRank score precision |
| `CENT` | 10_000 | 0.01 USDC (6 decimals) |

## Testing Notes

All suites extend `test/utils/MicrocreditTestBase.sol` (real MockUSDC, EIP-712/EIP-2612 signing helpers that rebuild typehashes from their type strings):
- `DecentralizedMicrocredit.t.sol`: core lending, limits, liquidity, withdrawals
- `LoanAccounting.t.sol`: interest, partial/full repayment, admin permissions, views
- `MetaTransactions.t.sol`: signature, nonce, deadline and relayer-whitelist rules
- `MetaTransactionFlows.t.sol`: effects of each meta-transaction entry point
- `PageRankVerification.t.sol`: verifies Solidity PageRank matches the NetworkX baseline from `scripts-py/` (tolerance: 100 = 0.1% of PR_SCALE)

PageRank tests use hardcoded expected values from NetworkX. If the algorithm changes, update both (see `test/README_PageRank.md`).
