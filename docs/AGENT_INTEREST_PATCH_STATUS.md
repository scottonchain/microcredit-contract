# Agent interest patch: draft, not deployment-ready

Codex (AI), October 30, 2026. Implements contract issue44 against main0e2cd727.

The draft removes the first-day zero-interest branch and requires exact debt repayment before closing. Partial payments always apply interest before principal. CENT remains for unrelated signed-quote tolerance and withdrawal queue behavior. Existing original-principal APR accrual and integer rounding are unchanged. No minimum fee, ABI change, deployment or migration is included. An existing immutable deployment does not gain this behavior from a source edit.

Five new Forge regressions cover one-hour sub-cent interest and pool/reserve accounting, one-unit underpayment and completion/credit usage, partial interest payments, the 24-hour boundary, and zero/sub-atomic interest. Test minting is fixture setup, never evidence of profitable commerce.

Validation performed here: git diff --check and public-content checks. Foundry/solc are unavailable in this executor, so no Solidity compilation or execution is claimed.

Before review or merge:
1. Run forge fmt and forge test --match-contract AgentLoanInterestTest -vv with the pinned toolchain and submodule.
2. Migrate the existing tests that intentionally assert the removed policies in AdvanceFacts.t.sol, LoanAccounting.t.sol, LoanLifecycle.t.sol and HermesPR16.t.sol. Preserve their accounting/security coverage. Do not delete or skip the old suite to obtain green checks.
3. Reconcile the independent CreditHandler invariant model, which still includes GRACE_PERIOD and sub-cent forgiveness. Run all tests and invariants; preserve CI-30 principal protection and fee/reserve conservation.
4. Update current-policy prose in CLAUDE.md, docs/ECONOMICS.md and docs/CREDIT_MODEL.md; preserve dated historical results as history. Check frontend/relayer quotes against exact payable debt. Existing cent-rounded display is not authority to forgive debt.
5. Independently review exact tested commit and report source/deployed-contract differences. No deployment/funds until separately authorized concrete transaction terms.

This packet is a partial implementation for review and completion, not a finished PR or validated contract.
