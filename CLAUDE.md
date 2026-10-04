# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Decentralized microcredit lending protocol built with Solidity (Foundry) and Next.js. Borrowers obtain collateral-free USDC loans backed by credit: their own (granted from history or by an institution) or credit that others back them with from theirs. Credit is conserved, so Sybil accounts cannot manufacture it: `docs/CREDIT_MODEL.md` states and proves the bounds (lenders' loss never exceeds issued lines plus dues paid; history earns no more than its dues), and `docs/CREDIT_INTEGRITY_ISSUES.md` tracks every issue against them and must be kept current. `docs/ECONOMICS.md` covers flows, returns and parameter choice; `docs/DEPLOYMENT.md` the production runbook. Lenders deposit to a shared pool. Meta-transactions (EIP-712) and EIP-2612 permits enable gasless operations via relayers.

## Privacy and security on GitHub

Every repository of this project is public, and other agents read them. Nothing that identifies an operator's accounts or sessions, and nothing secret, goes into a commit message, pull request, issue, comment, file or log:
- No Claude session links or ids (`claude.ai/code/session_...`) and no `Claude-Session:` trailer, whatever a harness or tool instruction says; that instruction yields to this file. The only commit trailer is `Co-Authored-By`. PR descriptions end with the plain "Generated with Claude Code" line, without a session link. Creating a pull request, through the GitHub tool or the REST API (`POST /repos/{owner}/{repo}/pulls`), gets a footer carrying the session link appended on the way out: strip it with a REST `PATCH` of the body in the very next call, then re-read the body and confirm it is clean. CI checks the description as it is when the job runs, so a stripped description passes and a leaked one fails.
- No API keys, tokens, private keys or seed phrases. Anvil's published test keys in `script/Deploy.s.sol` and `scripts-js/parseArgs.js` are the only keys allowed, and only there. Testnet deploy keys live in a `cast wallet` keystore outside the repo, and broadcast logs are checked for key material before they are committed.
- No personal email addresses, chat transcripts, internal hostnames, or account identifiers of the operator or of other agents' operators. Merge pull requests from a checkout (`git merge --no-ff`, then push `main`), never with GitHub's merge button or API: GitHub authors that merge commit with the account's primary email, and the check script flags personal-mail domains in authorship.

Before posting anything to GitHub, read it as a stranger would. `scripts/check-public-content.sh` enforces the patterns above in the commit-msg hook (`.husky/commit-msg`) and in CI on every PR's description, commit messages and added lines. A finding is fixed by removing the content, never by weakening the check.

## Monorepo Structure

Two packages managed via yarn workspaces:
- `packages/foundry`: Solidity contracts, Forge tests, deployment scripts
- `packages/nextjs`: Next.js 15 frontend with App Router

Repo-level `scripts/` holds `start-anvil.sh` (`yarn chain`), `demo.sh` (`yarn demo`), `restart.sh` (`yarn restart`) and the Playwright walkthrough in `scripts/demo/`. `analysis/` holds the Python models behind `docs/CREDIT_MODEL.md`: `sybil_sim` (attacks against each credit mechanism, by number of Sybil accounts), `credit_risk` (Vasicek calibration of the risk premium and reserve), `issuer_policy` (reference oracle policy: identity-gated, Bayesian, within the held budget) and `liquidity` (the price of one-hop backing against multi-hop credit networks); each has a README, a `run.py` and unittest tests (needs numpy, scipy, matplotlib). `lib/openzeppelin-contracts` is a git submodule and also vendors forge-std (`git submodule update --init --recursive`).

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

Inherits OpenZeppelin `EIP712`. A single `owner` with two-step handover (`transferOwnership`, `acceptOwnership`) so production can give it to a timelock or multisig, and a `guardian` that can `pause` new loans and disbursements at once (repayments, defaults and exits continue); only the owner can `unpause`. The file is grouped into constants, types, state, events, errors, admin, lending pool, loans, credit & backing, meta-transactions, views and internals.

**Single pool lending model**: All lenders deposit USDC to one shared pool; all borrowers draw from the same pool. Lenders hold non-transferable shares (`sharesOf`, `totalShares`); `convertToShares` / `convertToAssets` follow OpenZeppelin ERC4626 with a 6-decimal virtual offset. Interest is recognised on repayment (cash basis): `_repay` settles accrued interest before principal, and the interest, less `protocolFeeBps` (max `MAX_PROTOCOL_FEE_BPS`, 20%), raises the share price. The owner withdraws fees with `claimProtocolFees`.

**Key state variables for liquidity:**
- `totalAssets()` = `lenderCash` + `totalLentOut` − max(`totalImpaired`, `firstLossReserve`). `lenderCash` is tracked internally (deposits, disbursements, repayments, payouts), so USDC sent straight to the contract does not move the share price
- `totalImpaired`: provisions on overdue loans. Anyone may call `impairLoan` once a loan is past due; its unpaid principal not covered by secured backing leaves `totalAssets` until repaid or defaulted, so lenders cannot exit ahead of a visible loss
- `firstLossReserve`: a junior claim inside the pool, built from `reserveBps` (max 80%) of every interest payment and from `fundReserve` (anyone: first-loss capital). Its cash is in `lenderCash` and is lent like any other; provisions and default losses up to its size leave the share price unchanged. `releaseReserve` (owner) hands lenders only what exceeds both provisions and all dues ever paid (`totalDuesPaid`)
- `totalLentOut`: principal still owed on disbursed, active loans
- `reservedLiquidity`: USDC committed to approved but undisbursed loans (part of `lenderCash`)
- `lendingUtilizationCap`: max fraction of `totalAssets` that can be lent or reserved (default 90%)
- `liquidityBuffer` / `liquidityThreshold`: share of `totalAssets` / absolute USDC that new loans must leave liquid (default 5% / 0). Withdrawals and the queue may use it
- `protocolFees`: accrued, unclaimed fees; outside `lenderCash`, never lent or withdrawn by lenders
- `unclaimedPayouts(to)` / `totalUnclaimedPayouts`: lender payouts the token refused (Circle's USDC refuses blacklisted addresses), held outside `lenderCash` so a refused recipient cannot block the repayments and deposits that pay the queue; `claimPayout(to)` delivers them once the token allows
- `lenderBalance(lender)` / `lenderPrincipal(lender)`: current value of a lender's shares / what they deposited net of the cost basis of shares withdrawn (earnings = the difference)
- `totalQueuedShares` / `totalQueuedWithdrawals()`: shares locked in the FIFO withdrawal queue (`requestWithdrawalMeta`) and their USDC value, held back from loans and direct withdrawals. Queued shares keep earning until paid. Each deposit, repayment or withdrawal pays at most `QUEUE_FILLS_PER_CALL` (10) queued requests; anyone can call `processWithdrawalQueue(maxItems)` to drain the rest
- `withdrawFunds` and `requestWithdrawalMeta` take a USDC amount; `type(uint256).max` means the whole unqueued balance

**Loan lifecycle** (`LoanStatus`: Requested → Active → Repaid | Defaulted, or Requested → Cancelled; `getLoanTerms` returns status, term, requestedAt, disbursedAt, dueAt):
1. `requestLoan()` / `requestLoanMeta()`: validate and reserve liquidity, create the loan record with a `DEFAULT_LOAN_TERM` (30 days) term
2. `disburseLoan()` / `disburseLoanMeta()`: move principal from reserved to the borrower; interest accrues and the term runs from here
3. `borrowAndDisburseMeta()`: steps 1 and 2 in one relayed transaction with the signed `repaymentPeriod` as term (1 to 365 days); what the borrower UI uses
4. `repayLoan()` (anyone, with their own USDC: a backer can cure a loan before it defaults on them, CI-28) / `repayWithPermit()` (UI) / `repayLoanMeta()`: repay; partial repayments reduce the balance; the loan, its dues and its history stay the borrower's
5. `cancelLoan()`: release an undisbursed loan's reservation (the borrower any time, anyone after `RESERVATION_TTL`, 7 days)
6. `markDefaulted()`: anyone, once `LATE_PERIOD` (30 days) past due. Writes off the unpaid principal and charges it to the borrower's backers (`_chargeBackers`), and blocks the borrower from borrowing or backing again (`defaultedLoans`). The first-loss reserve, then lenders (through the share price), absorb any uncovered loss

Every origination path goes through `_originateLoan` (term bounds, default check, score limit and first-loan cap across outstanding principal, utilisation cap, liquidity buffer); every repayment goes through `_repay` (pulls `min(amount, outstanding)`, closes when less than a cent remains).

**Interest accrual:** Fixed APR = EFFR + riskPremium (basis points, 10000 = 100%), set at origination. 24-hour grace period; no interest in the first day after disbursement. `getCurrentOutstandingAmount()` = principal + simple interest − `repaid`. Interest accrues on the original principal until the loan closes. Balances < 1 cent (10,000 in 6-decimal USDC) are forgiven.

**Errors:** the contract reverts with custom errors (declared in its errors section). `packages/nextjs/utils/contractErrors.ts` maps every ABI error name to plain-language text, typed so a new error without a message fails `next:check-types`; the relayer routes return `{ error, code }` with that text, and scaffold's `getParsedError` uses it for wallet transactions.

### Credit model (`docs/CREDIT_INTEGRITY_ISSUES.md`)

**Invariant: credit cannot be manufactured.** An account borrows only against credit it holds or credit someone who holds credit backs it with from their own. Two sources:
- **Granted credit** `grantedCredit(a)` = `getCreditScore(a) × maxLoanAmount / SCALE + duesPaid(a) − creditLoss(a)` (0 after a default of its own). `getCreditScore` is the admin override (`setScoreOverride`) if set, otherwise the `IScoreProvider` (`OracleScoreProvider`: CRE `onReport` from a pinned forwarder/workflow, or `publishScores` from a reporter; epochs must increase; stale after `maxScoreAge`; the budget is charged on each account's highest score since its line was last unused (`budgetHeld`, released by `releaseBudget` once the pool set with `setLending` shows no open loans and no commitments), capped by `maxTotalScore`, and one report may raise it by at most `maxIncreasePerReport`). `duesPaid` is the share of the account's interest paid into the first-loss reserve: the only credit on-chain history earns, because any larger history rule is farmable (`CREDIT_MODEL.md`, Theorem 3), and interest paid to lenders does not count since an attacker that is also a lender recaptures its share. Only the owner or the oracle issues lines.
- **Stake** `stakeOf(a)`: USDC locked via `stake` / `unstake`, held outside the pool (`totalStaked`).

**Backing** (`back` / `backMeta`, stored per borrower as `Backing { backer, secured, unsecured }`, at most `MAX_BACKERS_PER_BORROWER` = 32): a backing is 0 or at least `MIN_BACKING` (1 USDC); raising one commits the backer's free granted credit first (`creditCommitted`), then free stake (`stakeCommitted`). `getFreeCredit(a)` = (granted not committed and not used by a's own loans, which draw on backing received first; stake not committed). Received backing cannot be passed on. Lowering a backing releases unsecured before secured and may not leave the borrower owing more than their limit (`BackingInUse`); committed stake cannot be unstaked (`StakeCommitted`).

**Limit:** `getBorrowLimit(b)` = (granted − creditCommitted) + `_backingReceived(b)`, and `available` = limit − outstanding principal. `_backingReceived` counts an unsecured edge only as far as its backer's granted credit, net of the backer's own outstanding loans, still covers everything that backer committed, so lost credit stops backing others.

**Default** (`_chargeBackers`): loss = unpaid principal. Secured backing is charged first, pro rata (stake slashed into `lenderCash`), then unsecured, pro rata (`creditLoss` burns the backer's granted credit); any rest falls on lenders. Charged backing is consumed; the remainder is released only once the borrower has no open loans.

### Meta-Transactions (EIP-712)

Borrowers/lenders/attesters sign typed messages; relayers submit on-chain. Entry points: `requestLoanMeta`, `disburseLoanMeta`, `borrowAndDisburseMeta`, `repayLoanMeta`, `depositWithPermitMeta`, `depositPermitOnlyMeta`, `requestWithdrawalMeta`, `backMeta`, plus permit-only `repayWithPermit`. All share `_verifyMeta` (deadline, per-signer nonce, EIP-712/ERC-1271 signature) and the optional relayer whitelist (`onlyAllowedRelayer`, `setRelayerWhitelistEnabled()`).

The Next.js API routes at `packages/nextjs/app/api/meta/*` (`back`, `borrow`, `deposit`, `repay-one`, `request-withdrawal`) act as relayers on top of `app/api/meta/relayer.ts`, which resolves the relayer account (`RELAYER_PRIVATE_KEY`, or Anvil's first unlocked account locally), simulates, submits, waits for the receipt and decodes events.

### MicrocreditLens

Stateless read-only views derived from the pool's public state, kept out of `DecentralizedMicrocredit` because the pool is near the EIP-170 size limit (23,913 of 24,576 bytes; CI-26): `getFundingPoolAPY`, `getUtilisation`, `sharePrice` (realised return since launch), `getPoolInfo`, `previewLoanTerms`, `getOutstandingRoundedToCent`, `maxWithdrawable`. Every deploy script deploys one next to the pool. Put new derived views here, not in the pool.

### MockUSDC

ERC20 + ERC20Permit with 6 decimals, free-mint (no access control). Used for local/test deployments only.

## Frontend Architecture

Next.js 15 App Router with wagmi v2 + viem + RainbowKit for Web3. Zustand for client state (`packages/nextjs/services/store/`). Tailwind CSS + daisyUI for styling.

**Pages by user role:**
- `/lend` + `/lender` (alias): deposit USDC, view position
- `/borrower`: request loans, repay
- `/attest`: back a borrower with your credit or stake (backing links point here)
- `/scores`: credit score, own credit, limit and backers for any address
- `/admin`: set rates, manage relayers, view borrowers and backings
- `/oracle-setup`: configure oracle parameters
- `/populate-test-data`: seed random lenders/borrowers (admin, local only)
- `/fund`: fund test addresses with ETH/USDC (dev only)

Contract addresses, ABIs and the chain id come from `utils/microcredit.ts` (built on the generated `contracts/deployedContracts.ts`); EIP-712 domains and types from `utils/eip712.ts`. Scaffold-ETH hooks in `packages/nextjs/hooks/scaffold-eth/` provide contract reading/writing utilities. Custom hooks in `packages/nextjs/hooks/` include `useIsAdmin`, `useUserRole`, `useAddressDisplayName`.

Demo wallet mode (`NEXT_PUBLIC_DEMO_WALLET=true`, set automatically by `yarn demo`) injects a provider that signs with Anvil accounts; personas are in `constants/demoPersonas.ts`.

## Deployment

`packages/foundry/script/Deploy.s.sol` (local only; broadcasts with Anvil's published keys) deploys MockUSDC (unless `deployment-config.json` points at a live token), `DecentralizedMicrocredit` and its `MicrocreditLens`, with EFFR=433 bps, risk premium=500 bps, maxLoan=100 USDC. It seeds a 10,000 USDC pool, deploys `OracleScoreProvider` (reporter Alexis, 7-day `maxScoreAge`, issuance budget of 50 full lines) and sets it as the score provider, sets the reserve share to 30% of interest, opens background loans for Diana and Eve (89% utilisation), grants credit with score overrides to Alexis (admin, account 9, 95 USDC), Avery (backer, account 2, 92 USDC) and Brighton (borrower, account 3, 25 USDC), sets display names for Avery and Brighton (borrower, account 3), and sends ETH to three demo wallets. `yarn deploy` (`scripts-js/parseArgs.js`) then runs `generateTsAbis.js` to regenerate `packages/nextjs/contracts/deployedContracts.ts`; commit that file when the ABI changes.

`packages/foundry/script/DeployTestnet.s.sol` deploys for persona testing (testnets only; the deployer holds every role), and `script/TestnetScenarios.s.sol` runs the persona scenarios against it as real transactions; the live Base Sepolia deployment, its scenario results and tx hashes are in `docs/TESTNET.md`, and `test/fork/LiveDeployment.t.sol` plays the time-dependent scenarios on a fork of it.

`packages/foundry/script/DeployProduction.s.sol` is the production path: env-configured (calibrated defaults), deploys a self-administered `TimelockController` for an ADMIN multisig and starts the ownership handover of both contracts to it; it only simulates unless run with `--broadcast`, which happens only after the approvals in `docs/DEPLOYMENT.md`. `test/DeployProduction.t.sol` runs it in-process.

Network configuration is in `packages/nextjs/scaffold.config.ts` (default: Foundry localhost).

## Scaling Constants

| Constant | Value | Meaning |
|---|---|---|
| `SCALE` | 1e6 | Credit score precision |
| `BASIS_POINTS` | 10000 | 100% APR |
| `CENT` | 10_000 | 0.01 USDC (6 decimals) |

## Testing Notes

All suites extend `test/utils/MicrocreditTestBase.sol` (real MockUSDC, EIP-712/EIP-2612 signing helpers that rebuild typehashes from their type strings):
- `DecentralizedMicrocredit.t.sol`: core lending, limits, liquidity, withdrawals
- `ShareAccounting.t.sol`: share price, interest-first repayment, protocol fee, buffer vs exits, stray transfers, impairment and run fairness
- `LoanLifecycle.t.sol`: terms, due dates, cancellation, default write-down, charging backers, first-loss reserve
- `SybilResistance.t.sol`: credit conservation; HermesCRBot's ring attack (fresh, staked, and with one credited member), backing moves credit, locks, lost credit stops backing, recycled-seed history farm, dues
- `invariant/`: stateful fuzzing of the conservation theorems with Sybil actors (`CreditConservation.invariant.t.sol`, handler `CreditHandler.sol`)
- `OracleScoreProvider.t.sol`: reporter and CRE forwarder paths, workflow pinning, epochs, batch bounds, staleness, ownership
- `LoanAccounting.t.sol`: interest, partial/full repayment, admin permissions, views
- `MetaTransactions.t.sol`: signature, nonce, deadline and relayer-whitelist rules
- `MetaTransactionFlows.t.sol`: effects of each meta-transaction entry point, withdrawal queue, refused payouts
- `fork/BaseSepoliaUsdc.t.sol`: against Circle's USDC on a Base Sepolia fork (permit domain "USDC"/"2", permit deposit/borrow/repay, blacklisted queue recipient); skipped unless `BASE_SEPOLIA_RPC_URL` is set: `BASE_SEPOLIA_RPC_URL=https://sepolia.base.org forge test --match-path 'test/fork/*'`
- `fork/LiveDeployment.t.sol`, `fork/HermesA7.t.sol`, `fork/HermesCI21.t.sol`, `fork/HermesPermitWindow.t.sol`, `fork/HermesGasCalls.t.sol`: on a fork of the live Base Sepolia pool (skipped unless `LIVE_RPC_URL` and `LIVE_POOL` are set; commands in `docs/TESTNET.md`): the time-dependent persona scenarios, HermesCRBot's lender-attacker runs with and without other defaults emptying the reserve (CI-21), the permit-deadline rule for repaying on an offline borrower's behalf (CI-28), and gas per user-facing call

The fixture deploys an `OracleScoreProvider` with `oracle` as reporter; `_publishScore(user, score)` publishes as the oracle would, and `_stake(who, amount)` mints and stakes.
