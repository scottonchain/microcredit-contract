# Agent interest change: source complete and validated, not deployed

Draft: Codex (AI), October 30, 2026, contract issue 44, against main `0e2cd727`. Completion of R1 to R4: Claude (AI), October 31, 2026, branch `claude/ctr44-agent-interest-20261031`. The commit list is `git log origin/main..HEAD`; the numbers below are for the head of the pull request that carries this file. This is a source change for review. It is not an audit, a deployment, or evidence of demand, borrowers or returns.

## The change

Interest accrues from disbursement: the 24-hour grace period and its cliff are gone. Repayment applies interest before principal and a loan closes only when its whole balance is paid; nothing is forgiven, so a payment short by even one unit leaves the loan open and holding its credit use. `CENT` remains for unrelated signed-quote tolerance in `repayLoanMeta` and for the withdrawal queue. The original-principal APR accrual and integer rounding are unchanged. No minimum fee, ABI change, deployment or migration is included. An existing immutable deployment does not gain this behavior from a source edit.

## What was completed

- R2, tests: the nine tests that asserted the removed policies are migrated, none deleted or skipped (`AdvanceFacts` x5, `HermesPR16` x1, `LoanAccounting` x2, `LoanLifecycle` x1), keeping their accounting and security coverage. The `CreditHandler` invariant model takes the three-line change and loses its dead constant; invariant I9 (no principal forgiven) holds. One new test: a permit with a cent of headroom closes the loan.
- R1, callers: a full payoff approved, permitted or passed for exactly the cent-rounded quote can fall short because interest accrues until the payment is mined. `packages/nextjs/utils/repayAmount.ts` gives the payoff amount (the quote plus headroom: at least one cent and ten minutes of interest at the 100% APR ceiling). The borrower page authorizes that amount and says so, checks the wallet against the exact balance owed, then reads the loan and shows the exact amount still owed in base units, or that closure could not be confirmed, because a mined success and `LoanRepaid` (which also fires for partial payments) do not prove closure. A typed partial amount stays the user's cap. The caller pre-review on ctr#44 (Codex, 2026-10-31) is answered in these terms. Recorded as CI-31.
- R3, prose and models: CLAUDE.md, README.md, docs/ECONOMICS.md, docs/CREDIT_MODEL.md, docs/CREDIT_INTEGRITY_ISSUES.md (CI-30 revised with its dated history kept, CI-23 noted, CI-31 new), docs/TESTNET_WALKTHROUGH.md and DEMO.md state the current rule. The three Python suites that modelled the grace period and the forgiveness (`analysis/sybil_sim`, `analysis/issuer_policy`, `analysis/credit_risk`) follow the source and were rerun with their own `run.py`; the results that changed are in the commit message of the models commit. The local demo deploy gives the demo borrower 1 USDC for interest. Dated history (TESTNET*.md, docs/reviews) is untouched.

## Validation on the head, with the pinned toolchain (forge 1.5.1, solc 0.8.33)

- `forge test`: 233 passed, 0 failed, 12 skipped (245 tests, 23 suites). Main `0e2cd727` is 227 passed, 0 failed, 12 skipped. The 12 skips are live-RPC fork tests that skip without their RPC variables; a skipped test is not a pass and nothing is claimed from them.
- Invariants: 14 of 14 pass at the configured 64 runs and 5,120 calls each. Only that depth is claimed, and it is evidence, not a proof of conservation.
- `forge fmt --check` clean. Runtime size of `DecentralizedMicrocredit` 24,150 bytes, 426 under EIP-170 (main 24,209, 367 under). Public ABI of the pool (209 entries) and the lens (9) identical to main and to `1812e7d`.
- The contract diff to main is the Codex draft only; the later commits touch contract comments and the lens comment, and runtime bytecode with the metadata tail removed is identical before and after them for both contracts.
- Python: `analysis/sybil_sim` 53 tests, `analysis/issuer_policy` 42 tests (1 skips as before), `analysis/credit_risk` 31 tests, `analysis/liquidity` 26 tests (unmodified), `scripts` 45 tests: all pass.
- App: `tsc --noEmit` clean; `eslint` clean on the whole package; `node --test` on `utils`: 56 of 56.
- `scripts/check-public-content.sh` on each staged diff and on `origin/main..HEAD`: exit 0; noreply author and committer on every commit.
- The local deploy script ran on a scratch Anvil and the demo borrower holds 1,000,000 base units afterwards.

## Source versus deployed (R4)

- The live pool is `0x73872B8fB7F1771C67911f03edc75aBdc9514973` on Base Sepolia (84532), recorded in `docs/TESTNET.md` and the testbed descriptor `deployments/current.json` as built from `1812e7d` (2026-10-06). On 2026-10-31 I read its on-chain runtime code through the public Base Sepolia RPC: 24,377 bytes. It equals the runtime code of a local build of `1812e7d` with the 11 immutable ranges zeroed and the metadata tail removed (24,324 bytes compared byte for byte). The metadata tails differ and I did not explain why (a different build path or environment is the likely cause, not verified). I did not read the other recorded pools (the mock-token pools of 2026-10-03).
- That deployed source predates both this change and the CI-30 fix of 2026-10-08. Its rule: a 24-hour grace period; `_repay` closes a loan when `owed - paid < CENT` and forgives that rest even when it is principal, debiting the reserve; `repayLoanMeta` closes a sub-cent balance without a transfer. Main `0e2cd727` has the CI-30 rule (a loan closes short only on interest) and still has the grace period. This branch has neither.
- Consequence: no deployed pool changes behavior because of this source. A pool with the new rule needs a new immutable deployment, funding and a granted credit line, none of which exists or is authorized here. The ABI is unchanged, so a new deployment would not change the app's generated ABI file.

## Not claimed

No Solidity audit, no proof of conservation beyond the configured fuzz depth, no review of the other deployed pools. The app change is type-checked, linted and unit tested at the helper and the outcome decision; it was not run in a browser against a wallet or a chain, and the full local browser demo was not run. No demand, borrower, price, return or human benefit is established, and test minting supplies fixtures, not economic evidence.
