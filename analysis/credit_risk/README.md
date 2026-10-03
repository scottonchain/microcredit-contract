# Credit-risk calibration of the DecentralizedMicrocredit pool

A one-factor (ASRF / Vasicek) calibration of the annual loss rate of the collateral-free USDC
pool in `packages/foundry/contracts/DecentralizedMicrocredit.sol`, with a finite-pool Monte Carlo
check. The calibration is then used to price the risk premium, size the planned first-loss
reserve (`reserveBps`), and quantify the stale-share-price run problem. No parameter is estimated
from data, because the pool has no default history. PD and asset correlation are scenario
inputs, and every result below is conditional on them.

## Bottom line

1. **The deployed `riskPremium` of 500 bps (APR 9.33%) is adequate only for annual PD ≲ 3%.**
   To break even on EL + 15% × UL(99.9%) at the Basel II other-retail correlation, annual PD can
   be at most **3.30%**, which is **0.28% per 30-day loan**. Counting the cash drag of a pool
   that is 85% lent, the limit falls to **2.60%**. At ρ = 0.15 the two limits are 2.39% and
   1.94%. At annual PD 5%, 500 bps covers EL and nothing more. At PD 10%, lenders' expected
   APY is **−0.57%**.
2. **Recommended `riskPremium` for annual PD 3 / 5 / 10%: 600 / 800 / 1,400 bps** (APR
   10.33 / 12.33 / 18.33%). These rest on Basel ρ, a 15% hurdle on 99.9% capital, 85%
   utilisation, no protocol fee, losses in a pool that re-lends after write-offs, a 500-loan
   granularity add-on, and rounding up to 50 bps. At ρ = 0.15 the figures are 750 / 1,100 /
   1,950 bps. The contract has one `riskPremium` for every loan, so it must be set for the
   riskiest PD band admitted, or admission must be gated so that the book stays in the band
   that was priced.
3. **Recommended `reserveBps` for PD 3 / 5 / 10%: 5,500 / 6,500 / 7,500** (55 / 65 / 75% of
   repaid interest, at the recommended APRs). Cap the reserve at u·(L99 − EL) = **5.8 / 6.5 / 7.9%
   of deposits** and release any surplus above the cap to lenders. Each share covers EL every
   year and builds the 99% unexpected-loss buffer in about three years. The probability that
   lenders take any loss in a year falls from **9.5–13%** in year 1 to **1.2–1.7%** in year 3
   and **≈0.3–0.5%** in steady state (independent years, ASRF). The shares are large because EL
   alone is 29 / 41 / 55% of interest at these APRs, so the minimum that absorbs an average
   year's defaults is **≥ 2,900 / 4,100 / 5,500 bps**. A reserve funded from lenders' own
   interest **cannot raise their expected return**. It re-times losses and keeps the share
   price steady. If it sits in idle USDC it costs 0.36–0.56% APY, so hold it as a junior claim
   on the pool.
4. **Book an impairment at the due date.** Today an overdue loan is carried at par until
   `markDefaulted`, 30 days after it is due. A lender holding share w who exits in that window
   takes w·X more than pro rata out of an overdue exposure X (§8).
5. **Measure PD per loan, but price it per year.** A 1% default rate per 30-day loan is an
   annual obligor PD of 11.5%, or 12.2 defaults per 100 exposure-years once defaulters are
   replaced. A 3% per-loan rate, which still looks like a "97% repayment rate", is 31% a year.

## Reproduce

```bash
cd analysis/credit_risk
python3 -m unittest -v test_vasicek   # 31 tests, ~2 s
python3 run.py                        # ~25 s: results/*.csv, results/summary.md, figures/*.png
```

The run used Python 3.11.15, numpy 2.4.6, scipy 1.17.1 and matplotlib 3.11.2. Every Monte Carlo
draw is seeded from `BASE_SEED = 20261003` and a fixed tag per experiment (PCG64 via
`SeedSequence`), and two consecutive runs gave byte-identical CSVs. `results/summary.md` holds
every table below, plus a few more.

## 1. Contract economics used

| Item | Value | Source in the contract | Used as |
|---|---|---|---|
| APR | `effrRate + riskPremium` = 433 + 500 bps = 9.33%, fixed at origination | `_originateLoan`, `Deploy.s.sol` | funding cost EFFR passed through; premium s = APR − EFFR |
| Interest | simple, on original principal, `principal × APR × elapsed / 365 days`; 0 if repaid within 24 h, otherwise the full elapsed time | `_interestAccrued`, `GRACE_PERIOD` | income u·APR per year (non-compounded) |
| Recognition | cash basis: interest settles first on repayment, and unpaid interest is never booked | `_repay` | a write-off removes principal only |
| Term | `DEFAULT_LOAN_TERM` 30 days; 1–365 days via `borrowAndDisburseMeta` | constants | n = 365/30 = 12.17 loans per exposure-year |
| Default | `markDefaulted` once `disbursedAt + term + LATE_PERIOD` (30 days) has passed; the loan can never be repaid after that (`_repayableLoan` requires `Active`) | `markDefaulted` | LGD 100% on the unsecured principal; ~60-day lag from disbursement to loss |
| Secured backing | committed stake slashed pro rata into `lenderCash` at default | `_chargeBackers` | LGD 0 on the stake-secured share |
| Unsecured backing | backer's granted credit burned via `creditLoss`; **no cash recovered** | `_chargeBackers` | LGD unchanged (100%); modelled only as a PD effect |
| Protocol fee | `protocolFeeBps` 0 by default, max 20% of repaid interest | `setProtocolFeeBps` | f |
| Utilisation | cap 90% of `totalAssets`; 5% liquidity buffer | constructor | u = 85% base, 90% sensitivity |
| Lender claim | non-transferable shares; `totalAssets = lenderCash + totalLentOut` (loans at par until written off) | `totalAssets`, `convertToAssets` | losses and stale prices pass through the share price |
| Pool size | 10,000 USDC seed; `maxLoanAmount` 100 USDC at score 100% | `Deploy.s.sol` | at 100 USDC per loan and 90% utilisation, a 10,000 USDC pool holds ≥ 90 loans, so N = 100–500 is the relevant range. The local deploy's two background loans (8,899 USDC to Diana and Eve, with `maxLoanAmount` raised temporarily) are a demo fixture, not a portfolio |

## 2. Model

### 2.1 PD horizon: per-loan versus annual

`p_T` is the probability that a loan of term T days is never repaid and is eventually marked
defaulted. **PD**, written without a subscript, is the annual obligor PD: the probability that a
borrower who keeps rolling loans defaults within a year. That is the Basel horizon, and every
grid value below is an annual PD.

**Assumption H (constant hazard).** Conditional on the systematic factor, each of a borrower's
successive loans defaults with the same probability, independently of the earlier ones. The
default time is then exponential with intensity λ = −ln(1 − PD), and

```
PD = 1 − (1 − p_T)^(365/T)        p_T = 1 − (1 − PD)^(T/365)
```

H ignores two effects that pull in opposite directions. Seasoning lowers risk, because borrowers
who have repaid are selected safer. Strategic default on the last loan raises it, because the
value of future access falls. Neither can be estimated without data.

| annual PD | per-30d-loan PD | hazard λ | defaults per exposure-year if replaced (n·p) |
|---|---:|---:|---:|
| 1% | 0.083% | 1.01% | 1.00% |
| 3% | 0.250% | 3.05% | 3.04% |
| 5% | 0.421% | 5.13% | 5.12% |
| 10% | 0.862% | 10.54% | 10.49% |
| 20% | 1.817% | 22.31% | 22.11% |

| per-30d-loan PD | annual PD | defaults per exposure-year if replaced |
|---|---:|---:|
| 0.25% | 3.0% | 3.0% |
| 0.50% | 5.9% | 6.1% |
| 1.00% | 11.5% | 12.2% |
| 2.00% | 21.8% | 24.3% |
| 3.00% | 31.0% | 36.5% |
| 5.00% | 46.4% | 60.8% |

`results/pd_annual_to_loan.csv` adds 7-, 90- and 365-day terms. Under H, expected defaults per
exposure-year, (365/T)·p_T, lie between PD (T = 365 days) and λ (T → 0) for every term: 5.00–5.13%
at PD 5%. One APR for all terms is therefore consistent in EL to first order. It is not
consistent in information lag (§8).

### 2.2 Asymptotic single risk factor (Vasicek 2002; Gordy 2003)

Obligor i defaults within the year if `√ρ Z + √(1−ρ) ε_i < Φ⁻¹(PD)`, with Z and the ε_i
i.i.d. N(0,1). Conditional on Z, defaults are independent with probability
`p(Z) = Φ((Φ⁻¹(PD) − √ρ Z)/√(1−ρ))`. In an infinitely granular pool the default rate converges
to `D = p(Z)`, and the loss rate per unit of exposure is `L = LGD·D`. Gordy (2003) shows that
capital charges depending only on each loan's own characteristics (portfolio invariance) agree
with a portfolio VaR target only in this asymptotic single-factor setting. Closed forms implemented and unit-tested in
`vasicek.py`, with c = Φ⁻¹(PD) and Φ₂ the bivariate normal CDF:

```
EL     = PD · LGD                                    (E[D] = PD exactly)
L_q    = LGD · Φ((c + √ρ Φ⁻¹(q)) / √(1−ρ))           (Vasicek quantile)
UL_q   = L_q − EL       UL_99.9 = Basel IRB K for retail (BCBS 2005), without the 1.06 scaling factor
Var D  = Φ₂(c, c; ρ) − PD²
ES_q   = LGD · [PD − Φ₂(c, Φ⁻¹(q); −√ρ)] / (1 − q)
E[(D−k)⁺] = PD − Φ₂(c, y_k; −√ρ) − k(1 − Φ(y_k)),   y_k = (√(1−ρ) Φ⁻¹(k) − c)/√ρ
```

The last line is the stop-loss transform, used for the reserve and lender-APY expectations.

**Correlation.** The Basel II other-retail correlation (BCBS 2006, paras 328–330; BCBS 2005) is
`ρ = 0.03·w + 0.16·(1 − w)`, with `w = (1 − e^(−35·PD))/(1 − e^(−35))`. It equals 0.16 as
PD → 0 and 0.03 at PD = 1, and gives 0.1216 / 0.0755 / 0.0526 / 0.0339 / 0.0301 at PD
1 / 3 / 5 / 10 / 20%. That formula was calibrated on bank retail books. A small DeFi pool whose
borrowers share a community, a region or crypto-linked income is plausibly more correlated, so
every result is also given on the grid ρ ∈ {0.02, 0.05, 0.10, 0.15, 0.20, 0.30}. Basel's
qualifying-revolving correlation, 0.04, falls inside that grid.

**LGD.** LGD is 100% on unsecured principal. A defaulted loan cannot be repaid, there is no
collateral and no collection process, and because interest is booked on a cash basis the
write-off is principal only. LGD is 0% on stake-secured principal: USDC stake is slashed into
`lenderCash` at `markDefaulted`, and the time value of the 60-day lag is ignored. EAD is the
principal of a bullet loan. Partial repayments go to interest first, so they reduce EAD late.

### 2.3 Static versus replenished pool

The Basel view is static: the obligors present at the start of the year are followed, and
defaulters are not replaced. This pool re-lends a slot once its defaulted loan is written off.
Conditional on Z, expected defaults per exposure-year become `n·(1 − (1 − p(Z))^(1/n))`. That
is at least p(Z), and it tends to −ln(1 − p(Z)) as n → ∞. The map is increasing in Z, so
quantiles transform exactly (`replenished_loss_quantile`). The effect is small at the mean
(5.12% versus 5.00% at PD 5%) and material in the tail: q99.9 is 18.3% versus 16.8% at PD 5%,
and 46.6% versus 37.8% at PD 20%. A revolving Monte Carlo (`simulate_revolving_year`: 500
slots, 12 terms, a one-term write-off lag, and the factor fixed for the year) reproduces both
views:

| PD | static MC mean | static MC q99.9 | ASRF+GA q99.9 | replenished MC mean | replenished MC q99.9 | replenished ASRF q99.9 |
|---|---:|---:|---:|---:|---:|---:|
| 3% | 3.00% | 14.8% | 14.7% | 3.05% | 15.6% | 15.2% |
| 5% | 5.00% | 17.6% | 17.5% | 5.12% | 18.8% | 18.3% |
| 10% | 10.00% | 24.4% | 24.4% | 10.46% | 26.8% | 26.4% |

The headline tables use the static ASRF (the standard, citable object). The premium
recommendation uses the replenished distribution, which is the more conservative one.

### 2.4 Finite pools: Monte Carlo and granularity

`montecarlo.simulate_loss_rates` draws Z, then the number of defaults as
Binomial(N, p(Z)). For equal exposures this is the copula exactly, not an approximation, and
`simulate_loss_rates_bruteforce` confirms it by thresholding every obligor's latent variable
(`results/mc_bruteforce_check.csv`: means, standard deviations and q99 agree within their 95%
CIs). With 10⁶ scenarios per cell, quantile CIs come from order statistics (distribution-free).
The analytic comparison is the first-order granularity adjustment (GA) of Martin and Wilde
(2002) and Gordy (2004) (see also Gordy and Lütkebohmert 2013):
`GA = −(1/2h(y)) d/dy[h(y)σ²(y)/μ′(y)]` at y = Φ⁻¹(q), with
`σ²(y) = LGD²·μ̃(1−μ̃)/N`. The closed form is in `granularity_adjustment`, and a unit test
checks it against a numerical derivative.

99.9% loss quantile at the Basel ρ (1,000,000 scenarios):

| PD | N | ASRF | ASRF + GA | Monte Carlo [95% CI] |
|---|---:|---:|---:|---:|
| 3% | 100 | 14.2% | 17.0% | 17.0% [17.0, 17.0] |
| 3% | 500 | 14.2% | 14.7% | 14.6% [14.6, 14.8] |
| 3% | 5,000 | 14.2% | 14.2% | 14.2% [14.1, 14.3] |
| 5% | 100 | 16.8% | 20.4% | 20.0% [20.0, 20.0] |
| 5% | 500 | 16.8% | 17.5% | 17.6% [17.4, 17.6] |
| 5% | 5,000 | 16.8% | 16.9% | 16.8% [16.7, 16.9] |
| 10% | 100 | 23.4% | 28.2% | 28.0% [27.0, 28.0] |
| 10% | 500 | 23.4% | 24.4% | 24.2% [24.2, 24.4] |
| 10% | 5,000 | 23.4% | 23.5% | 23.6% [23.4, 23.6] |

With N = 100, losses come in steps of 1%, so a CI can collapse onto one lattice point. A pool of
about 100 loans (10,000 USDC lent in 100 USDC loans) has a 99.9% tail **14–20% above the ASRF
value**. At
N = 500 the gap is 3–5%, and at 5,000 it is negligible. Simulated standard deviations match the
exact finite-N value `Var D + (PD − Φ₂(c,c;ρ))/N` to within 0.01 percentage point (`results/mc_granularity.csv`,
`figures/granularity.png`).

## 3. Loss distribution (LGD 100%)

At the Basel ρ:

| PD | ρ | EL | sd | q99 | q99.5 | q99.9 | UL99.9 = K | ES99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1% | 0.1216 | 1.0% | 1.1% | 5.3% | 6.4% | 9.1% | 8.1% | 11.1% |
| 3% | 0.0755 | 3.0% | 2.0% | 9.8% | 11.1% | 14.2% | 11.2% | 16.1% |
| 5% | 0.0526 | 5.0% | 2.4% | 12.7% | 13.9% | 16.8% | 11.8% | 18.5% |
| 10% | 0.0339 | 10.0% | 3.3% | 19.3% | 20.6% | 23.4% | 13.4% | 25.1% |
| 20% | 0.0301 | 20.0% | 4.9% | 32.8% | 34.4% | 37.8% | 17.8% | 39.7% |

99.9% quantile on the ρ grid:

| PD | Basel | 0.02 | 0.05 | 0.10 | 0.15 | 0.20 | 0.30 |
|---|---:|---:|---:|---:|---:|---:|---:|
| 1% | 9.1% | 2.8% | 4.7% | 7.7% | 11.0% | 14.6% | 22.4% |
| 3% | 14.2% | 7.2% | 11.1% | 17.0% | 22.9% | 28.9% | 41.1% |
| 5% | 16.8% | 11.1% | 16.4% | 24.1% | 31.4% | 38.4% | 52.3% |
| 10% | 23.4% | 19.7% | 27.2% | 37.4% | 46.3% | 54.5% | 68.8% |
| 20% | 37.8% | 34.1% | 43.9% | 55.7% | 65.0% | 72.7% | 84.5% |

`results/vasicek_losses.csv` has every quantile, UL and ES for each cell.
`figures/loss_distribution.png` plots the density and the log-scale exceedance curve at PD 5%.

## 4. Pricing

**Loan-level break-even premium** (the requested definition):

```
s* = EL + h · UL_99.9          APR = EFFR + s
```

Funding cost passes through: lenders' opportunity cost EFFR is already in the APR. h is the
required return **in excess of EFFR** on the risk capital K = UL_99.9. A total-return hurdle
h_tot corresponds to h = h_tot − EFFR. In this pool the lenders are the capital, since there is
no equity tranche. The formula is first order. It ignores the interest lost on a defaulting loan
(one term plus `LATE_PERIOD`, at most 0.13% APY at PD 10%, see `lender_apy.csv`) and compounding.

s* in bps at h = 15%; `*` means the deployed 500 bps is adequate:

| PD | Basel | 0.02 | 0.05 | 0.10 | 0.15 | 0.20 | 0.30 |
|---|---:|---:|---:|---:|---:|---:|---:|
| 1% | 222* | 127* | 155* | 201* | 250* | 303* | 422* |
| 3% | 467* | 364* | 422* | 511 | 599 | 688 | 872 |
| 5% | 677 | 592 | 671 | 786 | 895 | 1,002 | 1,209 |
| 10% | 1,201 | 1,145 | 1,258 | 1,411 | 1,545 | 1,667 | 1,883 |
| 20% | 2,267 | 2,212 | 2,358 | 2,535 | 2,675 | 2,791 | 2,968 |

**Pool-level break-even.** Lenders earn nothing on idle cash (1 − u) and pay the fee f on
interest. Requiring `u·APR·(1−f) − u·EL ≥ EFFR + h·u·UL` gives

```
s_pool = (EFFR/u + EL + h·UL) / (1 − f) − EFFR
```

At u = 85% the cash drag alone adds EFFR·(1/u − 1) = 76 bps. A reserve whose surplus is returned
to lenders leaves this expectation unchanged and is omitted.

Basel ρ, bps:

| PD | h | s* ASRF | s* replenished | s* N=500 | s* N=100 | pool u=85% | pool u=90% | pool u=85%, f=10% |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 3% | 10% | 412 | 427 | 417 | 440 | 488 | 460 | 590 |
| 3% | 15% | 467 | 488 | 476 | 510 | 544 | 516 | 652 |
| 3% | 25% | 579 | 609 | 593 | 651 | 655 | 627 | 776 |
| 5% | 10% | 618 | 646 | 625 | 654 | 694 | 666 | 820 |
| 5% | 15% | 677 | 712 | 688 | 731 | 754 | 725 | 885 |
| 5% | 25% | 795 | 843 | 813 | 885 | 872 | 843 | 1,017 |
| 10% | 10% | 1,134 | 1,214 | 1,144 | 1,182 | 1,211 | 1,182 | 1,393 |
| 10% | 15% | 1,201 | 1,293 | 1,216 | 1,273 | 1,278 | 1,250 | 1,468 |
| 10% | 25% | 1,336 | 1,452 | 1,360 | 1,455 | 1,412 | 1,384 | 1,617 |

**Largest annual PD that 500 bps can carry** (in parentheses, per 30-day loan; from
`results/max_pd_for_500bps.csv`):

| ρ | h = 0 (EL only) | h = 10% | h = 15% | h = 25% | h = 15%, pool level u = 85% |
|---|---:|---:|---:|---:|---:|
| Basel | 5.00% (0.42%) | 3.85% (0.32%) | 3.30% (0.28%) | 2.33% (0.19%) | 2.60% (0.22%) |
| 0.05 | 5.00% | 4.01% | 3.62% | 2.98% | 3.02% |
| 0.15 | 5.00% | 3.01% | 2.39% | 1.60% | 1.94% |
| 0.30 | 5.00% | 1.93% | 1.29% | 0.69% | 1.01% |

`figures/breakeven_premium.png` plots s* against PD.

## 5. Lender APY

```
APY ≈ u·APR·(1 − f − r) − max(u·L − R, 0)  [+ reserve released]      R = R₀ + u·APR·r
```

With no reserve this reduces to `u·APR·(1−f) − u·L`. If the unused reserve is released at year
end, the result is the same as having no reserve, exactly (unit-tested). APY decreases in L, so
its 1st percentile is the APY at L₉₉. The expectation uses the closed-form stop-loss transform,
and a unit test checks it against Monte Carlo.

Deployed APR 9.33%, u = 85%, f = 0, no reserve:

| PD | ρ | E[APY] | APY 1st pct | P(APY < 0) | P(APY < EFFR) |
|---|---:|---:|---:|---:|---:|
| 1% | Basel | 7.08% | 3.43% | 0.1% | 2.1% |
| 3% | Basel | 5.38% | −0.42% | 1.3% | 20.8% |
| 3% | 0.15 | 5.38% | −4.31% | 4.3% | 22.6% |
| 5% | Basel | 3.68% | −2.85% | 5.9% | 55.7% |
| 5% | 0.15 | 3.68% | −9.91% | 13.5% | 44.3% |
| 10% | Basel | −0.57% | −8.45% | 53.6% | 98.8% |
| 20% | Basel | −9.07% | −19.97% | 99.6% | 100% |

Expected APY equals EFFR at PD = APR − EFFR/u = 4.24% (u = 85%). `results/lender_apy.csv` also
covers a reserve that covers EL. While that reserve is being retained, lenders' cash yield is
lower by u·APR·r, and P(APY < EFFR) reaches 100% for PD ≥ 5%, because the retained balance is
not counted as lender income. Simple rates throughout: re-lending repaid interest monthly would
turn u·APR = 7.93% into 8.2%, which is not modelled. See `figures/lender_apy.png`.

## 6. Security mix: secured stake and unsecured backing

**Secured share s.** If a fraction s of every loan's principal is covered by committed stake,
LGD = 1 − s. The ASRF quantile is linear in LGD, so EL, UL and s* all scale by (1 − s). With
different s per loan, ASRF additivity gives `L_q = Σ wᵢ(1 − sᵢ)pᵢ(z_q)` (Gordy 2003). The
secured share needed for 500 bps to break even (Basel ρ, h = 15%) is 0 / 0 / **26%** / **58%** /
78% at PD 1 / 3 / 5 / 10 / 20% (`results/secured_share.csv`).

**Unsecured backing does not lower LGD for lenders.** `_chargeBackers` burns the backer's granted
credit (`creditLoss`) and recovers no USDC. Whatever lenders lose is still lost. Its economic
role, if it has one, is to **lower PD**. Backers screen, monitor and enforce (Stiglitz 1990;
Besley and Coate 1995; Ghatak and Guinnane 1999), and their own future credit is at stake. That
is modelled as a PD multiplier m on the borrower's PD, with the Basel ρ evaluated at m·PD; it
is never modelled as an LGD reduction. Break-even s* in bps (h = 15%, Basel ρ):

| PD | m | s = 0 | s = 25% | s = 50% |
|---|---:|---:|---:|---:|
| 3% | 1 | 467 | 351 | 234 |
| 3% | 0.5 | 292 | 219 | 146 |
| 5% | 1 | 677 | 508 | 339 |
| 5% | 0.75 | 547 | 410 | 274 |
| 5% | 0.5 | 412 | 309 | 206 |
| 10% | 1 | 1,201 | 901 | 601 |
| 10% | 0.5 | 677 | 508 | 339 |

The value of m is a hypothesis to estimate, not a fact. Giné and Karlan (2014) found no
significant rise in default when a Philippine lender removed group liability, so m may be close
to 1. On-chain data can estimate it: compare default rates of backed and unbacked loans at equal
score. Backing within one social network can also raise ρ, and it creates contagion: a backer who
loses credit may fail to roll their own loans. Neither effect is modelled. A single APR for
backed and unbacked loans overprices backed loans if m < 1, which invites adverse selection
among the unbacked. `figures/security_mix.png` shows both panels.

## 7. First-loss reserve (`reserveBps`)

**Assumed mechanics** (the reserve is not yet in the contract). A share r of repaid interest goes
to a reserve outside `lenderCash`. At `markDefaulted` the loss falls first on slashed stake, then
on the reserve, then on lenders. Per unit of deposits the reserve's one-year inflow is u·APR·r
and the loss is u·L, so **utilisation cancels**: covering a target loss rate T needs
`r = T / APR`. Anything above 1 − f cannot be funded from interest. The reserve is first loss, so
it pays from the first dollar. A reserve sized at L_q − EL therefore keeps lenders' loss at or
below u·EL (the loss already priced) with probability q. Lenders still take *some* loss with
probability P(L > L_q − EL), which can be large.

`reserveBps` (as a share of interest) whose one-year inflow equals the target, at the deployed
APR of 9.33%, with P(lenders take any loss in year 1) starting from an empty reserve:

| PD | ρ | EL | L95−EL | L99−EL | L99 | P(loss) EL | P(loss) L95−EL | P(loss) L99−EL | P(loss) L99 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1% | Basel | 11% | 22% | 46% | 57% | 33.8% | 11.7% | 2.0% | 1.0% |
| 3% | Basel | 32% | 41% | 73% | 105% | 39.6% | 25.4% | 5.1% | 1.0% |
| 3% | 0.15 | 32% | 63% | 122% | 154% | 35.2% | 13.0% | 2.4% | 1.0% |
| 5% | Basel | 54% | 50% | 82% | 136% | 42.4% | 48.5% | 13.2% | 1.0% |
| 5% | 0.15 | 54% | 93% | 171% | 225% | 37.0% | 15.5% | 3.0% | 1.0% |
| 10% | Basel | 107% | 64% | 99% | 207% | 45.3% | 91.2% | 54.3% | 1.0% |
| 10% | 0.15 | 107% | 152% | 257% | 364% | 39.8% | 22.3% | 5.2% | 1.0% |

At the deployed APR, a reserve funded from interest cannot cover EL at PD 10%, and at PD ≥ 3% it
cannot cover L99 within one year. The Vasicek distribution is right-skewed (median below mean),
so a reserve that covers exactly EL leaves lenders a 34–45% chance of some loss (PD 1–10%). At the
break-even APR (EFFR + s*, h = 15%, Basel ρ) the EL shares are 33 / 45 / 61% at PD 3 / 5 / 10%
(`results/reserve_sizing.csv` covers every ρ). `figures/reserve_bps.png` plots the shares.

**Multi-year policy.** Each year the reserve receives u·APR·r. It is capped at
`cap = u·(L99 − EL)`, and the excess is released to lenders. Annual factors are independent,
which is optimistic, since credit cycles are serially correlated. "Covers EL" means r = EL/APR.
"Recommended" means r = (EL + (L99 − EL)/3)/APR, rounded up to 5%. Both are evaluated at the
recommended APRs, with 200,000 paths:

| PD | policy | r | cap (of deposits) | P(any lender loss) yr 1 | yr 2 | yr 3 | yr 5 | yr 10 |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| 3% | covers EL | 29% | 5.81% | 39.6% | 29.1% | 23.9% | 18.9% | 13.7% |
| 3% | recommended | 55% | 5.81% | 9.5% | 2.9% | 1.2% | 0.4% | 0.4% |
| 5% | covers EL | 41% | 6.53% | 42.4% | 31.4% | 26.1% | 20.2% | 15.2% |
| 5% | recommended | 65% | 6.53% | 11.1% | 3.5% | 1.4% | 0.5% | 0.3% |
| 10% | covers EL | 55% | 7.88% | 45.4% | 33.4% | 27.8% | 22.0% | 16.9% |
| 10% | recommended | 75% | 7.88% | 13.0% | 4.0% | 1.7% | 0.5% | 0.3% |

What the reserve does and does not do:

- **Funded from lenders' interest, it cannot raise their expected return.** Once the surplus
  above the cap is released, lenders' long-run expected yield is still u·APR·(1−f) − u·EL. What
  it buys is a share price that does not fall at each write-off, which removes most of the run
  incentive of §8. It also protects lenders who stay against losses that arrive while others
  enter or exit. If the reserve is funded from the protocol's fee instead, it is a real transfer
  to lenders, and the protocol is the equity tranche.
- **Cost.** A full reserve held as idle USDC forgoes cap × pool return, which is 0.36 / 0.41 /
  0.56% APY at PD 3 / 5 / 10% (Basel ρ) and up to 2.4% at ρ = 0.15. Holding it as a junior claim
  in the pool removes the drag: reserve-owned shares are lent out like the rest and are burned
  first on default.
- **Granularity.** The table above is ASRF. With about 100 loans the tail is 14–20% fatter
  (§2.4), so a small pool reaches the steady-state probabilities later.
- **Parameter bounds.** The planned `reserveBps` must allow at least ~7,500 bps, and
  `reserveBps + protocolFeeBps ≤ 10,000`.

## 8. Stale share price and runs (Diamond and Dybvig 1983)

`totalAssets` counts each loan at par until `markDefaulted`, which comes 30 days after the due
date. Exits (`withdrawFunds` and queue fills) are paid at that share price. Take a pool of size
A with an overdue unsecured exposure X that will be written off with expected loss fraction ℓ
(ℓ = 1 if certain). A lender holding share w who exits before the write-off receives w·A, against
a fair w·(A − ℓX). The excess, **w·ℓ·X, is borne by the lenders who stay**, whose loss rate rises
from ℓX/A to ℓX/((1 − w)A). In a 10,000 USDC pool with 2% overdue (200 USDC), a 20% lender
extracts 40 USDC, and the stayers lose 2.5% instead of 2.0% (`results/run_transfer.csv`).

- **The information is public.** Due dates (`getLoanTerms`) and outstanding balances are
  on-chain, so this is not an insider problem. It is a first-mover game with payoff
  complementarity: each exit makes staying worse, as in Diamond and Dybvig (1983) and in the
  stale-NAV fund outflows studied by Chen, Goldstein and Jiang (2010).
- **Liquidity does not stop it.** The book of 30-day loans turns over about monthly, and queued
  withdrawals are paid before new loans. One `LATE_PERIOD` is therefore long enough for a large
  part of the pool to exit.
- **Size of the window.** In steady state the overdue stock awaiting write-off is λ·u·30/365,
  which is 0.21 / 0.36 / 0.74% of assets at PD 3 / 5 / 10%. In a stress year it scales with
  the realised default rate. For a 365-day bullet loan, a borrower who has stopped paying is
  carried at par for up to 395 days.

**Recommendation.**

1. At the due date, impair unpaid exposure to (1 − ℓ̂)·X, where ℓ̂ is the overdue-to-default roll
   rate times LGD. Start conservatively at ℓ̂ = 1 until history exists. This is the IFRS 9
   stage 3 / CECL treatment of credit-impaired assets.
2. Optionally, hold a portfolio allowance of p_T·LGD per loan from origination. This is the CECL
   day-one allowance, and for loans of a year or less it equals the IFRS 9 12-month ECL.
3. Let the reserve absorb impairments first, so the share price does not jump. A reserve that
   covers write-offs plays the role of deposit insurance in Diamond and Dybvig and removes the
   run equilibrium, for as long as it is adequate.

## 9. Assumptions and limitations

1. One Gaussian factor (Vasicek / Gordy). A fat-tailed factor, such as a t-copula, or several
   factors (geography, cohort, crypto market) would fatten the tails. The figures here are lower
   bounds for a given ρ.
2. PD and ρ are scenarios, not estimates. The Basel retail ρ comes from bank books, and the grid
   up to 0.30 brackets more concentrated pools.
3. The horizon is one year, with the factor fixed within it. The multi-year reserve model takes
   years to be independent, which is optimistic.
4. Constant hazard across a borrower's loans (assumption H), with no seasoning and no last-loan
   strategic default.
5. LGD is deterministic: 100% unsecured, 0% secured. No time value on the 60-day lag. EAD is the
   bullet principal.
6. Exposures are equal, with granularity handled by Monte Carlo and the first-order GA. Name
   concentration beyond that is not modelled; `maxLoanAmount` (100 USDC at score 100%) limits it.
7. Simple, non-compounded yields. Interest lost on defaulted loans is left out of pricing and
   bounded separately (≤ 0.26% APY even at PD 20%).
8. EFFR is held at 4.33%, the deployed constant. The loan-level premium does not depend on EFFR.
   The pool-level cash drag EFFR·(1/u − 1) does.
9. Utilisation is exogenous at 85% (90% as sensitivity). In stress, withdrawals and the queue
   would move it.
10. Not modelled: fraud, Sybil activity or score-oracle failure (the CI-6 trust root), smart-
    contract risk, USDC depeg, backing-network contagion, and loans repaid within 24 hours, which
    pay no interest yet carry some PD.
11. The 99.9% confidence level and the 10–25% hurdles are regulatory and industry conventions
    (BCBS 2005), not an optimum for this pool.

## Files

| Path | Content |
|---|---|
| `vasicek.py` | closed forms: PD horizons, Basel correlation, Vasicek quantile/CDF/pdf, variance, ES, stop-loss, replenished pool, granularity adjustment, pricing, lender APY, reserve, stale-NAV transfer |
| `montecarlo.py` | conditional-binomial and brute-force copula samplers, order-statistic quantile CIs, revolving year, multi-year reserve paths |
| `run.py` | writes every `results/*.csv`, `results/summary.md` and `figures/*.png` |
| `test_vasicek.py` | 31 unittest cases: Basel endpoints 0.16/0.03, EL = PD·LGD, quantile/CDF inversion, Φ₂ against SciPy and Owen's T, ES / variance / stop-loss against quadrature, MC against Vasicek at N = 200,000, GA against a numerical derivative and MC at N = 500, brute force against binomial, pricing roots, APY identities, reserve probabilities, determinism |
| `results/` | `pd_annual_to_loan`, `pd_loan_to_annual`, `basel_correlation`, `vasicek_losses`, `mc_granularity`, `mc_bruteforce_check`, `revolving_vs_static`, `breakeven_premium`, `max_pd_for_500bps`, `lender_apy`, `secured_share`, `backing_pd_multiplier`, `reserve_sizing`, `reserve_paths`, `recommendation`, `run_transfer`, `overdue_stock` (.csv), `summary.md` |
| `figures/` | `loss_distribution`, `granularity`, `breakeven_premium`, `lender_apy`, `security_mix`, `reserve_bps` (.png) |

## References

- BCBS (2005). *An Explanatory Note on the Basel II IRB Risk Weight Functions*. Basel Committee on Banking Supervision, July.
- BCBS (2006). *International Convergence of Capital Measurement and Capital Standards: A Revised Framework, Comprehensive Version*, paras 328–330 (retail risk-weight functions).
- Besley, T. and Coate, S. (1995). Group lending, repayment incentives and social collateral. *Journal of Development Economics* 46(1), 1–18.
- Chen, Q., Goldstein, I. and Jiang, W. (2010). Payoff complementarities and financial fragility: Evidence from mutual fund outflows. *Journal of Financial Economics* 97(2), 239–262.
- Diamond, D. W. and Dybvig, P. H. (1983). Bank runs, deposit insurance, and liquidity. *Journal of Political Economy* 91(3), 401–419.
- FASB (2016). Accounting Standards Update 2016-13, *Financial Instruments—Credit Losses (Topic 326)* (CECL).
- Ghatak, M. and Guinnane, T. W. (1999). The economics of lending with joint liability: theory and practice. *Journal of Development Economics* 60(1), 195–228.
- Giné, X. and Karlan, D. (2014). Group versus individual liability: Short and long term evidence from Philippine microcredit lending groups. *Journal of Development Economics* 107, 65–83.
- Gordy, M. B. (2003). A risk-factor model foundation for ratings-based bank capital rules. *Journal of Financial Intermediation* 12(3), 199–232.
- Gordy, M. B. (2004). Granularity adjustment in portfolio credit risk measurement. In G. Szegö (ed.), *Risk Measures for the 21st Century*, Wiley.
- Gordy, M. B. and Lütkebohmert, E. (2013). Granularity adjustment for regulatory capital assessment. *International Journal of Central Banking* 9(3), 33–71.
- IASB (2014). *IFRS 9 Financial Instruments*.
- Martin, R. and Wilde, T. (2002). Unsystematic credit risk. *Risk* 15(11), 123–128.
- Stiglitz, J. E. (1990). Peer monitoring and credit markets. *World Bank Economic Review* 4(3), 351–366.
- Vasicek, O. (2002). The distribution of loan portfolio value. *Risk* 15(12), 160–162.
