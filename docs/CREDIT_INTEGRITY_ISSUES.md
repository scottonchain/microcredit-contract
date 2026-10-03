# Credit integrity issues

Tracking for Sybil attacks and every other way credit could be created, lost or misattributed.
Keep this file current: add an entry as soon as an issue is reported, and close an entry only with
the fixing commit and the regression test that proves it.

## The invariant

**Credit cannot be manufactured.** An account can borrow only against credit it already holds or
credit that someone who holds credit commits to it from their own. Credit comes from exactly two
sources:

- **Granted credit:** the account's credit score (admin override, or published by the oracle
  through `IScoreProvider`) × `maxLoanAmount`, less `creditLoss`. This is the only unsecured
  credit, and only the owner or the oracle can create it.
- **Stake:** USDC the account locks in the contract (`stake`). Secured.

Backing (`back` / `backMeta`) moves credit from a backer to a borrower. The backer's free granted
credit is committed first, then free stake, and the backer's own capacity falls by exactly what
the borrower gains. An account with no granted credit and no stake can neither borrow nor back,
so a ring of fresh accounts has zero capacity however they vouch for each other.

If a backed borrower defaults, the backers pay first: committed stake is slashed back into the pool
and committed credit is burned from the backer's granted credit (`creditLoss`), so a guarantor
cannot back the same loss twice.

## Open issues

| ID | Issue | Source | Status |
| --- | --- | --- | --- |
| CI-4 | In the demo video Brighton already has credit, from previous activity or because an institution gave it to him; it is not money he staked, and Avery's attestation should not be what creates it. Until now every deploy script gave Brighton no credit of his own, so his whole limit came from Avery's attestation at no cost to her (the CI-1 path). | User, 2026-10-03 (LinkedIn video) | **Fixed in the model and the demo:** Brighton now starts with a 25 USDC granted line (score override standing in for history or an institution) and Avery backs him with 50 USDC of her own credit, which leaves her limit. Still to do: step through the video itself, which is blocked until `dms.licdn.com` is allowed in the environment's network settings. |
| CI-5 | Repayment history does not raise a limit. Credit earned from history is granted credit: it must come from the oracle's or an institution's grant (which can read `completedLoans`), never be created automatically on-chain. | Hermes on #3: round 1 item 5; user, 2026-10-03 | Open (oracle policy and the CRE workflow) |
| CI-6 | Unsecured credit exists only where the owner or oracle grants it, so their keys and the provider are the trust root. | Design consequence of the invariant | Open: Ownable2Step, timelock and bounds on overrides and provider changes |
| CI-7 | No first-loss reserve: unsecured backing defaults fall on lenders immediately. | Hermes on #3: round 2 item 3 | Open |
| CI-8 | No invariant tests for conservation: total capacity ≤ Σ granted + Σ stake; lender claims ≤ `totalAssets`; a default plus a run never lets the first exiter take more than pro rata. | Hermes on #3: round 2 item 5 | Open |
| CI-9 | Lenders cannot see what they can withdraw (`maxWithdrawable`) or the pool's utilisation and realised yield. | Hermes on #3: round 1 items 2 and 6, round 2 item 4 | Open |
| CI-10 | `getCurrentOutstandingAmount` reverts for closed loans; views should return 0. | Hermes on #3: round 1 item 4 | Open |

## Closed issues

| ID | Issue | Source | Fix | Regression test |
| --- | --- | --- | --- | --- |
| CI-1 | Sybil ring manufactured credit: fresh accounts vouching for each other (plus all for one beneficiary) reached high scores and borrowed with nothing behind them, out-borrowing honest users. Earlier mitigations (stake per vouch, anchored PageRank, first-loan cap) only made this harder, because graph topology still turned vouches into credit. | Hermes on #3: persona walkthrough item 1, Base Sepolia item 1, multi-persona round 1 item 1; user directive 2026-10-03 | Credit-conservation redesign: backing (`back` / `backMeta`) moves the backer's own granted credit or stake; vouches carry no credit; on-chain PageRank removed | `SybilResistance.t.sol`: `testRingOfFreshAccountsCannotBackOrBorrow`, `testStakedRingBorrowsNoMoreThanItsStakeAndLendersLoseNothing`, `testRingCannotMultiplyOneMembersCredit` |
| CI-2 | An attester with no history and nothing at stake passed weight to a borrower. | Hermes on #3: persona 6, Base Sepolia item 2 | Same redesign: backing needs the backer's own free credit or stake (`InsufficientCredit`); received backing cannot be passed on | `testRingOfFreshAccountsCannotBackOrBorrow`, `testReceivedBackingCannotBePassedOn` |
| CI-3 | Vouching cost the voucher nothing. | Hermes on #3: round 1 item 7 | Same redesign: backing lowers the backer's limit by the same amount, and the backer pays on default (stake slashed, credit burned via `creditLoss`) | `testBackingMovesCreditItDoesNotCopyIt`, `LoanLifecycle.t.sol` default tests |
| CI-15 | Credit a backer has lost (lower score, a default, a charge) kept backing others. | Found during the redesign | `_backingReceived` counts unsecured backing only as far as the backer's remaining credit covers its commitments | `testLostCreditStopsBackingOthers`, `testDefaulterLosesTheCreditItGaveOthers` |
| CI-16 | Releasing a defaulter's remaining backing while it still has other open loans would leave those loans unbacked. | Found during the redesign | `_chargeBackers` releases the rest only once the borrower has no open loans | `testDefaultKeepsBackingForTheBorrowersOtherOpenLoans` |
| CI-11 | No default state: an unpaid loan stayed active forever and nothing was written down. | Hermes on #3: persona 4, round 2 | f263165: `markDefaulted` after `LATE_PERIOD` writes off unpaid principal and blocks the borrower | `LoanLifecycle.t.sol` |
| CI-12 | Lenders never earned interest, losses were not socialised, and exit order decided who took losses. | Hermes on #3: personas 2 and 3, round 2 item 1 | b5dd2db: non-transferable shares, cash-basis interest, buffer gates loans only | `ShareAccounting.t.sol` |
| CI-13 | Reverts were bare strings (`Score > 0`) with no plain-language explanation. | Hermes on #3: persona 5, round 1 item 3 | f263165: custom errors plus `utils/contractErrors.ts` | `next:check-types` enforces a message per error |
| CI-14 | Trust ranking ran on-chain (O(n²) per attestation) instead of behind a swappable oracle. | User constraint relayed by Hermes on #3 | On-chain PageRank removed; scores come from overrides or `OracleScoreProvider` (Chainlink CRE `onReport` or reporter) and only ever grant credit, never propagate it | `OracleScoreProvider.t.sol` |
