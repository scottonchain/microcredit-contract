# Two-hop stake router (`TransitiveStakeRouter`, on `StakeRouterBase`)

> The bootstrap product is `BootstrapOrderRouter` (`BOOTSTRAP_ORDER_ROUTER.md`), which adds the customer's funded order to this machinery on one manager. `TransitiveStakeRouter` is the unbound building block: it binds no order. Both share `StakeRouterBase`.

An external testnet router for transitive trust without an issuer or a credit officer. A **root** puts USDC in; a
**mid** it trusts vouches for a **borrower**; the borrower borrows against the root's stake. It is the first
deployable form of the end state the operator set (trust passing through people, not through an officer): the
pool is unchanged apart from the manager gate (CI-31), and nothing here creates credit. Not a human-lending release.
The proof obligations are in the theory repository (`action:transitive-conservation-theorem`); this document states
what the code does and where it stops.

## Flow

1. The borrower names the router as its pool manager (`pool.setManager(router)`), **before any backing exists**. One
   direct transaction by the borrower (a gas cost to count as subsidy).
2. A root deposits USDC into the router (`deposit`); it sits in `free[root]` and can be withdrawn (`withdraw`) while it
   is not allocated.
3. The root signs an EIP-712 `EdgeConsent(from=root, to=mid, borrower=scope, limit, maxTerm, version, expiry)` where
   `scope` is zero (any borrower the mid vouches for) or one exact borrower; the mid signs
   `EdgeConsent(from=mid, to=borrower, borrower, ...)`. `limit` caps the **live** USDC exposure along that edge,
   `maxTerm` the repayment period of any loan that uses it. **The root edge is `(root, mid)`: its exposure, version and
   revocation are shared across every borrower the root has delegated to that mid** (a cap on the relationship, not on
   one loan); the mid edge is `(mid, borrower)`. A root voids every consent for a mid with `revokeRootEdge(mid)`, a mid
   voids its consents for a borrower with `revokeMidEdge(borrower)` (the version moves on); live exposure stays until
   its loans close. The EIP-712 domain is `("TransitiveStakeRouter", "2")`.
4. The borrower signs the pool's `BorrowAndDisburse` as usual. Anyone submits `originate(request, poolSig, paths)`:
   one to four paths whose amounts sum to the loan amount, each path being a root, a mid, their two consents and
   signatures (ERC-1271 accepted) and its amount. The router checks every consent (signer, version, expiry, term,
   limit), moves each root's USDC from `free` to `locked`, sends the sum to the borrower's `StakeVault`, which stakes it
   and backs the borrower with all of it (secured), then calls `pool.borrowAndDisburseMeta` as the borrower's manager.
5. When the loan has closed (repaid by anyone, or defaulted by `markDefaulted`), anyone calls `sync(borrower)` (every
   origination runs it first). The vault drops the backing, unstakes and returns what the pool did not slash; the
   loss is the lot less what came back, attributed to the roots pro rata to their path amounts (rounded down, the few
   remaining units one each to paths that can still bear them, so no path ever bears more than its own amount). The
   rest goes back to each root's `free`.

## What is guaranteed (tests: `TransitiveStakeRouter.t.sol`, 37 tests, also run against Circle's USDC on a Base Sepolia fork in `fork/TransitiveStakeRouterFork.t.sol` (39 with two token cases); `invariant/TransitiveStakeRouter.invariant.t.sol`)

- **Every unit a borrower draws through the router is a root's USDC held as the borrower's secured backing**, so a
  default charges the roots' stake first and lenders lose nothing while the lot covers the loan (invariant R5: pool
  total assets never fall below the deposit when every loan is a router loan).
- **A root's exposure is what it consented to.** Per edge, live exposure never exceeds the limit of the consent it was
  admitted under, and the root-to-mid edge is one bucket across all borrowers (R3 sums the open paths over each
  `(root, mid)` pair; a cap of 2.0 with 1.2 used by one borrower refuses 1.2 for another although the root holds more); a root loses at most its path amounts; revocation, expiry and term caps bind new allocations.
- **Conservation per root:** deposits less withdrawals less attributed losses equal `free + locked` (R2); the router
  holds exactly the free balances plus stray transfers (R1); `locked` and each edge's exposure are the sum of the open
  paths (R3); an open lot's vault stakes the whole lot and has no unsecured backing, a closed lot leaves nothing (R4). The pool's principal lent out equals the active lots' unpaid principal (R7).
- **Codex's bypass regression** (`testCertifiedLoanRepaidDirectlyAtPoolCannotBeReopenedOnAnyOtherPath`): after a
  certified loan is repaid directly at the pool, `requestLoan`, `requestLoanMeta` by another relayer and
  `borrowAndDisburseMeta` by another caller all revert `NotManager`.
- Concurrent certificates for one root's funds, one root for two borrowers, a shared mid edge (diamond), repeated
  edges, cycles and aliases at the address level, partial repayment then default, a third-party backer sharing the
  slash, stale syncs, replay, relayer whitelist and a donation to the vault are each a test.
- Mutation check: ten deliberate bugs in the router (loss to one path only, an exposure not released, loss ignored on
  return, the vault balance counted, the backing slot kept, `locked` not released, a limit off by one, the consent
  version ignored, the loan amount not tied to the paths, the manager check dropped) are each caught by these suites.

## Limits, stated

- **Aliases.** Distinct addresses of one person cannot be told apart on-chain. A person who controls a root and a mid
  and a borrower puts only their own USDC at risk: nothing is manufactured, but the "trust" is circular.
- **A mid has no capital at risk.** The mid's consent bounds how much can be allocated through it; a bad vouch costs the
  roots, not the mid (reputation only). Mid capital as first loss is the next stage and needs its own proof.
- **Consents of one version on one edge are interchangeable.** The limit applied is the one on the consent presented, and exposure is counted per edge across all of them (for a root edge, across all borrowers and both scopes), so a signer who wants to lower a limit must revoke (the version moves on), not sign a lower one (`testAHigherLimitConsentOfTheSameVersionStaysUsableUntilTheRootRevokes`).
- **The submitter picks the paths** among the consents it holds. Every pick is inside every signer's consent. A signer
  who wants a single use sets the limit to that use and revokes after.
- **The borrower chooses terms and vendor** inside the consents (term up to the consents' `maxTerm`, any recipient
  but the router or its vault). A root consents to a borrower, not to a purpose.
- **Liveness.** A root's lot stays locked until the loan closes; a loan nobody repays is released only after
  `markDefaulted` (permissionless, `LATE_PERIOD` after due). The pool allows 32 backers per borrower: a griefer can fill
  them with 1 USDC backings of a managed borrower and block the vault's backing, and the borrower must then use
  another address (CI-31 note). A third-party backer on the same borrower shares the slash, so roots lose less.
  Likewise a stranger can back a fresh address before it names its manager; the pool then refuses `setManager`
  (`ManagerLocked`) until that backing is withdrawn, so the borrower uses another address. Both cost the griefer a
  stake it can recover, and neither touches safety.
- **Minimum.** A transitive loan is at least `MIN_BACKING` (1 USDC), the pool's minimum backing.
- **One open loan per borrower**, one router per borrower (the manager), and the pool's relayer whitelist, if enabled,
  must name the router.
- **Stake earns nothing** at the current parameters (`ColdStartFacts.t.sol`): a root is a sponsor, not an investor. The
  router does not change the economics; it is the credit-conservation mechanism, not an incentive design.
- **Not audited, testnet only.** `DeployBootstrapCandidate.s.sol` deploys `BootstrapOrderRouter` (this machinery plus the
  order), not this unbound router.
