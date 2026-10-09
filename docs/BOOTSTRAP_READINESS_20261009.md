# Bootstrap readiness for the October 9 sync

Prepared by Codex / ChatGPT (AI), October 8, 2026. The delivery deadline is
**October 9, 2026, 10:00 UTC (04:00 America/Denver)**. The operator directs the
team to agree, implement and continue until the contract is ready, with evidence.
[Delivery instruction and owner split](https://github.com/scottonchain/microcredit-agent-testbed/issues/17#issuecomment-6059757413).

Planning remains in the testbed's canonical world model. This document is the
contract acceptance specification, not a replacement planning database. Basis:
testbed `115bfb04a6a5fa4e17d2a25ca2dc59a3a20b78df` (model v0.1.83), contract
`9f5c1434a1fa99bec7939bbf458f86ddee55bec9`.

> **Status at the repaired candidate head.** The numbers and the open gate in the next section describe the first packet at
> contract main `9f5c143` (historical; they are not evidence for the candidate). Since then: the atomic settlement
> adapter and the roots' two-hop stake are one manager, `BootstrapOrderRouter` (`BOOTSTRAP_ORDER_ROUTER.md`), with debt-first
> settlement, rejection and default tests, and a shared root-to-mid budget; the candidate's evidence is pinned to one
> head in `evidence/bootstrap-candidate-<head>/` and `CANDIDATE_VERIFICATION.md`. This document stays the acceptance
> specification; the gates below are checked against that directory, not against the older figures.

## What this first test packet establishes

`test/BootstrapReadiness.t.sol` adds integrated tests of the existing pool using
5 USDC of lender liquidity, 1 USDC of sponsor stake and 1.5 USDC of prefunded
test-customer money. The borrower has no granted credit, ETH or USDC. There are
no mints after setup, including when the order fails. All 7.5 USDC remain
attributed across participants and pool throughout each test.

Nine focused tests passed with Forge 1.8.5 and Solidity 0.8.33. The full Forge
suite passed **220 tests, with 12 public-fork tests skipped** and zero failures (at `9f5c143`, historical).
The new sub-cent principal test fails as expected against deployed source
`1812e7d`, so it distinguishes the old defect from the corrected candidate.
Focused test logs, the full-suite summary, build settings and checksums are in
[`evidence/bootstrap-readiness-20261008`](../evidence/bootstrap-readiness-20261008/).
These are local EVM tests with a synthetic clock and MockUSDC, not Base Sepolia execution.

| Scenario | Observed behavior |
| --- | --- |
| First-day 0.20 USDC vendor advance against a 0.50 USDC test order | Signed vendor receives 0.20; customer repays 0.20; worker receives 0.30; lender and sponsor fully exit; no interest or earned credit is invented. |
| Same advance over seven synthetic days | Interest 357 base units; lender gross return 196; protected reserve 160; share-rounding remainder 1; worker receives 299,643. Gas and default costs are not included in this modelled return. |
| Rejected order with no customer payment or operator cure | Sponsor loses 0.20; lender exits with 5; customer retains its budget; default remains recorded. |
| Shared stake and two outstanding loans | Same root cannot allocate its committed stake to a second borrower; after only one loan repays, backing and stake remain locked. |
| Sub-cent partial principal | Repaying one unit of a 9,999-unit loan leaves 9,998 owed and the backing locked. |
| Cancellation | Undisbursed reservation and borrower capacity are restored without paying the vendor. |
| Signature substitution and origination replay | Changed vendor is rejected; nonce replay creates no second loan/payment. |
| Repeated pool repayment after close | No second customer debit. This does not prove an external escrow cannot double-release worker proceeds. |
| Attempted onward backing | Rejected: received backing is not transitive in the current contract. |

The test customer's debt-first payment and worker payout are separate voluntary
calls orchestrated by the test. **They do not implement an atomic settlement
adapter or establish customer consent outside the fixture.** This is an explicit
remaining engineering gate, not a completed escrow result. `vm.prank(relayer)`
proves the borrower need not be the transaction caller; public relayer operation,
gas payment and crash recovery need actual execution evidence.

## Release acceptance gates

Readiness requires a pinned release candidate, passing relevant tests and an
independent internal check. A passing source suite is not a deployed release.

| Gate | Required evidence | Responsible lane |
| --- | --- | --- |
| Source and build | Exact reviewed commit, compiler/settings, runtime/ABI hashes and bytecode-size check; corrected CI-30 behavior on the candidate | Claude authors/integrates; Codex verifies |
| Fresh bootstrap | Separate deposited liquidity and secured sponsor backing; zero-grant borrower; exact lender, sponsor, borrower and vendor balances | Codex tests; Hermes executes |
| Controlled settlement | Test payer funds and consents to an exact order, worker, pool/loan and recipient. Atomic or otherwise enforceable debt-first payment; residual worker payout; source attribution; bounded late interest; rejection/refund/cancellation semantics | Claude implements; Codex adversarial tests |
| Settlement negative cases | Unauthorized payer/worker/recipient changes; wrong pool, token, chain or loan; duplicate order/settlement; closed/defaulted/partially repaid loan; insufficient order balance; stale deadline/nonce; reentrancy or failed token transfer; no premature worker release | Codex review; Claude corrections |
| Loss and accounting | Shared roots, simultaneous loans, partial repayments, sub-cent principal, cancellation, stake exit, rejected job without synthetic cure and matured default; supply/assets/reserve/fees/rounding all reconciled | Codex tests; Claude proof; Hermes fork receipts |
| Gas and retry | Public testnet transaction from borrower starting without ETH via funded relayer or supported paymaster; payer and cost recorded; same signed intent survives crash/timeout without double send | Claude packet; Hermes execution; Codex reconciliation |
| Transitive target | Consented stake-rooted paths, global reservations and no double-counted root/edge capacity; conservation/default proof and diamonds/cycles/aliases/concurrent/partial/rounding/legacy fixtures; actual implementation status | Claude proof/code; Codex review; Hermes rehearsal |
| Operational candidate | Circle USDC on Base Sepolia, exact candidate addresses, creation receipts and runtime fingerprints, successful lifecycle, exits, safe retry and rollback instructions | Hermes executes reviewed packet; Codex checks |
| Evidence package | Reproducible commands, raw logs, receipts, block numbers, starting/ending balances, funding provenance, checksums, limitations and exact gate verdicts | All lanes; Codex reconciles |

For controlled settlement, a pool method accepting third-party repayment is a
capability, not an assignment of the customer's proceeds. Customer/escrow consent
must bind the actual debt-first route. A paymaster or successful relay does not
provide that consent. Order rejection must not quietly erase an already-disbursed
loan: specify who bears the input loss and how refund and default interact.

The current one-hop path is useful first-stage evidence, but it cannot satisfy
the required officer-free transitive target. Preserve this distinction in the
final verdict. Do not manufacture a fee, repayment, third-party order or credit
score to turn a failed gate green.

Optional AML controls remain off. A control that only delays rotating backing
to a different borrower must not be described as a global throughput bound.
Global originated-principal bounds must also count repeated loans to the same
borrower. This design issue is not a reason to stop the other readiness work.

## Execution and recovery boundaries

Keep the existing public-app pool and its three pending live communities and
source-5 restoration separate. Use an isolated candidate deployment for changed
bytecode; do not repoint or alter the original pool. Private keys remain with
their custodian. Original root-signed bytes remain email-only under the existing
procedure. A channel outage is not permission to publish them.

Testnet receipts prove mechanics, and fork time travel proves only labelled
synthetic lifecycle cases. Customer demand, consenting outside borrower,
unavoidable paid-input gap, positive all-in economics and real settlement remain
separate admission requirements. An absent qualifying order stops that loan;
it does not stop contract implementation or testing.

The proposed engineering checkpoints are Oct 8 14:00 UTC for architecture and
assent, 18:00 for candidate/proof, 22:00 for review; Oct 9 06:00 for execution,
08:00 for reconciliation, and 10:00 for the sync verdict. Actual assents and
outcomes belong in the canonical model. Repair continues if a gate fails; the
deadline itself cannot confer readiness.

## Reproduce this source packet

From a clean checkout, initialize the pinned submodules, then run:
