# Economics

Who pays whom, what each party earns and risks, and how to set the parameters. The proofs behind
the credit rules are in [`CREDIT_MODEL.md`](CREDIT_MODEL.md); the numbers come from
[`analysis/credit_risk`](../analysis/credit_risk/README.md).

## Flows

Every loan's APR is fixed at origination: `effrRate` + `riskPremium`. Interest is simple, starts
24 hours after disbursement, and is settled before principal on every repayment. Each interest
payment `I` splits three ways:

| Share | Goes to | Purpose |
| --- | --- | --- |
| `protocolFeeBps` × I (max 20%) | `protocolFees`, claimable by the owner | operator revenue |
| `reserveBps` × I (max 80%) | `firstLossReserve`, a junior claim inside the pool; also credited to the borrower as `duesPaid` | absorbs defaults and provisions before the share price; backs the borrower's earned credit |
| the rest | `lenderCash`, so the share price rises | lenders' return |

Principal repaid returns to `lenderCash`. A default writes off unpaid principal and charges it in
this order: secured backing (stake slashed into the pool), unsecured backing (backers' granted
credit burned, which recovers no cash), the first-loss reserve, then lenders through the share
price. A loan past its due date can be provisioned at once (`impairLoan`), with the reserve
absorbing the provision first.

## What each party earns and risks

| Party | Earns | Risks |
| --- | --- | --- |
| Lender | utilisation × APR × (1 − fee − reserve share), less losses beyond the reserve | defaults on issued lines (dues-funded credit never costs lenders: `CREDIT_MODEL.md`, corollary to Theorem 2) |
| Borrower | a loan without collateral, and earned credit equal to the reserve share of the interest it pays | its own credit, earned credit and any stake, all forfeited on default; no further borrowing or backing |
| Backer (unsecured) | nothing on-chain; the borrower's goodwill | the credit it commits, burned pro rata on default |
| Backer (secured) | nothing on-chain | the stake it commits, slashed pro rata on default |
| Issuer (oracle, institution) | whatever it charges off-chain | its reputation; with CI-17, its capital; it can lend at most its budget against its lines |
| Reserve funder (`fundReserve`) | nothing on-chain | its capital, which absorbs losses before lenders and is never returned to it |

## Expected lender return

With utilisation $u$, APR $a$, fee share $f$, reserve share $r$ and an annual loss rate $L$ on lent
principal,

$$\mathrm{APY} \approx u\,a\,(1-f-r) + \text{(reserve released)} - \max\big(0,\ uL - \text{(reserve inflow)}\big).$$

A reserve funded from lenders' own interest does not raise their expected return; it smooths it,
up to the share that covers expected loss. Interest-funded reserve is never released
(`releaseReserve` keeps all dues), so over a long horizon lenders' expected APY is

$$u\,\big(a(1-f) - \max\{L,\ a\,r\}\big),$$

which equals $u\,(a(1-f) - L)$ only while $r \le L/a$. Above that share every further point of $r$
costs lenders $u\,a$ a year for good, because the excess accumulates in a balance they cannot
receive (pricing paper, Theorem 2). External first-loss capital (`fundReserve`) does raise their
return: it can be released above all dues ever paid.

`MicrocreditLens.getFundingPoolAPY()` shows $u\,a\,(1-f-r)$: the projected return before default losses, net of
the fee and the reserve share.

## Setting the premium

The premium must cover expected loss plus a return on the capital that unexpected loss ties up.
At the Basel other-retail correlation and a 15% hurdle (one-factor Vasicek model, LGD 100% on
unsecured principal, 30-day loans re-lent through the year):

| Annual PD of the book | Per 30-day loan | Break-even premium | Recommended `riskPremium` | Recommended `reserveBps` |
| --- | --- | --- | --- | --- |
| 3% | 0.25% | 467 bps | 600 bps | 5,500 |
| 5% | 0.42% | 677 bps | 800 bps | 6,500 |
| 10% | 0.86% | 1,201 bps | 1,400 bps | 7,500 |

Two cautions from the calibration:

- **Price per year, measure per loan.** A 1% default rate per 30-day loan is an 11.5% annual PD;
  a "97% repayment rate" per loan is 31% a year.
- **One premium for every loan.** The contract charges the same premium on every loan, so it
  must be set for the riskiest band the issuer admits, or admission must keep the book in the
  band that was priced. Stake-secured principal carries no loss given default but pays the same
  premium (CI-18).

The local demo deploys 500 bps and a 30% reserve share (expected loss at 3% annual PD). The
production script defaults to 800 bps and 4,500 bps (`docs/DEPLOYMENT.md`).

## The reserve share

The `reserveBps` column above assumes the surplus over a cap is released to lenders, which the
contract does not do. With the lock, at PD 5%, a 12.33% APR and utilisation 85%, the long-run
expected APY above is 6.10% at the expected-loss share (41.8%), 5.76% at 45%, and 3.67% at 65%,
against the 4.33% funding rate. The reserve share also sets how fast a repaying borrower earns
credit (the same share of its interest becomes its dues), and how much risk lenders bear before the
reserve has built up. Raising it raises the loan rate lenders need, which lowers the loan volume
borrowers demand. The owner set the default to 4,500 on 2026-10-05 as an interim value. The final
value is to follow a reviewed equilibrium analysis (loan demand, lender supply, the reserve share
and pool liquidity) and other considerations, and until then it does not change (CI-29).

## Liquidity

New loans may use at most `lendingUtilizationCap` (90%) of `totalAssets` and must leave
`liquidityBuffer` (5%) plus queued withdrawals in cash; withdrawals and the queue may use the
buffer. `MicrocreditLens.maxWithdrawable(lender)` is what a lender can take now; larger requests join a FIFO
queue paid as loans are repaid, and queued shares keep earning until paid.
