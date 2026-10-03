"""Monte Carlo for the one-factor Gaussian copula with a finite pool of equal loans.

Every simulator takes an explicit ``seed`` and uses ``numpy.random.default_rng`` (PCG64), so
results are reproducible bit for bit on the same numpy version.

* :func:`simulate_loss_rates` draws the factor ``Z`` and then the number of defaults among
  ``n_loans`` equal loans as ``Binomial(n_loans, p(Z))``. This is exact, not an approximation:
  conditional on ``Z`` the copula's defaults are independent with probability ``p(Z)``.
* :func:`simulate_loss_rates_bruteforce` draws every obligor's latent variable
  ``sqrt(rho) Z + sqrt(1 - rho) eps_i`` and thresholds it. It exists to check the first one.
* :func:`simulate_revolving_year` rolls 30-day loans through the year with the factor held fixed,
  either without replacement (the static Basel view) or replacing each defaulter after the
  ``LATE_PERIOD`` write-off lag.
* :func:`simulate_reserve_paths` runs a multi-year first-loss reserve with a cap.
"""

from __future__ import annotations

import math

import numpy as np
from scipy.stats import binom, norm

import vasicek as vs


def rng_for(seed) -> np.random.Generator:
    """Generator for an int or a tuple of ints (hashed through SeedSequence)."""
    entropy = list(seed) if isinstance(seed, (tuple, list)) else [int(seed)]
    return np.random.default_rng(np.random.SeedSequence(entropy))


def simulate_loss_rates(pd, rho, n_loans, n_scenarios, lgd=1.0, seed=0):
    """Loss rates (fraction of pool exposure) for ``n_scenarios`` one-year scenarios.

    ``n_loans`` equal loans, annual PD ``pd``, asset correlation ``rho``, deterministic LGD.
    """
    rng = rng_for(seed)
    z = rng.standard_normal(n_scenarios)
    p = vs.conditional_pd(pd, rho, z)
    k = rng.binomial(n_loans, p)
    return lgd * k / n_loans


def simulate_loss_rates_bruteforce(pd, rho, n_loans, n_scenarios, lgd=1.0, seed=0, chunk=2000):
    """Same distribution as :func:`simulate_loss_rates`, drawing each obligor's latent variable."""
    rng = rng_for(seed)
    c = norm.ppf(pd)
    sr, si = math.sqrt(rho), math.sqrt(1 - rho)
    out = np.empty(n_scenarios)
    for start in range(0, n_scenarios, chunk):
        m = min(chunk, n_scenarios - start)
        z = rng.standard_normal((m, 1))
        eps = rng.standard_normal((m, n_loans))
        out[start : start + m] = np.count_nonzero(sr * z + si * eps < c, axis=1)
    return lgd * out / n_loans


def empirical_quantile(x, q):
    """VaR-style quantile ``inf{v : F_n(v) >= q}`` (numpy method 'inverted_cdf')."""
    return float(np.quantile(np.asarray(x), q, method="inverted_cdf"))


def quantile_ci(x, q, level=0.95):
    """Distribution-free confidence interval for the q-quantile from order statistics.

    With M i.i.d. draws the number below the true quantile is Binomial(M, q); the interval
    ``[x_(j), x_(k)]`` with j, k the binomial ``(1 -+ level)/2`` quantiles has coverage of at least
    ``level`` (conservative for discrete distributions).
    """
    xs = np.sort(np.asarray(x))
    m = xs.size
    a = (1 - level) / 2
    j = int(binom.ppf(a, m, q))
    k = int(binom.ppf(1 - a, m, q))
    j = max(j - 1, 0)
    k = min(k, m - 1)
    return float(xs[j]), float(xs[k])


def summarise(losses, quantiles=(0.99, 0.995, 0.999)):
    """Mean, standard deviation, quantiles and 95% order-statistic CIs of simulated loss rates."""
    x = np.asarray(losses)
    out = {"mean": float(x.mean()), "sd": float(x.std(ddof=1)), "mean_se": float(x.std(ddof=1) / math.sqrt(x.size))}
    for q in quantiles:
        lo, hi = quantile_ci(x, q)
        out[f"q{q}"] = empirical_quantile(x, q)
        out[f"q{q}_lo"] = lo
        out[f"q{q}_hi"] = hi
    return out


def simulate_revolving_year(pd, rho, n_slots, n_scenarios, cycles=12, lag_cycles=1, replace=True, seed=0):
    """One year of back-to-back loans in ``n_slots`` equal slots, factor fixed for the year.

    The year is split into ``cycles`` loan terms (12 terms of 365/12 days, close to the 30-day
    default term). Conditional on ``Z``, each loan defaults with ``1 - (1 - p(Z)) ** (1/cycles)``,
    so a borrower who survives and rolls all year defaults with the Vasicek conditional annual PD
    ``p(Z)`` (constant hazard, independent across cycles given Z).

    ``replace=False`` is the static view: a defaulted borrower is blocked and its slot stays
    empty. ``replace=True``: a loan defaulting at the end of cycle m is written off
    ``lag_cycles`` later (LATE_PERIOD = 30 days, about one term) and the slot is re-lent from the
    following cycle to a new borrower with the same PD. Returns ``(default_rate, active_share)``
    per scenario: defaults per slot and the average share of slot-cycles that were lent.
    """
    rng = rng_for(seed)
    z = rng.standard_normal(n_scenarios)
    p_year = np.clip(vs.conditional_pd(pd, rho, z), 0.0, 1 - 1e-15)
    p_cycle = -np.expm1(np.log1p(-p_year) / cycles)
    active = np.full(n_scenarios, n_slots, dtype=np.int64)
    returning = np.zeros((cycles + lag_cycles + 2, n_scenarios), dtype=np.int64)
    defaults = np.zeros(n_scenarios, dtype=np.int64)
    active_sum = np.zeros(n_scenarios, dtype=np.int64)
    for m in range(cycles):
        active += returning[m]
        active_sum += active
        k = rng.binomial(active, p_cycle)
        defaults += k
        active -= k
        if replace:
            returning[m + 1 + lag_cycles] += k
    return defaults / n_slots, active_sum / (n_slots * cycles)


def simulate_reserve_paths(pd, rho, years, n_paths, reserve_share, cap, apr=vs.APR, utilisation=0.85, lgd=1.0, opening=0.0, seed=0):
    """Multi-year first-loss reserve with independent annual factors, infinitely granular pool.

    Per unit of deposits each year: inflow ``u APR r``; loss ``u LGD D_t`` with D_t from the
    Vasicek distribution (independent years, an optimistic assumption); the reserve pays first
    and lenders take ``max(u LGD D_t - B_{t-1} - inflow, 0)``; the balance is then capped at
    ``cap`` with the excess released to lenders. Returns ``(lender_loss, balance)``, arrays of
    shape (years, n_paths).
    """
    rng = rng_for(seed)
    u = utilisation
    inflow = u * apr * reserve_share
    bal = np.full(n_paths, float(opening))
    lender_loss = np.empty((years, n_paths))
    balances = np.empty((years, n_paths))
    for t in range(years):
        d = vs.conditional_pd(pd, rho, rng.standard_normal(n_paths))
        loss = u * lgd * d
        avail = bal + inflow
        lender_loss[t] = np.maximum(loss - avail, 0.0)
        bal = np.minimum(np.maximum(avail - loss, 0.0), cap)
        balances[t] = bal
    return lender_loss, balances
