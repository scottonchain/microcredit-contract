# Bootstrap candidate: ordered execution packet (Base Sepolia)

**Draft. Not authorization.** Nothing here may be executed until (1) Codex has accepted a named head in writing, (2) Hermes
has reproduced that exact head (`scripts/candidate_evidence.sh`, compared with the head's `SHA256SUMS`) and (3) the operator's
existing bounds hold: Base Sepolia only, test USDC only, no mainnet or real-money action, no officer grant, no mint or faucet
retry, no use of the original wallets or the live pool's funds. The packet is the same ordered call list as
`scripts/candidate_rehearsal.py run` (including the officer steps), which has passed on a fork of this chain with Circle's USDC; the fork replaces the
custodian's keystores with throwaway keys and the funding by impersonation with real transfers.

## Scope and budget

- Contracts: deploy `DeployBootstrapCandidate.s.sol` at the accepted head (pool, lens, `BootstrapOrderRouter`). The pool is
  built with the router as its immutable originator (the script predicts the router's address and checks it), so no other
  caller can originate for any borrower. The live pool at `0x7387...` is not touched.
- Roles (fresh keystores, custodian-held, never in the repository): deployer, lender, root1, root2, mid, worker, customer,
  vendor (receives USDC only), officer (its own key; signs approvals, never sends a transaction), submitter (any funded account). The worker needs no ETH and sends no transaction.
- Test USDC, per run: lender 5, root1 1, root2 1, customer 1.5. Two runs (C1, C2): 17 at most, within the 25 cap; every
  unit comes back to the funding account in the cleanup step. ETH: deployment about 13.1 million gas (0.00008 ETH at
  0.006 gwei plus the L1 data fee), then about 25 transactions; cap 0.003 ETH in total, as in the existing live-run bound.

## Gates, in order (stop at the first that fails)

1. **G0 head.** The accepted SHA is checked out; `git status` clean; `forge build` output sizes match the head's
   `logs/build-sizes.txt`.
2. **G1 preflight.** `cast chain-id` = 84532; record block number and hash and UTC time; Circle test USDC at
   `0x036CbD53842c5426634e7929541eC2318f3dCF7e` has code and `decimals() = 6`; the funding ledger shows the 17 USDC and the
   ETH are unearmarked holdings; no loan is open for any role address.
3. **G2 deployment.** Run the deploy script with the custodian's keystore (`--account`, `--sender`),
   `BOOTSTRAP_ORACLE` set to an address the custodian controls (no scores are used) and **no** `OFFICER` (the router starts
   with no officer, so nothing can originate yet). Record the three addresses and transaction hashes. Then `python3 scripts/verify_candidate_deployment.py --rpc <url> --pool .. --lens .. --router ..
   --json`: all three strict matches and every wiring check must pass, and the masked-runtime and ABI sha256 values must
   equal the head's `logs/verifier.json`; `pool.ORIGINATOR == router` and `router.officer == 0x0` are in the report. Anything
   else: stop, nothing was funded.
4. **G3 officer.** The router's admin (the deployer) calls `R.setOfficer(officer, 1)`. Read back `R.officer()`, `R.policyVersion()
   = 1` and `R.officerEpoch()`; record them. The officer key is not any of the other roles' keys.

## Ordered calls (C1: customer accepts)

Amounts in USDC base units (6 decimals). `P` pool, `R` router, `U` token.

1. lender: `U.approve(P, 5e6)`, `P.depositFunds(5e6)`.
2. (no worker transaction) Read back `P.ORIGINATOR() == R`.
3. root1, root2: `U.approve(R, 1e6)`, `R.deposit(1e6)` each.
4. customer: `U.approve(R, 1.5e6)`, then `R.fund(Intent, 1.5e6, 1.5e6, settleBy)` with `Intent = (worker, vendor, 1e6, 604800,
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
9. Cleanup: roots `R.withdraw`, lender `P.withdrawFunds(max)`, sweep the worker's and customer's USDC to the funding account.
   Final: `P.totalLentOut = 0`, `U.balanceOf(R) = 0`, aggregate USDC across roles, pool and router equal to the start.

## C2: rejection, then a stranger cures

Repeat steps 3 to 7 with a new order (a new job id; the worker's nonce has advanced), then: customer `R.refundOrder(orderId)`
(escrow returns; the loan stays); a funded stranger repays `P.repayLoan(loanId, current outstanding)` inside the first
day; anyone `R.sync(worker)`; expect `R.lossOf = 0` for both roots and the lot back in `free`. Cleanup as in step 9.

## C3: officer outage (optional, same run)

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
