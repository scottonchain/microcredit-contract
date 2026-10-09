# Bootstrap candidate: ordered execution packet (Base Sepolia)

**Draft. Not authorization.** Nothing here may be executed until (1) Codex has accepted a named head in writing (done for
2986e23, review 5463615873), (2) Hermes has reproduced that exact head (`scripts/candidate_evidence.sh`, compared with the head's
`SHA256SUMS`; receipt on testbed issue 15, comment 6071727539), (3) Codex has recorded its disposition on that receipt and
revalidated this packet in writing, and (4) the operator's existing bounds hold: Base Sepolia only, test USDC only, no mainnet or
real-money action, no officer grant, no mint or faucet retry, no use of the original wallets or the live pool's funds.

**What is rehearsed and what is not.** G0 to G3 and **C1** are the ordered call list of `scripts/candidate_rehearsal.py run`
(including the officer steps), which has passed on a fork of this chain with Circle's USDC; the fork replaces the custodian's
keystores with throwaway keys and the funding by impersonation with real transfers. **C2 and C3 are not in the rehearsal.** The
rehearsal's optional tail (`--with-default`) refunds an order and then jumps time to an uncured default, which is a different
scenario from C2's stranger cure. The parts of C2 and C3 are covered separately by unit tests on a local EVM, not by an earlier
run of the same sequence: the cure by a third party `testAThirdPartyCuresTheLoanBeforeSettlementAndNothingIsReleasedTwice`
(before settlement, not after a refund); refund, expiry and escrow separation `testExpiredOrderRefundsOnlyTheOriginalPayer` and
`testRootsCannotWithdrawEscrowAndRefundsCannotTouchRootFunds`; the officer outage and rotation
`testAnOutageStopsNewAdmissionsOnlyAndLeavesEveryExitWorking`, `testRotatingOrRevokingTheOfficerVoidsUnusedApprovalsAndMovesNoMoney`
and `testRotationWithTheSamePolicyStillVoidsOldApprovals`. C2 and C3 are therefore **optional extensions, run only after C1 is
clean**, and their first public run is itself new evidence, not a repeat.

## Scope and budget

- Contracts: deploy `DeployBootstrapCandidate.s.sol` at the accepted head (pool, lens, `BootstrapOrderRouter`). The pool is
  built with the router as its immutable originator (the script predicts the router's address and checks it), so no other
  caller can originate for any borrower. The live pool at `0x7387...` is not touched.
- Roles (fresh keystores, custodian-held, never in the repository): deployer, lender, root1, root2, mid, worker, customer,
  officer (its own key; signs approvals, never sends a transaction), submitter (any funded account). The worker needs no ETH and
  sends no transaction. **The vendor is the funding account `F` itself** (the account that pays the lender, roots and customer),
  so the vendor's 1 USDC lands back in the funding ledger and no separate vendor needs gas to return it. **The stranger in C2 is
  also `F`**, repaying with its own USDC.
- Test USDC out of `F`, per run: lender 5, root1 1, root2 1, customer 1.5 (8.5); C2 adds the stranger's 1 (the cure), so at most
  9.5 at any one time and 18 in all for C1 plus C2, within the 25 cap. ETH: deployment about 13.1 million gas (0.00008 ETH at
  0.006 gwei plus the L1 data fee), then about 25 transactions; cap 0.003 ETH in total, as in the existing live-run bound.
- Expected final ledger per role after cleanup (C1, then C2 on the same deployment): `F` back to its starting balance (the
  vendor payment +1 offsets the stranger's cure -1, and every other unit returns); lender, roots, customer, worker, router and
  pool at 0 of the test USDC. The worker's 0.5 USDC per settled order returns to `F` by an EIP-3009 `transferWithAuthorization`
  signed by the worker and submitted by `F` (the worker holds no ETH); if the token refuses that call, the 0.5 stays with the worker
  and the ledger records it as a holding, not as a loss. Anything else left behind is a mismatch and stops the run.

## Gates, in order (stop at the first that fails)

1. **G0 head.** The accepted SHA is checked out; `git status` clean; `forge build` output sizes match the head's
   `logs/build-sizes.txt`.
2. **G1 preflight.** `cast chain-id` = 84532; record block number and hash and UTC time; Circle test USDC at
   `0x036CbD53842c5426634e7929541eC2318f3dCF7e` has code and `decimals() = 6`; the funding ledger shows the 18 USDC and the
   ETH are unearmarked holdings; no loan is open for any role address.
3. **G2 deployment.** Run the deploy script with the custodian's keystore (`--account`, `--sender`),
   `BOOTSTRAP_ORACLE` set to an address the custodian controls (no scores are used) and **no** `OFFICER` (the router starts
   with no officer, so nothing can originate yet). Record the three addresses and transaction hashes. Then `python3 scripts/verify_candidate_deployment.py --rpc <url> --pool .. --lens .. --router ..
   --json`: all three strict matches and every wiring check must pass, and the metadata-free masked-runtime hashes (`masked_nometa_sha256_*`) and the ABI sha256
   values must equal the head's `logs/verifier.json` (the full `masked_sha256_*` carries a compiler metadata hash that depends on the checkout path, so it differs between hosts); `pool.ORIGINATOR == router` and `router.officer == 0x0` are in the report. Anything
   else: stop, nothing was funded.
4. **G3 officer.** The router's admin (the deployer) calls `R.setOfficer(officer, 1)`. Read back `R.officer()`, `R.policyVersion()
   = 1` and `R.officerEpoch()`; record them. The officer key is not any of the other roles' keys.

## Ordered calls (C1: customer accepts)

Amounts in USDC base units (6 decimals). `P` pool, `R` router, `U` token.

1. lender: `U.approve(P, 5e6)`, `P.depositFunds(5e6)`.
2. (no worker transaction) Read back `P.ORIGINATOR() == R`.
3. root1, root2: `U.approve(R, 1e6)`, `R.deposit(1e6)` each.
4. customer: `U.approve(R, 1.5e6)`, then `R.fund(Intent, 1.5e6, 1.5e6, settleBy)` with `Intent = (worker, vendor = F, 1e6, 604800,
   933, P.nonces(worker), deadline, keccak256("<job id>"))`, `settleBy` about 30 days out, `deadline` about an hour out. Read
   the order id from `R.nextOrderId()` before the call.
5. Signatures (typed data, `cast wallet sign --data`; `candidate_rehearsal.py typed-data pool|consent|accept|approval`
   prints the exact JSON): the worker signs the pool's `BorrowAndDisburse` and the router's `AcceptOrder`; each root signs an
   `EdgeConsent(root, mid, scope 0, limit, 30 days, version 0, expiry)` and the mid signs `EdgeConsent(mid, worker, worker,
   ...)`, split 0.6 and 0.4 USDC.
6. Negative controls by `eth_call` (each must revert as noted): `P.requestLoan(1e6)` from the worker (`NotManager`);
   `P.borrowAndDisburseMeta` from the submitter (`NotManager`); `R.originateOrder` with a changed vendor
   (`IntentMismatch`); a forged consent (revert); **`R.originateOrder` with everything signed but no officer approval
   (`NoApproval`)**.
6a. Officer approval. The officer signs `JobApproval(orderId, R.intentHash(intent) as in R.orders(orderId), maxAmount,
   expiry, R.policyVersion(), R.officerEpoch())`; the submitter records it with `R.approveOrder(approval, sig)`. First
   record one with `maxAmount = 1e6 - 1` and check that `R.originateOrder` by `eth_call` reverts `ApprovalTooSmall`; then
   have the officer re-sign for `maxAmount = 1e6` and record it. Also check by `eth_call` that an approval made under a
   stale epoch or policy version (sign one, then do not use it; see C3) is refused with `NoApproval`.
7. submitter: `R.originateOrder(orderId, request, poolSig, acceptSig, paths)`. Expect: vendor +1 USDC, `P.totalLentOut` +1
   USDC, `R.locked(root1) = 0.6`, `R.locked(root2) = 0.4`, `R.totalEscrowHeld() = 1.5`, `R.loanOrder(loanId) = orderId`.
   A replay must revert.
8. customer: `R.settleOrder(orderId)` within the first 24 hours (zero interest). Expect: the loan closed, the worker +0.5
   USDC, escrow 0, roots' `free` back to 1 each (the router syncs inside settlement).
9. Cleanup: roots `R.withdraw`, lender `P.withdrawFunds(max)`, the customer's leftover USDC to `F`, the worker's 0.5 USDC to `F`
   by `transferWithAuthorization` (see the ledger above). Final: `P.totalLentOut = 0`, `U.balanceOf(R) = 0`, `F` at its starting
   balance, and the aggregate USDC across `F`, the roles, the pool and the router equal to the start.

## C2 (optional, after a clean C1): rejection, then a stranger cures

Not in the rehearsal (see above). Repeat steps 3 to 7 with a new order (a new job id; the worker's nonce has advanced), then:
customer `R.refundOrder(orderId)` (escrow returns; the loan stays); the stranger `F` approves the pool and repays
`P.repayLoan(loanId, current outstanding)` inside the first day with its own 1 USDC; anyone `R.sync(worker)`; expect `R.lossOf = 0`
for both roots and the lot back in `free`. Cleanup as in step 9.

## C3 (optional, after a clean C1): officer outage

Fund a third order and have the officer approve it; then the admin calls `R.setOfficer(officer, 2)`. Expect by `eth_call`
that `R.originateOrder` for it reverts `NoApproval` (void under the new epoch and policy), the customer's `R.refundOrder`
works at once, and the roots' `R.withdraw` of `free` works. Set the officer back to version 1 before C2 if C2 follows.

## Not in this packet

A **default** cannot be shown on a public chain inside a day: the shortest term is 1 day and a loan defaults 30 days after
due. The fork rehearsal (`--with-default`) shows it with a time jump, labelled as such. A public default case would hold 1 USDC
of the roots' stake for at least 31 days; it needs its own decision.

## What to publish

For every transaction: sender, nonce, hash, block, status, decoded events and fees; for every `eth_call` control: the
call and the decoded revert; the funding ledger and the aggregate before and after (integer equality); the verifier JSON
and the head's evidence checksums. Stop rules: any unexpected revert or mismatch stops the run; no retry without
reconciling the nonce (`nonces(signer)` past the request means it landed); an RPC timeout is not a refusal. Missing
observations are unknown, never zero. No claim of poverty reduction, revenue or independent demand follows from internal
transfers of test currency.
