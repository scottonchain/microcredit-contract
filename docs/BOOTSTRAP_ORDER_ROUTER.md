# The bootstrap order router (`BootstrapOrderRouter`)

One manager for the bootstrap product: a consenting customer's **funded exact order** pays a named loan first, and the
loan is **backed by roots' stake** through the two-hop router. It composes `BootstrapOrderEscrow` and
`TransitiveStakeRouter` into a single contract because a worker can name only one pool manager and backing locks that
choice (CI-31); two managers could never act on the same loan. Testnet only; not a human-lending release. The pool is
unchanged apart from the manager gate. This document states what the code does and where it stops; the base
machinery (consents, vault, `sync`, loss attribution) is described in `TRANSITIVE_STAKE_ROUTER.md`.

Components kept for their own tests and labelled as such: `TransitiveStakeRouter` (the unbound two-hop router: anyone
holding the borrower's signed pool request and the consents may originate; it binds no order) and
`BootstrapOrderEscrow` (an order adapter backed by a sponsor's own stake at the pool). Neither is deployed by
`DeployBootstrapCandidate.s.sol`, and an order-bound worker has no unbound entry: `BootstrapOrderRouter` has exactly
one origination function, `originateOrder`.

## Flow

1. The worker (a borrower with no credit, no ETH, no USDC) names the router as its pool manager, **before any backing
   exists**: the one direct transaction it needs.
2. Roots deposit USDC (`deposit`); it sits in `free[root]`. Roots and mids sign EIP-712 `EdgeConsent`s (below).
3. A customer funds an order: `fund(Intent, price, maxDebt, settleBy)`. The intent is the pool request field for field
   (worker, vendor, amount, term, max APR, the worker's pool nonce, the deadline) plus a job hash; the pool and token
   are in the hash. `price` is escrowed; `maxDebt` caps what may be repaid out of it.
4. The worker signs the pool's `BorrowAndDisburse` and the router's `AcceptOrder(orderId, payer, price, maxDebt,
   settleBy, intentHash)`.
5. Anyone submits `originateOrder(id, request, poolSig, orderSig, paths)`. The router checks the order is Funded and
   in its window, every request field equals the intent, the worker's acceptance verifies (EOA or ERC-1271), then in
   one transaction reserves the roots' USDC along one to four consented paths, sends it to the worker's vault, which
   stakes it and backs the worker with all of it (secured), calls `pool.borrowAndDisburseMeta` as the worker's manager,
   and binds the new loan to the order (`loanOrder`).
6. The customer accepts delivery with `settleOrder(id)`: the loan's current debt is repaid out of the order's escrow
   first (capped by `maxDebt` and the price), the worker receives the remainder, and the roots' lot is returned in the
   same transaction (`sync`).
7. The customer may `refundOrder(id)` at any time before settlement, and anyone may return an expired order's escrow to
   its payer. A refund returns the escrow only: **it never forgives a disbursed loan and never releases the roots'
   lot**. If nobody cures the loan, `markDefaulted` charges the vault's stake and `sync` attributes the loss to the
   roots pro rata to their path amounts.

## Shared root-to-mid budget

A root consent is `EdgeConsent(from=root, to=mid, borrower=scope, limit, maxTerm, version, expiry)` where `scope` is
zero (any borrower the mid vouches for) or one exact borrower. Its live exposure, version and revocation are **shared
across every borrower the root has delegated to that mid**: the edge is `(root, mid)`, so `limit` caps the relationship,
not one loan. The mid consent is `(mid, borrower)`. `revokeRootEdge(mid)` voids every root consent for that mid,
whatever its scope; `revokeMidEdge(borrower)` voids only that terminal edge. Live exposure stays until its loans close.
Root cash is a separate hard bound: allocations come out of `free[root]`.

## Two ledgers, one balance

Roots' USDC (`free`, `locked`) and customers' escrow (`totalEscrowHeld`) share the contract and never mix:
`token.balanceOf(router) = totalFree + totalEscrowHeld + identified stray transfers`. A root withdraws only from
`free`; escrow leaves only through `settleOrder` or `refundOrder`; origination draws only on roots' `free` and never
treats escrow as backing.

## The officer gate (second gate)

Operator direction of 2026-10-08, reconciled with the transitive target in testbed issue 17 (comment 6065169803): every new loan needs a credit officer's approval of that exact job, and the officer cannot create credit. Origination is the AND of two separately versioned gates.

- **Graph gate (first, unchanged).** The roots' consents, versions, exposure limits and free balances, re-derived at execution. It sets the ceiling. Nothing the officer signs is read as capacity.
- **Officer gate (second, new).** `approveOrder(JobApproval, sig)` records the officer's EIP-712 approval for one funded order: order id, intent hash, maximum amount, expiry, policy version and officer epoch. `originateOrder` then requires a live approval under the current epoch and policy version for at least the order's amount (`NoApproval`, `ApprovalTooSmall`). The intent is exact, so the officer can only refuse or approve the whole order; it cannot raise, add, move or revive anything. An approval is consumed by origination and bound to one order.
- **Officer control.** `officerAdmin` (the deployer at first; `setOfficerAdmin` hands it over) names the officer and the policy version with `setOfficer`; the admin or the officer itself clears it with `revokeOfficer`. Either bumps the epoch, which voids every unused approval. Neither touches a ledger, a consent or a root's balance. The router starts with no officer, so nothing originates until one is named (fail closed). The officer key is separate from the roots' keys and from the worker's.
- **Outage.** No officer, a revoked officer or an officer contract that reverts on every call stops new admissions and nothing else: `settleOrder`, `refundOrder`, `sync`, repayment by anyone and a root's withdrawal read no officer state (`testAnOutageStopsNewAdmissionsOnlyAndLeavesEveryExitWorking`).
- **Tests.** `testNoApprovalNoOrigination`, `testRouterStartsWithoutAnOfficerAndFailsClosed`, `testAnApprovalBelowTheAmountCannotOriginate`, `testAValidApprovalNeverCreatesCapacity`, `testRevokingTheGraphDefeatsAValidApprovalWithoutTouchingIt`, `testRotatingOrRevokingTheOfficerVoidsUnusedApprovalsAndMovesNoMoney`, `testRotationWithTheSamePolicyStillVoidsOldApprovals`, `testOnlyTheAdminOrTheOfficerCanChangeTheOfficer`, `testAnApprovalForOneOrderCannotBeUsedForAnother`, `testGrantedCreditDoesNotLetAManagedWorkerSkipTheOfficer`; the invariant campaign (O1 to O7) now also rotates and revokes the officer. Seven deliberate bugs in the gate are each caught.

**Scope, stated.** The gate binds every worker that names this router as its only pool manager before any backing exists, which is how the pilot is set up. It does **not** bind a borrower who names no manager, or who clears its manager with `setManager(0)` while it owes nothing and holds no backing; and an owner or oracle granted line is capacity the officer did not approve, usable by such a borrower through the pool's ordinary entries. A pool-wide guarantee needs an immutable origination authority fixed at construction and checked in `_originateLoan` for every route (it also removes `managerOf`, `setManager` and their locks); a governed authority would be an owner bypass. Its bytes are being measured; the pool is 24,538 of 24,576 today. Tracked as CI-32.

## What is tested

- `BootstrapOrderRouter.t.sol` (25 tests; 27 with the two token cases in `fork/BootstrapOrderRouterFork.t.sol`, run
  against Circle's USDC on a Base Sepolia fork): the composed flow with two roots (vendor paid, debt cleared before the
  worker, roots and lender exit, every unit attributed); seven-day interest and the protected reserve; **rejection
  then default** (roots bear the exact lot, lender whole); default after partial repayment; a third party curing the
  loan before settlement (nothing released twice); **no bypass** (all three pool origination routes refuse the worker,
  the unbound router's entry does not exist, a changed vendor/amount/term/APR/nonce/deadline/worker or another job's
  acceptance is rejected, replay, a refunded order's signed advance); the shared budget across two workers; ledger
  separation (a root cannot reach escrow, escrow is never backing); signatures bound to the router and chain.
- `TransitiveStakeRouter.t.sol` (37 tests) adds the shared-edge regressions: a cap of 2.0 with 1.2 used by one borrower
  refuses 1.2 for another although the root holds more, and frees after the first loan syncs (the pool's smallest
  backing is 1 USDC, so the review's 0.6 + 0.6 against 1.0 scales to 1.2 + 1.2 against 2.0); exact and wildcard
  scopes; root revocation voids every borrower's consent, mid revocation is local; a higher-limit consent of the
  same version stays usable until revoked (stated limit).
- `invariant/BootstrapOrderRouter.invariant.t.sol` (O1 to O7): the router holds exactly free roots plus escrow plus
  strays; escrow held is the open orders' prices; each root's deposits less withdrawals less losses is its free plus
  locked; locked and every shared edge's exposure follow the open paths across workers; lenders lose nothing; every
  created unit has a known holder. The campaign funds, originates, settles, refunds, repays, defaults and syncs.
- Mutation check: seven deliberate bugs (settlement or refund not debiting escrow, settlement not returning the lot, the
  root edge scoped to the borrower again, the wildcard scope refused, the exact scope ignored, escrow counted twice) are
  each caught by these suites.
- `scripts/candidate_rehearsal.py run [--with-default]` replays the whole product with `cast` against the deployed
  candidate on a fork with Circle's USDC (`CANDIDATE_VERIFICATION.md`).

## Limits, stated

- **The lot equals the loan.** Backing is the loan's principal 1:1, so the loan is at least `MIN_BACKING` (1 USDC).
  A smaller advance needs over-backing, which this contract does not offer.
- **The customer decides acceptance, not an oracle.** Rejection refunds the customer and leaves the debt with the worker
  and the loss with the roots; the roots consented to the worker and the job class, not to the customer's verdict.
  Customer, worker and roots may be one party's aliases; nothing here detects it.
- **One open lot per worker**, one manager per worker, and the pool's relayer whitelist, if enabled, must name the router.
- **A mid has no capital at risk** and the submitter picks the paths among the consents it holds (see
  `TRANSITIVE_STAKE_ROUTER.md`). Consents of one version on one edge are interchangeable.
- **Liveness only:** a stranger can back a fresh address before it names a manager (the pool then refuses
  `setManager`), and can fill the pool's 32 backer slots; neither touches safety.
- **Token risk:** a blacklisted vendor makes `originateOrder` fail whole; a blacklisted worker blocks `settleOrder`,
  and the customer can still refund (tested on the fork).
- **Not audited; testnet only.** The live Base Sepolia pool keeps its old bytecode.
