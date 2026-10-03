"""Closed-form one-factor (ASRF / Vasicek) credit-loss model for the microcredit pool.

Conventions used throughout
---------------------------
* Rates are annual decimals (0.05 = 5% = 500 bps) unless a name ends in ``_bps``.
* ``pd`` is the **annual obligor PD**: the probability that a borrower who keeps rolling loans
  defaults within one year (the Basel convention). :func:`loan_pd_from_annual_pd` and
  :func:`annual_pd_from_loan_pd` convert to and from the per-loan PD of a loan with a given term.
* Losses are fractions of exposure (principal). ``D`` denotes the default rate of an infinitely
  granular pool and ``L = lgd * D`` its loss rate. Interest is cash basis in the contract
  (``_repay``), so a write-off removes principal only (``markDefaulted``).
* The systematic factor ``Z ~ N(0, 1)`` is "good" when high. Obligor ``i`` defaults within the
  year if ``sqrt(rho) Z + sqrt(1 - rho) eps_i < Phi^{-1}(pd)``. Conditional on ``Z = z`` the
  default probability is ``p(z) = Phi((Phi^{-1}(pd) - sqrt(rho) z) / sqrt(1 - rho))``.

References: Vasicek (2002, Risk 15(12)); Gordy (2003, J. Financial Intermediation 12(3));
BCBS (2005), "An explanatory note on the Basel II IRB risk weight functions"; BCBS (2006),
Basel II comprehensive version, para. 330 (other retail correlation); Martin and Wilde (2002,
Risk 15(11)) and Gordy and Luetkebohmert (2013, IJCB 9(3)) for the granularity adjustment.
"""

from __future__ import annotations

import math

import numpy as np
from scipy import integrate, optimize
from scipy.stats import norm

# ── contract parameters (packages/foundry/contracts/DecentralizedMicrocredit.sol, Deploy.s.sol) ──
EFFR = 0.0433  # effrRate = 433 bps at deployment (set manually, not an oracle)
RISK_PREMIUM = 0.0500  # riskPremium = 500 bps at deployment
APR = EFFR + RISK_PREMIUM  # loan rate fixed at origination: effrRate + riskPremium
DAYS_PER_YEAR = 365  # SECONDS_PER_YEAR = 365 days
DEFAULT_TERM_DAYS = 30  # DEFAULT_LOAN_TERM
MIN_TERM_DAYS, MAX_TERM_DAYS = 1, 365  # MIN_LOAN_TERM, MAX_LOAN_TERM
LATE_PERIOD_DAYS = 30  # LATE_PERIOD: markDefaulted allowed this long after the due date
GRACE_PERIOD_DAYS = 1  # GRACE_PERIOD: a loan repaid within a day pays no interest
UTILISATION_CAP = 0.90  # lendingUtilizationCap = 9000 bps
LIQUIDITY_BUFFER = 0.05  # liquidityBuffer = 500 bps
PROTOCOL_FEE = 0.0  # protocolFeeBps default
MAX_PROTOCOL_FEE = 0.20  # MAX_PROTOCOL_FEE_BPS

# Basel II "other retail" correlation endpoints (BCBS 2006, para. 330).
BASEL_RETAIL_RHO_HIGH_PD = 0.03
BASEL_RETAIL_RHO_LOW_PD = 0.16
BASEL_RETAIL_K = 35.0


def _as_float_or_array(x):
    arr = np.asarray(x, dtype=float)
    return float(arr) if arr.ndim == 0 else arr


def _check_open_unit(name, x):
    arr = np.asarray(x, dtype=float)
    if np.any(~((arr > 0.0) & (arr < 1.0))):
        raise ValueError(f"{name} must lie strictly between 0 and 1, got {x!r}")


# ───────────────────────────── PD horizon conversion ─────────────────────────────


def cycles_per_year(term_days: float = DEFAULT_TERM_DAYS) -> float:
    """Number of back-to-back loans of ``term_days`` that fit in a 365-day year (12.17 for 30 days)."""
    if term_days <= 0:
        raise ValueError("term_days must be positive")
    return DAYS_PER_YEAR / term_days


def annual_pd_from_loan_pd(loan_pd, term_days: float = DEFAULT_TERM_DAYS):
    """Annual obligor PD of a borrower who rolls loans of ``term_days`` all year.

    Assumption (constant hazard / independence across cycles): conditional on surviving the
    previous loans, each loan defaults with the same probability ``loan_pd``, independently of
    the borrower's earlier cycles, so ``PD_annual = 1 - (1 - loan_pd) ** (365 / term_days)``.
    Equivalently the default time is exponential with hazard ``-ln(1 - PD_annual)`` per year.
    Fractional cycle counts are interpreted through that continuous hazard.
    """
    p = np.asarray(loan_pd, dtype=float)
    if np.any((p < 0) | (p >= 1)):
        raise ValueError("loan_pd must lie in [0, 1)")
    return _as_float_or_array(-np.expm1(np.log1p(-p) * cycles_per_year(term_days)))


def loan_pd_from_annual_pd(annual_pd, term_days: float = DEFAULT_TERM_DAYS):
    """Inverse of :func:`annual_pd_from_loan_pd`: ``1 - (1 - PD_annual) ** (term_days / 365)``."""
    p = np.asarray(annual_pd, dtype=float)
    if np.any((p < 0) | (p >= 1)):
        raise ValueError("annual_pd must lie in [0, 1)")
    return _as_float_or_array(-np.expm1(np.log1p(-p) / cycles_per_year(term_days)))


def hazard_rate(annual_pd):
    """Constant default intensity (per year) implied by an annual PD: ``-ln(1 - PD)``."""
    p = np.asarray(annual_pd, dtype=float)
    if np.any((p < 0) | (p >= 1)):
        raise ValueError("annual_pd must lie in [0, 1)")
    return _as_float_or_array(-np.log1p(-p))


def replenished_default_rate(annual_pd, term_days: float = DEFAULT_TERM_DAYS):
    """Expected defaults per unit of exposure-year when every defaulted loan is replaced at once.

    A "slot" of exposure lent in back-to-back loans of ``term_days`` sees ``n = 365 / term``
    loans a year, each defaulting with the per-loan PD; if a defaulter is immediately replaced
    by a new borrower with the same PD, expected defaults per slot-year are ``n * loan_pd``,
    which exceeds the static annual PD ``1 - (1 - loan_pd) ** n`` (the defaulter cannot default
    twice; its replacement can). As ``n -> inf`` this tends to the hazard ``-ln(1 - PD)``.
    Applied to a conditional PD ``p(z)`` it maps the static ASRF loss to the replenished one.
    """
    n = cycles_per_year(term_days)
    return _as_float_or_array(n * np.asarray(loan_pd_from_annual_pd(annual_pd, term_days)))


# ───────────────────────────── correlation ─────────────────────────────


def basel_other_retail_correlation(pd):
    """Basel II IRB asset correlation for "other retail" exposures (BCBS 2006, para. 330).

    ``rho = 0.03 w + 0.16 (1 - w)`` with ``w = (1 - exp(-35 PD)) / (1 - exp(-35))``: 0.16 as
    PD -> 0 and 0.03 at PD = 1. Calibrated on bank retail books, not on DeFi microcredit.
    """
    p = np.asarray(pd, dtype=float)
    if np.any((p < 0) | (p > 1)):
        raise ValueError("pd must lie in [0, 1]")
    w = -np.expm1(-BASEL_RETAIL_K * p) / -math.expm1(-BASEL_RETAIL_K)
    return _as_float_or_array(BASEL_RETAIL_RHO_HIGH_PD * w + BASEL_RETAIL_RHO_LOW_PD * (1.0 - w))


def resolve_rho(pd, rho):
    """``rho`` itself, or the Basel other-retail correlation of ``pd`` when ``rho`` is None."""
    return basel_other_retail_correlation(pd) if rho is None else rho


# ───────────────────────────── Vasicek distribution ─────────────────────────────


def conditional_pd(pd, rho, z):
    """Default probability conditional on the systematic factor ``Z = z`` (low z = bad state)."""
    _check_open_unit("pd", pd)
    _check_open_unit("rho", rho)
    return _as_float_or_array(norm.cdf((norm.ppf(pd) - np.sqrt(rho) * np.asarray(z, float)) / np.sqrt(1 - rho)))


def vasicek_quantile(pd, rho, q):
    """q-quantile of the infinitely granular pool's default rate (Vasicek 2002, eq. for L_alpha).

    ``D_q = Phi((Phi^{-1}(PD) + sqrt(rho) Phi^{-1}(q)) / sqrt(1 - rho))``. Gordy (2003) shows
    this is the exact q-quantile of the loss rate in the asymptotic single-risk-factor limit.
    """
    _check_open_unit("pd", pd)
    _check_open_unit("rho", rho)
    _check_open_unit("q", q)
    return _as_float_or_array(norm.cdf((norm.ppf(pd) + np.sqrt(rho) * norm.ppf(q)) / np.sqrt(1 - rho)))


def vasicek_cdf(x, pd, rho):
    """P(D <= x) = Phi((sqrt(1 - rho) Phi^{-1}(x) - Phi^{-1}(PD)) / sqrt(rho)), x in [0, 1]."""
    _check_open_unit("pd", pd)
    _check_open_unit("rho", rho)
    xa = np.clip(np.asarray(x, dtype=float), 0.0, 1.0)
    with np.errstate(divide="ignore"):
        out = norm.cdf((np.sqrt(1 - rho) * norm.ppf(xa) - norm.ppf(pd)) / np.sqrt(rho))
    return _as_float_or_array(out)


def vasicek_pdf(x, pd, rho):
    """Density of D on (0, 1) (Vasicek 2002)."""
    _check_open_unit("pd", pd)
    _check_open_unit("rho", rho)
    xa = np.asarray(x, dtype=float)
    u = norm.ppf(xa)
    c = norm.ppf(pd)
    dens = np.sqrt((1 - rho) / rho) * np.exp(0.5 * u**2 - (np.sqrt(1 - rho) * u - c) ** 2 / (2 * rho))
    return _as_float_or_array(dens)


def bivariate_normal_cdf(h: float, k: float, r: float) -> float:
    """Phi_2(h, k; r) = P(X <= h, Y <= k) for standard normals with correlation ``r``.

    Computed as the one-dimensional integral ``int_{-inf}^{h} phi(x) Phi((k - r x)/sqrt(1-r^2)) dx``
    with adaptive quadrature (absolute error ~1e-13), which is accurate in the far tails where
    generic multivariate-normal CDF routines lose relative precision.
    """
    if not -1 < r < 1:
        raise ValueError("r must lie in (-1, 1)")
    if h == -math.inf or k == -math.inf:
        return 0.0
    if h == math.inf:
        return float(norm.cdf(k))
    if k == math.inf:
        return float(norm.cdf(h))
    s = math.sqrt(1 - r * r)
    val, _ = integrate.quad(lambda x: norm.pdf(x) * norm.cdf((k - r * x) / s), -math.inf, h, epsabs=1e-14, epsrel=1e-11, limit=200)
    return float(val)


def vasicek_variance(pd: float, rho: float) -> float:
    """Var(D) = Phi_2(c, c; rho) - PD^2 with c = Phi^{-1}(PD) (Vasicek 2002)."""
    c = float(norm.ppf(pd))
    return bivariate_normal_cdf(c, c, rho) - pd * pd


def expected_loss(pd, lgd=1.0):
    """EL per unit exposure = PD x LGD (E[D] = PD exactly in the Vasicek model)."""
    return _as_float_or_array(np.asarray(pd, float) * np.asarray(lgd, float))


def loss_quantile(pd, rho, q, lgd=1.0):
    """q-quantile of the loss rate L = LGD x D for a deterministic LGD."""
    return _as_float_or_array(np.asarray(lgd, float) * np.asarray(vasicek_quantile(pd, rho, q)))


def unexpected_loss(pd, rho, q, lgd=1.0):
    """UL_q = q-quantile minus EL; at q = 99.9% this is the Basel IRB capital K (retail, no MA)."""
    return _as_float_or_array(np.asarray(loss_quantile(pd, rho, q, lgd)) - np.asarray(expected_loss(pd, lgd)))


def basel_irb_capital(pd, lgd=1.0, rho=None, q=0.999):
    """Basel II IRB capital requirement per unit EAD for retail (BCBS 2005, eq. 1, no maturity adj.).

    ``K = LGD [Phi((Phi^{-1}(PD) + sqrt(rho) Phi^{-1}(0.999)) / sqrt(1 - rho)) - PD]``. The 1.06
    scaling factor and the 12.5 RWA multiplier of the Accord are not applied.
    """
    return unexpected_loss(pd, resolve_rho(pd, rho), q, lgd)


def expected_shortfall(pd: float, rho: float, q: float, lgd: float = 1.0) -> float:
    """ES_q = E[L | L >= L_q] in closed form.

    ``int_{y_q}^{inf} Phi((c + sqrt(rho) y)/sqrt(1-rho)) phi(y) dy = PD - Phi_2(c, Phi^{-1}(q); -sqrt(rho))``,
    so ``ES_q = LGD (PD - Phi_2(c, Phi^{-1}(q); -sqrt(rho))) / (1 - q)``.
    """
    _check_open_unit("q", q)
    c = float(norm.ppf(pd))
    tail = pd - bivariate_normal_cdf(c, float(norm.ppf(q)), -math.sqrt(rho))
    return lgd * tail / (1 - q)


def stop_loss(pd: float, rho: float, k: float) -> float:
    """Stop-loss transform E[(D - k)^+] of the Vasicek default rate, in closed form.

    With ``y_k = (sqrt(1-rho) Phi^{-1}(k) - c) / sqrt(rho)`` (so ``P(D <= k) = Phi(y_k)``),
    ``E[(D - k)^+] = PD - Phi_2(c, y_k; -sqrt(rho)) - k (1 - Phi(y_k))``. Used for the expected
    loss that a first-loss reserve of size k (per unit exposure) does not absorb.
    """
    if k <= 0:
        return pd - k
    if k >= 1:
        return 0.0
    c = float(norm.ppf(pd))
    y_k = (math.sqrt(1 - rho) * float(norm.ppf(k)) - c) / math.sqrt(rho)
    val = pd - bivariate_normal_cdf(c, y_k, -math.sqrt(rho)) - k * float(norm.sf(y_k))
    return max(val, 0.0)


# ───────────────────────────── replenished (revolving) pool ─────────────────────────────


def replenished_loss_quantile(pd, rho, q, lgd=1.0, term_days: float = DEFAULT_TERM_DAYS):
    """q-quantile of the loss per exposure-year when defaulted loans are replaced immediately.

    The factor fixes the conditional annual PD ``p(z)`` for the year; each slot then sees
    ``n * (1 - (1 - p(z)) ** (1/n))`` expected defaults (:func:`replenished_default_rate`). The
    map is increasing in ``p(z)``, so quantiles transform directly.
    """
    return _as_float_or_array(np.asarray(lgd, float) * np.asarray(replenished_default_rate(vasicek_quantile(pd, rho, q), term_days)))


def replenished_expected_loss(pd: float, rho: float, lgd: float = 1.0, term_days: float = DEFAULT_TERM_DAYS) -> float:
    """E[loss per exposure-year] with immediate replacement, by Gauss-Hermite quadrature over Z."""
    nodes, weights = np.polynomial.hermite_e.hermegauss(120)
    vals = replenished_default_rate(np.clip(conditional_pd(pd, rho, nodes), 0.0, 1 - 1e-15), term_days)
    return float(lgd * np.dot(weights, vals) / math.sqrt(2 * math.pi))


# ───────────────────────────── granularity ─────────────────────────────


def granularity_adjustment(pd, rho, q, n_loans, lgd=1.0):
    """First-order granularity adjustment to the q-quantile for ``n_loans`` equal loans.

    Uses the first-order formula of Martin and Wilde (2002) and Gordy (2004),
    ``GA = -1/(2 h(y)) d/dy [h(y) sigma^2(y) / mu'(y)]`` at ``y = Phi^{-1}(q)``, where ``y = -Z``,
    ``mu(y) = E[L | y]``, ``sigma^2(y) = Var[L | y]`` and ``h`` is the standard normal density.
    For equal exposures and deterministic LGD, ``sigma^2 = LGD^2 mu~(1 - mu~) / N`` with
    ``mu~ = Phi(g)``, ``g = (c + sqrt(rho) y)/sqrt(1 - rho)``, ``b = sqrt(rho/(1 - rho))``, giving
    ``GA = LGD [mu~(1-mu~)(y - g b) - (1 - 2 mu~) phi(g) b] / (2 N phi(g) b)``. It is O(1/N) and
    ignores the lattice structure of a finite pool's losses (multiples of LGD/N).
    """
    if n_loans < 1:
        raise ValueError("n_loans must be >= 1")
    y = norm.ppf(q)
    c = norm.ppf(pd)
    b = np.sqrt(rho / (1 - rho))
    g = (c + np.sqrt(rho) * y) / np.sqrt(1 - rho)
    mu = norm.cdf(g)
    dmu = norm.pdf(g) * b
    ga = (mu * (1 - mu) * (y - g * b) - (1 - 2 * mu) * dmu) / (2 * n_loans * dmu)
    return _as_float_or_array(np.asarray(lgd, float) * ga)


# ───────────────────────────── pricing ─────────────────────────────


def breakeven_premium(pd, rho, hurdle, lgd=1.0, q=0.999):
    """Loan-level break-even risk premium per year: ``s* = EL + hurdle * UL_q``.

    APR = EFFR + s with the lenders' funding cost EFFR passed through one for one. ``hurdle`` is
    the required return in excess of EFFR on risk capital ``K = UL_q`` (a total-return hurdle
    ``h_tot`` corresponds to ``hurdle = h_tot - EFFR``). First-order: ignores the interest lost on
    a defaulting loan (at most one term's interest plus LATE_PERIOD, see README) and compounding.
    """
    return _as_float_or_array(np.asarray(expected_loss(pd, lgd)) + np.asarray(hurdle, float) * np.asarray(unexpected_loss(pd, rho, q, lgd)))


def pool_breakeven_premium(pd, rho, hurdle, lgd=1.0, q=0.999, utilisation=0.85, fee=PROTOCOL_FEE, effr=EFFR):
    """Risk premium at which lenders' expected excess return over EFFR pays the hurdle on capital.

    Per unit of deposits: lenders earn ``u APR (1 - f) - u EL`` and require ``EFFR + hurdle u UL``
    (idle cash ``1 - u`` earns nothing on-chain). Solving for ``s`` in ``APR = EFFR + s``:
    ``s = (EFFR / u + EL + hurdle UL) / (1 - f) - EFFR``. A reserve funded from interest whose
    surplus is returned to lenders does not change this expectation and is therefore omitted.
    """
    el = np.asarray(expected_loss(pd, lgd))
    ul = np.asarray(unexpected_loss(pd, rho, q, lgd))
    return _as_float_or_array((effr / utilisation + el + hurdle * ul) / (1 - fee) - effr)


def max_pd_for_premium(premium, hurdle, rho=None, lgd=1.0, q=0.999, pd_lo=1e-5, utilisation=None, fee=PROTOCOL_FEE, effr=EFFR):
    """Largest annual PD whose break-even premium does not exceed ``premium``.

    Loan level (``utilisation=None``): ``EL + hurdle UL_q``. Pool level (``utilisation`` given):
    :func:`pool_breakeven_premium`. ``rho=None`` uses the Basel other-retail correlation of each
    candidate PD. Returns 0.0 if no PD >= ``pd_lo`` qualifies. The loan-level premium is at
    least EL = PD LGD and the pool-level one at least that, so the root lies below ``premium/lgd``.
    """

    def excess(p):
        r = resolve_rho(p, rho)
        if utilisation is None:
            return float(breakeven_premium(p, r, hurdle, lgd, q)) - premium
        return float(pool_breakeven_premium(p, r, hurdle, lgd, q, utilisation, fee, effr)) - premium

    hi = min(premium / lgd, 0.999)
    grid = np.geomspace(pd_lo, hi, 400)
    vals = np.array([excess(p) for p in grid])
    if vals[0] > 0:
        return 0.0
    above = np.nonzero(vals > 0)[0]
    if above.size == 0:
        return float(hi)
    i = above[0]
    return float(optimize.brentq(excess, grid[i - 1], grid[i], xtol=1e-12))


# ───────────────────────────── lender returns and reserve ─────────────────────────────


def lender_apy(loss_rate, utilisation=0.85, apr=APR, fee=PROTOCOL_FEE, reserve_share=0.0, reserve_opening=0.0, release=False):
    """Lenders' one-year return per unit of deposits for a realised loss rate per unit exposure.

    ``APY = u APR (1 - f - r) - max(u L - R, 0)`` with first-loss reserve ``R = R0 + u APR r``
    (``R0`` = opening reserve per unit of deposits). With ``release=True`` the unused reserve is
    paid to lenders at year end, which gives ``u APR (1 - f) - u L``, identical to no reserve.
    Simple (non-compounded) rate; no interest lost on defaulted loans; timing within the year
    ignored (the reserve's inflow is available before the year's losses are charged).
    """
    L = np.asarray(loss_rate, dtype=float)
    R = reserve_opening + utilisation * apr * reserve_share
    hit = np.maximum(utilisation * L - R, 0.0)
    apy = utilisation * apr * (1 - fee - reserve_share) - hit
    if release:
        apy = apy + np.maximum(R - utilisation * L, 0.0)
    return _as_float_or_array(apy)


def lender_apy_stats(pd, rho, lgd=1.0, utilisation=0.85, apr=APR, fee=PROTOCOL_FEE, reserve_share=0.0, reserve_opening=0.0, effr=EFFR, low_q=0.01):
    """Expected lender APY, its ``low_q`` percentile and shortfall probabilities (ASRF, reserve retained).

    Expected hit to lenders uses the closed-form stop-loss transform:
    ``E[(u L - R)^+] = u LGD E[(D - R/(u LGD))^+]``. APY is decreasing in L, so its 1st percentile
    is the APY at the 99th loss percentile.
    """
    u = utilisation
    R = reserve_opening + u * apr * reserve_share
    income = u * apr * (1 - fee - reserve_share)
    k = R / (u * lgd) if lgd > 0 else math.inf
    exp_hit = u * lgd * stop_loss(pd, rho, k) if lgd > 0 else 0.0
    l_low = float(loss_quantile(pd, rho, 1 - low_q, lgd))
    apy_low = float(lender_apy(l_low, u, apr, fee, reserve_share, reserve_opening))

    def prob_apy_below(level):
        # APY < level  <=>  (u L - R)^+ > income - level
        m = income - level
        if m < 0:
            return 1.0
        if lgd <= 0:
            return 0.0
        return float(1.0 - vasicek_cdf(min((m + R) / (u * lgd), 1.0), pd, rho))

    return {
        "expected_apy": income - exp_hit,
        "apy_low": apy_low,
        "p_apy_below_0": prob_apy_below(0.0),
        "p_apy_below_effr": prob_apy_below(effr),
        "p_lender_loss": prob_lender_loss(pd, rho, lgd, R / u),
    }


def reserve_share_for_target(target_loss_rate, apr=APR):
    """Share of interest (reserveBps / 10000) whose one-year inflow equals ``target_loss_rate``.

    Inflow per unit of deposits is ``u APR r`` and the losses to cover are ``u L``, so utilisation
    cancels: ``r = L_target / APR``. Values above ``1 - fee`` cannot be funded from interest.
    """
    return _as_float_or_array(np.asarray(target_loss_rate, float) / apr)


def prob_lender_loss(pd, rho, lgd, reserve_per_exposure):
    """P(lenders bear any loss in the year) = P(LGD D > reserve per unit exposure) (ASRF)."""
    if lgd <= 0:
        return 0.0
    k = reserve_per_exposure / lgd
    if k >= 1:
        return 0.0
    if k <= 0:
        return 1.0
    return float(1.0 - vasicek_cdf(k, pd, rho))


# ───────────────────────────── stale share price (run) ─────────────────────────────


def stale_nav_transfer(exit_share, overdue_exposure, pool_assets, loss_given_overdue=1.0):
    """Value an early exiter extracts when overdue loans are carried at par until write-off.

    A lender holding fraction ``w`` of the shares exits at ``w A`` while the pool still counts an
    overdue exposure ``X`` at par; the fair (impaired) claim is ``w (A - l X)`` where ``l`` is the
    expected loss on the overdue exposure. The excess, borne by the remaining lenders, is
    ``w l X``. Returns a dict with the transfer and the stayers' loss rate with and without it.
    """
    w, X, A, l = exit_share, overdue_exposure, pool_assets, loss_given_overdue
    if not (0 <= w < 1 and 0 <= X <= A and A > 0):
        raise ValueError("need 0 <= w < 1 and 0 <= X <= A, A > 0")
    return {
        "transfer": w * l * X,
        "exit_paid": w * A,
        "exit_fair": w * (A - l * X),
        "stayer_loss_rate": l * X / ((1 - w) * A),
        "pro_rata_loss_rate": l * X / A,
    }
