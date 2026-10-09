# Bootstrap candidate: ordered execution packet (Base Sepolia)

**Draft. Not authorization. Not accepted.** Codex's revalidation of this packet (contract PR 28, comment 6078698487) did not pass; this
revision answers its five items and has not been revalidated again. Nothing here may be executed until all of the following hold,
in writing:

1. **The head to deploy is accepted.** Codex's written acceptance is of source head `2986e23` (review 5463615873). The evidence of
   record was made at `3efdb6f`: Hermes's run (testbed commit `8f80978d`), whose original script exited 1 on the output format
   and whose logs pass only the retrospective evaluation with the repaired parser, packaged in
   `evidence/bootstrap-candidate-3efdb6f-hermes-run/` (its README names the tested, parser, re-evaluation and packaging revisions;
   the packet is the latest commit that touches that directory). `packages/` is identical in `2986e23` and `3efdb6f`
   (`git diff 2986e23 3efdb6f -- packages` is empty), so the contract bytes are the same. That identity is a statement by Claude;
   whether Codex's acceptance carries from `2986e23` to `3efdb6f` for execution is Codex's decision and is not assumed here.
2. **A reproduction exists and its disposition is recorded.** Codex's disposition (PR 28, comment 6078698487): Hermes's first receipt
   (testbed issue 15, comment 6071727539, at `2986e23`) remains a qualified reproduction (a wrapper and tail rerun, 64 x 80
   invariant evidence, overwritten original outputs), not a clean end-to-end run; the `3efdb6f` run supersedes it as the evidence
   of record for the packet. The `3efdb6f` run is one host's, on a local EVM and local forks, with 14 local skips.
3. **Codex has revalidated this packet in writing,** at a named revision of this file (not yet done).
4. **The operator's bounds hold:** Base Sepolia only, test USDC only, no mainnet or real-money action, no credit-line grant (no
   score override or oracle score is set; none is used), no mint or faucet retry, no use of the original wallets or the live pool's
   funds.

**Open scope item for the operator.** The bound as recorded reads "no officer grant". Gate G3 below appoints the router's
order-approval officer with `R.setOfficer`. That is a role appointment on the router, not a credit-line grant, but whether the
bound covers it is not for this draft to decide and is not decided by it. Until the operator states in writing that G3 is within
the bounds, G3 and everything after it are **not authorized**; with no officer the router admits nothing, so no order can
originate without it.

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
- Test USDC out of `F`: C1 needs lender 5, root1 1, root2 1 and customer 1.5 (8.5). C2 runs on the same deployment before the
  cleanup, so the lender's 5 and the roots' free 1 each are still in place (the settled order returned the lot); it adds only the
  customer's 1.5 and the stranger's 1 (the cure): 11 in all for C1 plus C2, within the 25 cap. C3, if run, adds the customer's
  1.5, refunded at once. ETH: deployment about 13.1 million gas (0.00008 ETH at
  0.006 gwei plus the L1 data fee), then about 35 transactions including the cleanup; cap 0.003 ETH in total, as in the existing live-run bound.
- Expected final ledger per role after the single cleanup (step 9, run once after the last scenario): `F` back to its starting
  balance (each vendor payment +1 offsets the C2 cure -1, and every other unit returns to `F` by a plain `U.transfer` from the
  lender, root1, root2 and customer, each of which holds ETH for gas); router and pool at 0 of the test USDC. The worker's 0.5
  USDC per settled order returns to `F` by an EIP-3009 `transferWithAuthorization` signed by the worker and submitted by `F`
  (the worker holds no ETH); if the token refuses that call, the worker keeps the 0.5 and the ledger records it as a holding,
  not as a loss. Anything else left behind is a mismatch and stops the run.
- **Rehearsed versus not.** The fork rehearsal ends at the withdrawals and asserts aggregate conservation across all roles; it does
  not exercise the transfers back to `F` or the EIP-3009 return. Those are new, unrehearsed steps (plain token transfers, and one
  call the token may refuse), listed here so they are not read as rehearsed.

## Gates, in order (stop at the first that fails)

1. **G0 head.** The head named in the opening (`3efdb6f` unless Codex names another with identical `packages/`) is checked out;
   `git status` clean; `forge build` output sizes match `logs/build-sizes.txt` of the evidence packet.
2. **G1 preflight.** `cast chain-id` = 84532; record block number and hash and UTC time; Circle test USDC at
   `0x036CbD53842c5426634e7929541eC2318f3dCF7e` has code and `decimals() = 6`; the funding ledger shows the 11 USDC and the
   ETH are unearmarked holdings; no loan is open for any role address.
3. **G2 deployment.** Run the deploy script with the custodian's keystore (`--account`, `--sender`),
   `BOOTSTRAP_ORACLE` set to an address the custodian controls (no scores are used) and **no** `OFFICER` (the router starts
   with no officer, so nothing can originate yet). Record the three addresses and transaction hashes. Then `python3 scripts/verify_candidate_deployment.py --rpc <url> --pool .. --lens .. --router ..
   --json`: all three strict matches and every wiring check must pass, and the metadata-free masked-runtime hashes (`masked_nometa_sha256_*`) and the ABI sha256
   values must equal the evidence packet's `logs/verifier.json` (the full `masked_sha256_*` carries a compiler metadata hash that depends on the checkout path, so it differs between hosts); `pool.ORIGINATOR == router` and `router.officer == 0x0` are in the report. Anything
   else: stop, nothing was funded.
4. **G3 officer** (not authorized until the operator's written decision on the scope item in the opening). The router's admin (the deployer) calls `R.setOfficer(officer, 1)`. Read back `R.officer()`, `R.policyVersion()
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
6. Negative controls by `eth_call`, before any officer approval is recorded (each must revert as noted): `P.requestLoan(1e6)` from the
   worker (`NotManager`); `P.borrowAndDisburseMeta` from the submitter (`NotManager`); `R.originateOrder` with a changed vendor
   (`IntentMismatch`); **`R.originateOrder` with everything else signed and valid but no officer approval (`NoApproval`)**. The
   forged-consent control is not here: `originateOrder` reads the stored approval before it checks any root consent (router source,
   `originateOrder` then `_originateLot`), so without an approval it would revert `NoApproval` and show nothing about consents.
   It is step 6b.
6a. Officer approval. The officer signs `JobApproval(orderId, R.intentHash(intent) as in R.orders(orderId), maxAmount,
   expiry, R.policyVersion(), R.officerEpoch())`; the submitter records it with `R.approveOrder(approval, sig)`. First
   record one with `maxAmount = 1e6 - 1` and check that `R.originateOrder` by `eth_call` reverts `ApprovalTooSmall`; then
   have the officer re-sign for `maxAmount = 1e6` and record it (`approveOrder` overwrites the stored approval). Approval-field
   check, by `eth_call` of `R.approveOrder(a, sig)` where `a` is the valid approval except `policyVersion = R.policyVersion() - 1`,
   with any signature: expect `NoApproval` (the field check runs before the signature check, so this is a policy-version field check only: it does not
   by itself show the epoch check, which is shown in C3, and it shows nothing about the signature). What a later
   rotation does to an approval that is already recorded is shown only in C3, not here: `originateOrder` accepts no officer
   signature, it consumes the stored approval.
6b. Consent control, after the valid approval of 6a is recorded. By `eth_call`, `R.originateOrder` with every input valid except
   that one root's `EdgeConsent` signature is replaced by a signature over the same digest from a different key: expect
   `InvalidConsent`. The router also uses that revert name for the worker's acceptance and for the officer's signature, so the
   control is a pair: the identical call with the genuine root signature must **not** revert. Both are `eth_call`s; the
   approval is not consumed.
7. submitter: `R.originateOrder(orderId, request, poolSig, acceptSig, paths)`. Expect: vendor +1 USDC, `P.totalLentOut` +1
   USDC, `R.locked(root1) = 0.6`, `R.locked(root2) = 0.4`, `R.totalEscrowHeld() = 1.5`, `R.loanOrder(loanId) = orderId`.
   A replay must revert.
8. customer: `R.settleOrder(orderId)` within the first 24 hours (zero interest). Expect: the loan closed, the worker +0.5
   USDC, escrow 0, roots' `free` back to 1 each (the router syncs inside settlement).
9. Cleanup, **run once, after the last scenario** (after C1, or after C2 or C3 if they run; not between scenarios, which share one
   funded deployment): roots `R.withdraw` their `free`, lender `P.withdrawFunds(max)`; then each of root1, root2, lender and
   customer `U.transfer(F, balance)`; the worker's 0.5 USDC per settled order to `F` by `transferWithAuthorization` (see the
   ledger above). Final: `P.totalLentOut = 0`, `U.balanceOf(R) = 0`, `F` at its starting balance (or the worker's
   holding recorded), and the aggregate USDC across `F`, the roles, the pool and the router equal to the start. The cleanup
   adds about 6 transactions to the ETH count below.

## C2 (optional, after a clean C1): rejection, then a stranger cures

Not in the rehearsal (see above). It continues on the same deployment, **before the cleanup**: steps 1 to 3 are not repeated,
because the lender's 5 is still in the pool and the roots' 1 each is still `free` after C1's settlement. Repeat steps 4 to 7 with a
new order (a new job id; the customer funds a fresh 1.5; the worker's nonce has advanced; the officer approves the new order),
then:
customer `R.refundOrder(orderId)` (escrow returns; the loan stays); the stranger `F` approves the pool and repays
`P.repayLoan(loanId, current outstanding)` inside the first day with its own 1 USDC; anyone `R.sync(worker)`; expect `R.lossOf = 0`
for both roots and the lot back in `free`. Cleanup as in step 9.

## C3 (optional, after a clean C1; run last): officer outage

Fund a third order (the customer's fresh 1.5) and have the officer approve it; then the admin calls `R.setOfficer(officer, 2)`.
Expect by `eth_call` that `R.originateOrder` for it reverts `NoApproval` (void under the new epoch and policy), that `R.approveOrder(a, sig)` with the
officer's earlier approval and signature (signed under policy version 1 and the old epoch) also reverts `NoApproval`, and the customer's
`R.refundOrder` works at once. Then run the single cleanup (step 9) **with the officer left at version 2**: the roots' and the
lender's withdrawals succeeding in that state is the evidence that exits read no officer state. Not in the rehearsal (see above).

## Not in this packet

A **default** cannot be shown on a public chain inside a day: the shortest term is 1 day and a loan defaults 30 days after
due. The fork rehearsal (`--with-default`) shows it with a time jump, labelled as such. A public default case would hold 1 USDC
of the roots' stake for at least 31 days; it needs its own decision.

## What to publish

For every transaction: sender, nonce, hash, block, status, decoded events and fees; for every `eth_call` control: the
call and the decoded revert; the funding ledger and the aggregate before and after (integer equality); the verifier JSON
and the evidence packet's `SHA256SUMS`. Stop rules: any unexpected revert or mismatch stops the run; no retry without
reconciling the nonce (`nonces(signer)` past the request means it landed); an RPC timeout is not a refusal. Missing
observations are unknown, never zero. No claim of poverty reduction, revenue or independent demand follows from internal
transfers of test currency.
