"""Reproduce every table and figure of the credit-risk calibration.

    cd analysis/credit_risk && python3 run.py

Writes results/*.csv, results/summary.md and figures/*.png. Deterministic: every Monte Carlo
draw is seeded from BASE_SEED and a fixed per-experiment tag.
"""

from __future__ import annotations

import csv
import math
import os
import time

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
from scipy.stats import norm  # noqa: E402

import montecarlo as mc  # noqa: E402
import vasicek as vs  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "results")
FIGURES = os.path.join(HERE, "figures")

BASE_SEED = 20261003
PD_GRID = [0.01, 0.03, 0.05, 0.10, 0.20]
RHO_GRID = [0.02, 0.05, 0.10, 0.15, 0.20, 0.30]
RHO_CASES = ["basel"] + RHO_GRID
Q_LEVELS = [0.99, 0.995, 0.999]
HURDLES = [0.10, 0.15, 0.25]
BASE_HURDLE = 0.15
N_GRID = [100, 500, 5000]
TERMS = [7, 30, 90, 365]
LOAN_PD_GRID = [0.001, 0.0025, 0.005, 0.01, 0.02, 0.03, 0.05, 0.10]
U_BASE = 0.85
U_CAP = vs.UTILISATION_CAP
PREMIUM = vs.RISK_PREMIUM
REC_PDS = [0.03, 0.05, 0.10]  # bottom-line range
REC_N = 500  # pool size used for the granularity add-on in the recommendation
REC_BUILD_YEARS = 3  # years over which the reserve should reach its 99% buffer
M_GRAN = 1_000_000
M_REVOLVE = 400_000
M_RESERVE = 200_000

# chart palette (dataviz reference instance, light mode; validated)
SURFACE, INK, INK2, MUTED, GRID, AXIS = "#fcfcfb", "#0b0b0b", "#52514e", "#898781", "#e1e0d9", "#c3c2b7"
CAT = ["#2a78d6", "#eb6834", "#1baf7a"]
ORD5 = ["#86b6ef", "#5598e7", "#2a78d6", "#1c5cab", "#0d366b"]
ORD3 = ["#6da7ec", "#256abf", "#0d366b"]


def rho_of(pd, case):
    return float(vs.basel_other_retail_correlation(pd)) if case == "basel" else float(case)


def rho_label(case):
    return "Basel" if case == "basel" else f"{case:g}"


def bps(x):
    return 1e4 * x


def ceil_to(x, step):
    return step * math.ceil(x / step - 1e-9)


def fmt(v):
    if isinstance(v, (bool, np.bool_)):
        return "yes" if v else "no"
    if isinstance(v, (float, np.floating)):
        return f"{float(v):.6g}"
    return v


def write_csv(name, rows):
    path = os.path.join(RESULTS, name)
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        for r in rows:
            w.writerow({k: fmt(v) for k, v in r.items()})
    return path


def md_table(header, rows):
    out = ["| " + " | ".join(header) + " |", "|" + "|".join("---:" if i else "---" for i in range(len(header))) + "|"]
    out += ["| " + " | ".join(str(c) for c in r) + " |" for r in rows]
    return "\n".join(out)


def pct(x, d=1):
    return f"{100 * x:.{d}f}%"


# ───────────────────────────── 1. PD horizons and correlation ─────────────────────────────


def pd_conversion():
    rows = []
    for pd in PD_GRID:
        r = {"annual_pd": pd, "hazard_per_year": vs.hazard_rate(pd)}
        for t in TERMS:
            r[f"loan_pd_{t}d"] = vs.loan_pd_from_annual_pd(pd, t)
        r["replenished_defaults_per_exposure_year_30d"] = vs.replenished_default_rate(pd, 30)
        rows.append(r)
    write_csv("pd_annual_to_loan.csv", rows)
    rows2 = []
    for p in LOAN_PD_GRID:
        rows2.append({
            "loan_pd_30d": p,
            "annual_pd": vs.annual_pd_from_loan_pd(p, 30),
            "defaults_per_exposure_year_replenished": vs.cycles_per_year(30) * p,
            "cycles_per_year": vs.cycles_per_year(30),
        })
    write_csv("pd_loan_to_annual.csv", rows2)
    write_csv("basel_correlation.csv", [{"annual_pd": pd, "rho_basel_other_retail": vs.basel_other_retail_correlation(pd)} for pd in PD_GRID])
    return rows, rows2


# ───────────────────────────── 2. Vasicek losses ─────────────────────────────


def vasicek_table():
    rows = []
    for pd in PD_GRID:
        for case in RHO_CASES:
            rho = rho_of(pd, case)
            r = {"annual_pd": pd, "rho_case": rho_label(case), "rho": rho, "el": vs.expected_loss(pd), "sd": math.sqrt(vs.vasicek_variance(pd, rho))}
            for q in Q_LEVELS:
                r[f"q{q}"] = vs.loss_quantile(pd, rho, q)
            for q in Q_LEVELS:
                r[f"ul{q}"] = vs.unexpected_loss(pd, rho, q)
            r["es0.999"] = vs.expected_shortfall(pd, rho, 0.999)
            r["el_replenished"] = vs.replenished_expected_loss(pd, rho)
            r["q0.999_replenished"] = vs.replenished_loss_quantile(pd, rho, 0.999)
            rows.append(r)
    write_csv("vasicek_losses.csv", rows)
    return rows


# ───────────────────────────── 3. Monte Carlo ─────────────────────────────


def mc_granularity():
    rows = []
    for i, pd in enumerate(PD_GRID):
        for j, case in enumerate(["basel", 0.15]):
            rho = rho_of(pd, case)
            c = float(norm.ppf(pd))
            c2 = vs.bivariate_normal_cdf(c, c, rho)
            for k, n in enumerate(N_GRID):
                losses = mc.simulate_loss_rates(pd, rho, n, M_GRAN, seed=(BASE_SEED, 1, i, j, k))
                s = mc.summarise(losses, Q_LEVELS)
                r = {"annual_pd": pd, "rho_case": rho_label(case), "rho": rho, "n_loans": n, "scenarios": M_GRAN,
                     "mc_mean": s["mean"], "mc_mean_se": s["mean_se"], "mc_sd": s["sd"],
                     "sd_exact_finite_n": math.sqrt(c2 - pd * pd + (pd - c2) / n), "sd_asrf": math.sqrt(c2 - pd * pd)}
                for q in Q_LEVELS:
                    asrf = vs.loss_quantile(pd, rho, q)
                    ga = vs.granularity_adjustment(pd, rho, q, n)
                    r[f"asrf_q{q}"] = asrf
                    r[f"asrf_ga_q{q}"] = asrf + ga
                    r[f"mc_q{q}"] = s[f"q{q}"]
                    r[f"mc_q{q}_ci_lo"] = s[f"q{q}_lo"]
                    r[f"mc_q{q}_ci_hi"] = s[f"q{q}_hi"]
                rows.append(r)
    write_csv("mc_granularity.csv", rows)
    return rows


def mc_bruteforce_check():
    pd, rho = 0.05, float(vs.basel_other_retail_correlation(0.05))
    rows = []
    for k, (n, m) in enumerate([(500, 60_000), (5000, 12_000)]):
        bf = mc.simulate_loss_rates_bruteforce(pd, rho, n, m, seed=(BASE_SEED, 2, k), chunk=1000)
        bi = mc.simulate_loss_rates(pd, rho, n, m, seed=(BASE_SEED, 3, k))
        for name, x in (("bruteforce", bf), ("binomial", bi)):
            s = mc.summarise(x, (0.99,))
            rows.append({"method": name, "annual_pd": pd, "rho": rho, "n_loans": n, "scenarios": m, "mean": s["mean"], "mean_se": s["mean_se"],
                         "sd": s["sd"], "q0.99": s["q0.99"], "q0.99_ci_lo": s["q0.99_lo"], "q0.99_ci_hi": s["q0.99_hi"],
                         "asrf_ga_q0.99": vs.loss_quantile(pd, rho, 0.99) + vs.granularity_adjustment(pd, rho, 0.99, n)})
    write_csv("mc_bruteforce_check.csv", rows)
    return rows


def revolving_vs_static():
    rows = []
    for i, pd in enumerate(PD_GRID):
        rho = float(vs.basel_other_retail_correlation(pd))
        st, _ = mc.simulate_revolving_year(pd, rho, REC_N, M_REVOLVE, replace=False, seed=(BASE_SEED, 4, i))
        rp, act = mc.simulate_revolving_year(pd, rho, REC_N, M_REVOLVE, replace=True, seed=(BASE_SEED, 4, i))
        rows.append({
            "annual_pd": pd, "rho": rho, "n_slots": REC_N, "scenarios": M_REVOLVE,
            "static_mc_mean": st.mean(), "static_mc_q0.999": mc.empirical_quantile(st, 0.999),
            "static_asrf_ga_q0.999": vs.loss_quantile(pd, rho, 0.999) + vs.granularity_adjustment(pd, rho, 0.999, REC_N),
            "replenished_mc_mean": rp.mean(), "replenished_mc_q0.999": mc.empirical_quantile(rp, 0.999),
            "replenished_asrf_el": vs.replenished_expected_loss(pd, rho), "replenished_asrf_q0.999": vs.replenished_loss_quantile(pd, rho, 0.999),
            "replenished_mean_active_share": act.mean(),
        })
    write_csv("revolving_vs_static.csv", rows)
    return rows


# ───────────────────────────── 4. Pricing ─────────────────────────────


def pricing():
    rows = []
    for pd in PD_GRID:
        for case in RHO_CASES:
            rho = rho_of(pd, case)
            el, ul = vs.expected_loss(pd), vs.unexpected_loss(pd, rho, 0.999)
            el_rep = vs.replenished_expected_loss(pd, rho)
            ul_rep = vs.replenished_loss_quantile(pd, rho, 0.999) - el_rep
            for h in HURDLES:
                s = vs.breakeven_premium(pd, rho, h)
                rows.append({
                    "annual_pd": pd, "loan_pd_30d": vs.loan_pd_from_annual_pd(pd, 30), "rho_case": rho_label(case), "rho": rho, "hurdle": h,
                    "el": el, "ul0.999": ul, "s_star": s, "s_star_bps": bps(s), "adequate_at_500bps": s <= PREMIUM,
                    "s_star_replenished_bps": bps(el_rep + h * ul_rep),
                    "s_star_ga_n500_bps": bps(el + h * (ul + vs.granularity_adjustment(pd, rho, 0.999, 500))),
                    "s_star_ga_n100_bps": bps(el + h * (ul + vs.granularity_adjustment(pd, rho, 0.999, 100))),
                    "s_pool_u85_bps": bps(vs.pool_breakeven_premium(pd, rho, h, utilisation=0.85)),
                    "s_pool_u90_bps": bps(vs.pool_breakeven_premium(pd, rho, h, utilisation=0.90)),
                    "s_pool_u85_fee10_bps": bps(vs.pool_breakeven_premium(pd, rho, h, utilisation=0.85, fee=0.10)),
                })
    write_csv("breakeven_premium.csv", rows)

    rows2 = []
    for case in RHO_CASES:
        rho = None if case == "basel" else case
        for h in [0.0] + HURDLES:
            p_loan = vs.max_pd_for_premium(PREMIUM, h, rho)
            p_pool = vs.max_pd_for_premium(PREMIUM, h, rho, utilisation=U_BASE)
            rows2.append({
                "rho_case": rho_label(case), "hurdle": h,
                "max_annual_pd_loan_level": p_loan, "max_loan_pd_30d_loan_level": vs.loan_pd_from_annual_pd(p_loan, 30),
                "max_annual_pd_pool_u85": p_pool, "max_loan_pd_30d_pool_u85": vs.loan_pd_from_annual_pd(p_pool, 30),
            })
    write_csv("max_pd_for_500bps.csv", rows2)
    return rows, rows2


# ───────────────────────────── 5. Lender APY ─────────────────────────────


def foregone_interest_bound(pd, utilisation=U_BASE, apr=vs.APR, term=vs.DEFAULT_TERM_DAYS):
    """Expected APY lost to interest never received on defaulting loans (term + LATE_PERIOD)."""
    return utilisation * pd * apr * (term + vs.LATE_PERIOD_DAYS) / vs.DAYS_PER_YEAR


def lender_apy_table():
    rows = []
    for pd in PD_GRID:
        for case in ["basel", 0.15]:
            rho = rho_of(pd, case)
            for label, r in (("none", 0.0), ("covers_EL", pd / vs.APR)):
                r_eff = min(r, 1.0)
                st = vs.lender_apy_stats(pd, rho, utilisation=U_BASE, reserve_share=r_eff)
                rows.append({"annual_pd": pd, "rho_case": rho_label(case), "rho": rho, "utilisation": U_BASE, "apr": vs.APR, "fee": vs.PROTOCOL_FEE,
                             "reserve_policy": label, "reserve_share": r_eff, "expected_apy": st["expected_apy"], "apy_p1": st["apy_low"],
                             "p_apy_below_0": st["p_apy_below_0"], "p_apy_below_effr": st["p_apy_below_effr"], "p_lender_loss": st["p_lender_loss"],
                             "foregone_interest_bound": foregone_interest_bound(pd)})
    write_csv("lender_apy.csv", rows)
    return rows


# ───────────────────────────── 6. Security mix ─────────────────────────────


def security_mix():
    rows = []
    for pd in PD_GRID:
        rho = float(vs.basel_other_retail_correlation(pd))
        s0 = vs.breakeven_premium(pd, rho, BASE_HURDLE)
        for s in np.round(np.linspace(0, 1, 11), 2):
            rows.append({"annual_pd": pd, "rho": rho, "hurdle": BASE_HURDLE, "secured_share": s, "lgd_effective": 1 - s,
                         "s_star_bps": bps((1 - s) * s0), "min_secured_share_for_500bps": max(0.0, 1 - PREMIUM / s0)})
    write_csv("secured_share.csv", rows)

    rows2 = []
    for pd in PD_GRID:
        for m in [1.0, 0.75, 0.5, 0.25]:
            for case in ["basel", 0.15]:
                pde = m * pd
                rho = rho_of(pde, case)
                for s in [0.0, 0.25, 0.5]:
                    rows2.append({"annual_pd": pd, "pd_multiplier": m, "effective_pd": pde, "rho_case": rho_label(case), "rho": rho, "secured_share": s,
                                  "hurdle": BASE_HURDLE, "s_star_bps": bps(vs.breakeven_premium(pde, rho, BASE_HURDLE, lgd=1 - s)) if s < 1 else 0.0})
    write_csv("backing_pd_multiplier.csv", rows2)
    return rows, rows2


# ───────────────────────────── 7. Reserve ─────────────────────────────


def reserve_sizing():
    rows = []
    for pd in PD_GRID:
        for case in RHO_CASES:
            rho = rho_of(pd, case)
            el = vs.expected_loss(pd)
            l95, l99 = vs.loss_quantile(pd, rho, 0.95), vs.loss_quantile(pd, rho, 0.99)
            targets = {"EL": el, "L95-EL": l95 - el, "L99-EL": l99 - el, "L95": l95, "L99": l99}
            apr_be = vs.EFFR + vs.breakeven_premium(pd, rho, BASE_HURDLE)
            r = {"annual_pd": pd, "rho_case": rho_label(case), "rho": rho, "el": el, "l95": l95, "l99": l99, "apr_deployed": vs.APR, "apr_breakeven_h15": apr_be}
            for name, t in targets.items():
                r[f"r_{name}_deployed"] = vs.reserve_share_for_target(t)
                r[f"r_{name}_breakeven"] = vs.reserve_share_for_target(t, apr_be)
                r[f"p_lender_loss_{name}"] = vs.prob_lender_loss(pd, rho, 1.0, t)
                r[f"feasible_{name}_deployed"] = t / vs.APR <= 1 - vs.PROTOCOL_FEE
            rows.append(r)
    write_csv("reserve_sizing.csv", rows)
    return rows


def reserve_paths(recs):
    rows = []
    years = 10
    for i, rec in enumerate(recs):
        pd, rho, apr = rec["pd"], rec["rho"], rec["apr"]
        for j, (label, share) in enumerate((("covers_EL", rec["r_el"]), ("recommended", rec["r_rec"]))):
            ll, bal = mc.simulate_reserve_paths(pd, rho, years, M_RESERVE, share, rec["cap"], apr=apr, utilisation=U_BASE, seed=(BASE_SEED, 5, i))
            for t in range(years):
                rows.append({"annual_pd": pd, "rho": rho, "apr": apr, "policy": label, "reserve_share": share, "cap_per_deposit": rec["cap"], "year": t + 1,
                             "p_lender_loss": float((ll[t] > 1e-12).mean()), "mean_lender_loss": float(ll[t].mean()),
                             "mean_balance_over_cap": float(bal[t].mean() / rec["cap"]), "p_balance_at_cap": float((bal[t] >= rec["cap"] - 1e-12).mean())})
    write_csv("reserve_paths.csv", rows)
    return rows


# ───────────────────────────── 8. Run transfer ─────────────────────────────


def run_transfer():
    rows = []
    A = 10_000.0
    for x_share in [0.01, 0.02, 0.05]:
        for w in [0.05, 0.20, 0.50]:
            t = vs.stale_nav_transfer(w, x_share * A, A)
            rows.append({"pool_assets": A, "overdue_share": x_share, "exit_share": w, **t})
    write_csv("run_transfer.csv", rows)
    rows2 = []
    for pd in PD_GRID:
        lam = vs.hazard_rate(pd)
        rows2.append({"annual_pd": pd, "utilisation": U_BASE, "late_period_days": vs.LATE_PERIOD_DAYS,
                      "overdue_stock_share_of_assets": lam * U_BASE * vs.LATE_PERIOD_DAYS / vs.DAYS_PER_YEAR})
    write_csv("overdue_stock.csv", rows2)
    return rows, rows2


# ───────────────────────────── 9. Recommendation ─────────────────────────────


def recommendation(case="basel"):
    """Premium and reserve for PD 3-10% at the Basel correlation, h = 15%, u = 0.85, f = 0.

    Premium: the pool-level break-even (cash drag included) evaluated on the replenished loss
    distribution, with the N = 500 granularity add-on applied to the 99.9% quantile, rounded up
    to 50 bps. Reserve (static ASRF, as in reserve_sizing): cover EL each year plus build the 99%
    unexpected-loss buffer over REC_BUILD_YEARS years, rounded up to 5% of interest; cap the
    balance at u (L99 - EL) per unit of deposits.
    """
    recs = []
    for pd in REC_PDS:
        rho = rho_of(pd, case)
        el = vs.replenished_expected_loss(pd, rho)
        q999 = vs.replenished_loss_quantile(pd, rho, 0.999) + vs.granularity_adjustment(pd, rho, 0.999, REC_N)
        ul = q999 - el
        s_pool = (vs.EFFR / U_BASE + el + BASE_HURDLE * ul) - vs.EFFR
        s_rec = ceil_to(s_pool, 0.005)
        apr = vs.EFFR + s_rec
        el_s = vs.expected_loss(pd)
        l99 = vs.loss_quantile(pd, rho, 0.99)
        r_el = el_s / apr
        r_rec = ceil_to((el_s + (l99 - el_s) / REC_BUILD_YEARS) / apr, 0.05)
        cap = U_BASE * (l99 - el_s)
        st0 = vs.lender_apy_stats(pd, rho, utilisation=U_BASE, apr=apr, reserve_share=0.0)
        recs.append({
            "pd": pd, "loan_pd_30d": vs.loan_pd_from_annual_pd(pd, 30), "rho_case": rho_label(case), "rho": rho,
            "s_loan_asrf_bps": bps(vs.breakeven_premium(pd, rho, BASE_HURDLE)),
            "s_pool_asrf_bps": bps(vs.pool_breakeven_premium(pd, rho, BASE_HURDLE, utilisation=U_BASE)),
            "s_pool_rep_ga_bps": bps(s_pool), "s_rec_bps": bps(s_rec), "apr": apr,
            "r_el": r_el, "r_rec": r_rec, "cap": cap,
            "p_loss_year1_rec": vs.prob_lender_loss(pd, rho, 1.0, r_rec * apr),
            "expected_apy_rec": st0["expected_apy"], "apy_p1_rec": st0["apy_low"], "p_apy_below_effr_rec": st0["p_apy_below_effr"],
            # yield forgone if a full reserve (at its cap) sits in idle USDC instead of the pool
            "idle_reserve_cost": cap * st0["expected_apy"],
        })
    return recs


# ───────────────────────────── figures ─────────────────────────────


def _style():
    plt.rcParams.update({
        "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
        "axes.edgecolor": AXIS, "axes.labelcolor": INK2, "axes.titlecolor": INK, "axes.titlesize": 11, "axes.titleweight": "bold",
        "axes.labelsize": 9.5, "xtick.color": MUTED, "ytick.color": MUTED, "xtick.labelcolor": INK2, "ytick.labelcolor": INK2,
        "xtick.labelsize": 8.5, "ytick.labelsize": 8.5, "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.6,
        "grid.linestyle": "-", "axes.spines.top": False, "axes.spines.right": False, "lines.linewidth": 2.0,
        "legend.frameon": False, "legend.fontsize": 8.5, "font.size": 9.5, "text.color": INK,
    })


def _pct_axis(ax, which="y", decimals=0, step=None):
    from matplotlib.ticker import FuncFormatter, MultipleLocator

    axis = ax.yaxis if which == "y" else ax.xaxis
    if step is not None:
        axis.set_major_locator(MultipleLocator(step))
    axis.set_major_formatter(FuncFormatter(lambda v, _: f"{100 * v:.{decimals}f}%"))


def _end_label(ax, x, y, text, color=INK2, dy=0.0):
    ax.annotate(text, (x, y), xytext=(4, dy), textcoords="offset points", va="center", fontsize=8, color=color)


def _save(fig, name):
    path = os.path.join(FIGURES, name)
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    return path


def fig_loss_distribution():
    pd = 0.05
    xs = np.linspace(1e-4, 0.60, 2000)
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(10.5, 4.0))
    for color, case in zip(CAT, ["basel", 0.15, 0.30]):
        rho = rho_of(pd, case)
        lab = f"rho = {rho:.3f} (Basel)" if case == "basel" else f"rho = {rho:.2f}"
        a1.plot(xs, vs.vasicek_pdf(xs, pd, rho), color=color, label=lab)
        sf = 1 - vs.vasicek_cdf(xs, pd, rho)
        a2.plot(xs, sf, color=color, label=lab)
        q = vs.loss_quantile(pd, rho, 0.999)
        a2.plot([q], [0.001], "o", color=color, ms=6, mec=SURFACE, mew=1.5)
        a2.annotate(pct(q), (q, 0.001), xytext=(-5, -10), textcoords="offset points", ha="right", fontsize=8, color=INK2)
    a1.axvline(pd, color=MUTED, lw=1, ls="--")
    a1.annotate("EL = PD = 5%", (pd, 21), xytext=(4, 0), textcoords="offset points", fontsize=8, color=INK2)
    a1.set_ylim(0, 22)
    a1.set_xlim(0, 0.30)
    _pct_axis(a1, "x", step=0.05)
    a1.set_xlabel("Annual default rate D (= loss rate at LGD 100%)")
    a1.set_ylabel("Density (rho = 0.30 spikes near 0, clipped)")
    a1.set_title("Density")
    a1.legend(loc="upper right")
    for lvl, txt in ((0.01, "1%"), (0.001, "0.1%")):
        a2.axhline(lvl, color=MUTED, lw=1, ls="--")
        a2.annotate(f"{txt} exceedance", (0.60, lvl), xytext=(-2, 4), textcoords="offset points", ha="right", fontsize=8, color=INK2)
    a2.set_yscale("log")
    a2.set_ylim(1e-4, 1.2)
    a2.set_xlim(0, 0.60)
    _pct_axis(a2, "x", step=0.10)
    a2.set_xlabel("Annual default rate D")
    a2.set_ylabel("P(D > x), log scale")
    a2.set_title("Tail: dots mark the 99.9% quantile")
    fig.suptitle("Vasicek loss distribution, annual PD 5%", fontsize=11, fontweight="bold", color=INK)
    return _save(fig, "loss_distribution.png")


def fig_granularity(gran_rows):
    fig, ax = plt.subplots(figsize=(7, 4))
    basel = [r for r in gran_rows if r["rho_case"] == "Basel"]
    for color, pd in zip(ORD5, PD_GRID):
        rs = sorted([r for r in basel if r["annual_pd"] == pd], key=lambda r: r["n_loans"])
        n = np.array([r["n_loans"] for r in rs])
        base = np.array([r["asrf_q0.999"] for r in rs])
        mcq = np.array([r["mc_q0.999"] for r in rs]) / base
        lo = np.array([r["mc_q0.999_ci_lo"] for r in rs]) / base
        hi = np.array([r["mc_q0.999_ci_hi"] for r in rs]) / base
        nn = np.geomspace(80, 6500, 100)
        ga = 1 + np.array([vs.granularity_adjustment(pd, rs[0]["rho"], 0.999, k) for k in nn]) / base[0]
        ax.plot(nn, ga, color=color, lw=1.5)
        ax.errorbar(n, mcq, yerr=[mcq - lo, hi - mcq], fmt="o", color=color, ms=6, mec=SURFACE, mew=1.2, capsize=0, lw=1.2, label=f"PD {pct(pd, 0)}")
    ax.axhline(1, color=MUTED, lw=1)
    ax.set_xscale("log")
    ax.set_xticks(N_GRID)
    ax.set_xticklabels([f"{n:,}" for n in N_GRID])
    ax.set_xlabel("Number of equal loans in the pool (log scale)")
    ax.set_ylabel("99.9% loss quantile / ASRF quantile")
    ax.set_title("Granularity: finite pools have fatter tails than the ASRF limit")
    ax.legend(title="Dots: Monte Carlo (95% CI)\nLines: ASRF + granularity adj.", title_fontsize=8, loc="upper right")
    return _save(fig, "granularity.png")


def fig_breakeven():
    pds = np.linspace(0.002, 0.20, 300)
    fig, ax = plt.subplots(figsize=(7, 4.2))
    for color, case in zip(CAT, ["basel", 0.15, 0.30]):
        s = np.array([vs.breakeven_premium(p, rho_of(p, case), BASE_HURDLE) for p in pds])
        ax.plot(pds, s, color=color, label=f"rho = {rho_label(case)}" + (" (other retail)" if case == "basel" else ""))
        _end_label(ax, pds[-1], s[-1], rho_label(case))
    ax.plot(pds, pds, color=MUTED, lw=1.2, label="EL alone (PD x LGD)")
    ax.axhline(PREMIUM, color=INK2, lw=1, ls="--")
    pmax = vs.max_pd_for_premium(PREMIUM, BASE_HURDLE)
    ax.plot([pmax], [PREMIUM], "o", color=CAT[0], ms=7, mec=SURFACE, mew=1.5)
    ax.annotate(f"deployed 500 bps covers annual PD\nup to {pct(pmax, 1)} at the Basel rho", (pmax, PREMIUM), xytext=(0.085, 0.010), textcoords="data", fontsize=8, color=INK2,
                arrowprops=dict(arrowstyle="-", color=MUTED, lw=0.8))
    ax.set_xlim(0, 0.215)
    ax.set_ylim(0, 0.42)
    _pct_axis(ax, "x", step=0.02)
    ax.yaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda v, _: f"{1e4 * v:,.0f}"))
    ax.set_xlabel("Annual PD")
    ax.set_ylabel("Break-even risk premium (bps per year)")
    ax.set_title("Break-even premium EL + 15% x UL(99.9%), LGD 100%")
    ax.legend(loc="upper left")
    return _save(fig, "breakeven_premium.png")


def fig_lender_apy():
    pds = np.linspace(0.002, 0.20, 200)
    fig, ax = plt.subplots(figsize=(7, 4.2))
    rho = lambda p: float(vs.basel_other_retail_correlation(p))  # noqa: E731
    e = np.array([vs.lender_apy_stats(p, rho(p), utilisation=U_BASE)["expected_apy"] for p in pds])
    lo = np.array([vs.lender_apy_stats(p, rho(p), utilisation=U_BASE)["apy_low"] for p in pds])
    ax.plot(pds, e, color=CAT[0], label="Expected APY")
    ax.plot(pds, lo, color=CAT[1], label="1st percentile APY")
    _end_label(ax, pds[-1], e[-1], "expected")
    _end_label(ax, pds[-1], lo[-1], "1st pct")
    ax.axhline(vs.EFFR, color=INK2, lw=1, ls="--")
    ax.annotate("EFFR 4.33%", (0.20, vs.EFFR), xytext=(0, 4), textcoords="offset points", ha="right", fontsize=8, color=INK2)
    ax.axhline(0, color=AXIS, lw=1)
    ax.set_xlim(0, 0.215)
    _pct_axis(ax, "x", step=0.02)
    _pct_axis(ax, "y")
    ax.set_xlabel("Annual PD (Basel other-retail rho)")
    ax.set_ylabel("Lender APY")
    ax.set_title(f"Lender APY at the deployed 9.33% APR (u = {U_BASE:.0%}, fee 0, no reserve)")
    ax.legend(loc="lower left")
    return _save(fig, "lender_apy.png")


def fig_security():
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(10, 4.0), sharey=True)
    ss = np.linspace(0, 1, 101)
    for color, pd in zip(ORD3, REC_PDS):
        rho = float(vs.basel_other_retail_correlation(pd))
        s0 = vs.breakeven_premium(pd, rho, BASE_HURDLE)
        a1.plot(ss, (1 - ss) * s0, color=color, label=f"PD {pct(pd, 0)}")
        _end_label(a1, 0, s0, f"PD {pct(pd, 0)}", dy=-9 if pd == 0.03 else 6)
        ms = np.linspace(0.1, 1, 91)
        a2.plot(ms, [vs.breakeven_premium(m * pd, float(vs.basel_other_retail_correlation(m * pd)), BASE_HURDLE) for m in ms], color=color, label=f"PD {pct(pd, 0)}")
    for ax in (a1, a2):
        ax.axhline(PREMIUM, color=INK2, lw=1, ls="--")
        ax.yaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda v, _: f"{1e4 * v:,.0f}"))
        ax.set_ylim(0, 0.13)
    _end_label(a1, 0.62, PREMIUM, "deployed 500 bps", dy=7)
    _pct_axis(a1, "x")
    a1.set_xlabel("Share of principal secured by staked USDC (LGD 0)")
    a1.set_ylabel("Break-even premium (bps, h = 15%)")
    a1.set_title("Secured backing lowers LGD")
    a2.set_xlabel("PD multiplier from unsecured backing (1 = no effect)")
    a2.set_title("Unsecured backing can only lower PD (hypothesis)")
    a2.invert_xaxis()
    a2.legend(loc="upper right")
    return _save(fig, "security_mix.png")


def fig_reserve():
    pds = np.linspace(0.005, 0.20, 200)
    fig, ax = plt.subplots(figsize=(7, 4.2))
    rho = lambda p: float(vs.basel_other_retail_correlation(p))  # noqa: E731
    series = [
        ("Cover EL", lambda p: p),
        ("Cover L95 - EL", lambda p: vs.loss_quantile(p, rho(p), 0.95) - p),
        ("Cover L99 - EL", lambda p: vs.loss_quantile(p, rho(p), 0.99) - p),
    ]
    ymax = 1.6
    for color, (lab, fn) in zip(CAT, series):
        y = np.array([fn(p) / vs.APR for p in pds])
        ax.plot(pds, y, color=color, label=lab)
        inside = np.nonzero(y <= ymax)[0][-1]
        if inside == len(y) - 1:
            _end_label(ax, pds[-1], y[-1], lab)
        else:
            ax.annotate(lab, (pds[inside], y[inside]), xytext=(-6, -2), textcoords="offset points", ha="right", va="top", fontsize=8, color=INK2)
    ax.axhline(1.0, color=INK2, lw=1, ls="--")
    ax.annotate("100% of interest: not fundable from interest above this line", (0.002, 1.0), xytext=(0, 4), textcoords="offset points", fontsize=8, color=INK2)
    ax.set_xlim(0, 0.215)
    ax.set_ylim(0, ymax)
    _pct_axis(ax, "x", step=0.02)
    _pct_axis(ax, "y")
    ax.set_xlabel("Annual PD (Basel other-retail rho)")
    ax.set_ylabel("reserveBps as a share of interest")
    ax.set_title("Reserve share whose one-year inflow covers the target (APR 9.33%)")
    ax.legend(loc="lower right")
    return _save(fig, "reserve_bps.png")


# ───────────────────────────── summary ─────────────────────────────


def summary_md(conv, conv2, vrows, gran, bf, rev, prem, maxpd, apy, sec, back, res, paths, run_rows, overdue, recs):
    out = ["# Summary tables (generated by run.py)", ""]
    out.append("## PD conversion, 30-day loans (n = 365/30 = 12.17 cycles)")
    out.append(md_table(["annual PD", "per-30d-loan PD", "hazard/yr", "defaults per exposure-yr (replenished)"],
                        [[pct(r["annual_pd"], 0), pct(r["loan_pd_30d"], 3), pct(r["hazard_per_year"], 2), pct(r["replenished_defaults_per_exposure_year_30d"], 2)] for r in conv]))
    out.append("")
    out.append(md_table(["per-30d-loan PD", "annual PD", "defaults per exposure-yr"],
                        [[pct(r["loan_pd_30d"], 2), pct(r["annual_pd"], 1), pct(r["defaults_per_exposure_year_replenished"], 1)] for r in conv2]))
    out.append("\n## ASRF losses at the Basel other-retail correlation (LGD 100%)")
    out.append(md_table(["PD", "rho", "EL", "sd", "q99", "q99.5", "q99.9", "UL99.9 = K", "ES99.9", "q99.9 replenished"],
                        [[pct(r["annual_pd"], 0), f"{r['rho']:.4f}", pct(r["el"]), pct(r["sd"]), pct(r["q0.99"]), pct(r["q0.995"]), pct(r["q0.999"]), pct(r["ul0.999"]), pct(r["es0.999"]), pct(r["q0.999_replenished"])]
                         for r in vrows if r["rho_case"] == "Basel"]))
    out.append("\n## 99.9% quantile by rho (LGD 100%)")
    hdr = ["PD"] + [rho_label(c) for c in RHO_CASES]
    out.append(md_table(hdr, [[pct(pd, 0)] + [pct(next(r["q0.999"] for r in vrows if r["annual_pd"] == pd and r["rho_case"] == rho_label(c))) for c in RHO_CASES] for pd in PD_GRID]))
    out.append("\n## Granularity (Basel rho): 99.9% quantile, ASRF vs ASRF+GA vs Monte Carlo [95% CI], 1,000,000 scenarios")
    out.append(md_table(["PD", "N", "ASRF", "ASRF+GA", "MC", "MC 95% CI", "MC sd", "exact sd"],
                        [[pct(r["annual_pd"], 0), f"{r['n_loans']:,}", pct(r["asrf_q0.999"]), pct(r["asrf_ga_q0.999"]), pct(r["mc_q0.999"]), f"[{pct(r['mc_q0.999_ci_lo'])}, {pct(r['mc_q0.999_ci_hi'])}]", pct(r["mc_sd"], 2), pct(r["sd_exact_finite_n"], 2)]
                         for r in gran if r["rho_case"] == "Basel"]))
    out.append("\n## Brute-force copula vs conditional-binomial sampler (PD 5%, Basel rho)")
    out.append(md_table(["method", "N", "scenarios", "mean", "sd", "q99", "q99 95% CI", "ASRF+GA q99"],
                        [[r["method"], f"{r['n_loans']:,}", f"{r['scenarios']:,}", pct(r["mean"], 2), pct(r["sd"], 2), pct(r["q0.99"], 2), f"[{pct(r['q0.99_ci_lo'], 2)}, {pct(r['q0.99_ci_hi'], 2)}]", pct(r["asrf_ga_q0.99"], 2)] for r in bf]))
    out.append(f"\n## Static vs replenished year (Basel rho, {REC_N} slots, 12 cycles, write-off lag one cycle)")
    out.append(md_table(["PD", "static MC mean", "static MC q99.9", "static ASRF+GA q99.9", "replenished MC mean", "replenished MC q99.9", "replenished ASRF EL", "replenished ASRF q99.9", "active share"],
                        [[pct(r["annual_pd"], 0), pct(r["static_mc_mean"], 2), pct(r["static_mc_q0.999"]), pct(r["static_asrf_ga_q0.999"]), pct(r["replenished_mc_mean"], 2), pct(r["replenished_mc_q0.999"]), pct(r["replenished_asrf_el"], 2), pct(r["replenished_asrf_q0.999"]), pct(r["replenished_mean_active_share"], 1)] for r in rev]))
    out.append("\n## Break-even premium s* = EL + h x UL99.9 (bps), h = 15%; * = deployed 500 bps adequate")
    out.append(md_table(hdr, [[pct(pd, 0)] + [(lambda r: f"{r['s_star_bps']:,.0f}{'*' if r['adequate_at_500bps'] else ''}")(next(r for r in prem if r["annual_pd"] == pd and r["rho_case"] == rho_label(c) and r["hurdle"] == BASE_HURDLE)) for c in RHO_CASES] for pd in PD_GRID]))
    out.append("\n## Break-even premium by hurdle at the Basel rho (bps): loan level / small-pool and pool-level variants")
    out.append(md_table(["PD", "h", "s* ASRF", "s* replenished", "s* N=500", "s* N=100", "pool u=85%", "pool u=90%", "pool u=85% fee 10%"],
                        [[pct(r["annual_pd"], 0), pct(r["hurdle"], 0), f"{r['s_star_bps']:,.0f}", f"{r['s_star_replenished_bps']:,.0f}", f"{r['s_star_ga_n500_bps']:,.0f}", f"{r['s_star_ga_n100_bps']:,.0f}", f"{r['s_pool_u85_bps']:,.0f}", f"{r['s_pool_u90_bps']:,.0f}", f"{r['s_pool_u85_fee10_bps']:,.0f}"]
                         for r in prem if r["rho_case"] == "Basel"]))
    out.append("\n## Largest annual PD (per-30-day-loan PD) for which 500 bps breaks even")
    out.append(md_table(["rho", "h", "loan level", "pool level u=85%"],
                        [[r["rho_case"], pct(r["hurdle"], 0), f"{pct(r['max_annual_pd_loan_level'], 2)} ({pct(r['max_loan_pd_30d_loan_level'], 3)})", f"{pct(r['max_annual_pd_pool_u85'], 2)} ({pct(r['max_loan_pd_30d_pool_u85'], 3)})"] for r in maxpd]))
    out.append(f"\n## Lender APY at the deployed APR 9.33%, u = {U_BASE:.0%}, fee 0")
    out.append(md_table(["PD", "rho", "reserve", "r", "E[APY]", "APY 1st pct", "P(APY<0)", "P(APY<EFFR)", "P(lender loss)", "foregone-interest bound"],
                        [[pct(r["annual_pd"], 0), r["rho_case"], r["reserve_policy"], pct(r["reserve_share"], 0), pct(r["expected_apy"], 2), pct(r["apy_p1"], 2), pct(r["p_apy_below_0"], 1), pct(r["p_apy_below_effr"], 1), pct(r["p_lender_loss"], 1), pct(r["foregone_interest_bound"], 2)] for r in apy]))
    out.append("\n## Secured share needed for 500 bps (h = 15%, Basel rho)")
    out.append(md_table(["PD", "s* unsecured (bps)", "min secured share"],
                        [[pct(r["annual_pd"], 0), f"{r['s_star_bps']:,.0f}", pct(r["min_secured_share_for_500bps"], 0)] for r in sec if r["secured_share"] == 0.0]))
    out.append("\n## Unsecured backing as a PD multiplier m, with secured share s (bps, h = 15%, Basel rho of m x PD)")
    out.append(md_table(["PD", "m", "s=0", "s=25%", "s=50%"],
                        [[pct(pd, 0), f"{m:g}"] + [f"{next(r['s_star_bps'] for r in back if r['annual_pd'] == pd and r['pd_multiplier'] == m and r['rho_case'] == 'Basel' and r['secured_share'] == s):,.0f}" for s in (0.0, 0.25, 0.5)]
                         for pd in PD_GRID for m in (1.0, 0.75, 0.5, 0.25)]))
    out.append("\n## reserveBps (share of interest) whose one-year inflow covers each target, at the deployed APR 9.33%; P(any lender loss in year 1 from a zero opening balance)")
    out.append(md_table(["PD", "rho", "EL", "L95-EL", "L99-EL", "L95", "L99", "P(loss) EL", "P(loss) L95-EL", "P(loss) L99-EL", "P(loss) L99"],
                        [[pct(r["annual_pd"], 0), r["rho_case"], pct(r["r_EL_deployed"], 0), pct(r["r_L95-EL_deployed"], 0), pct(r["r_L99-EL_deployed"], 0), pct(r["r_L95_deployed"], 0), pct(r["r_L99_deployed"], 0),
                          pct(r["p_lender_loss_EL"], 1), pct(r["p_lender_loss_L95-EL"], 1), pct(r["p_lender_loss_L99-EL"], 1), pct(r["p_lender_loss_L99"], 1)] for r in res if r["rho_case"] in ("Basel", "0.15")]))
    out.append("\n## Same targets at the break-even APR (EFFR + s*, h = 15%)")
    out.append(md_table(["PD", "rho", "APR", "EL", "L95-EL", "L99-EL", "L99"],
                        [[pct(r["annual_pd"], 0), r["rho_case"], pct(r["apr_breakeven_h15"], 2), pct(r["r_EL_breakeven"], 0), pct(r["r_L95-EL_breakeven"], 0), pct(r["r_L99-EL_breakeven"], 0), pct(r["r_L99_breakeven"], 0)] for r in res if r["rho_case"] in ("Basel", "0.15")]))
    out.append(f"\n## Multi-year reserve (independent years, u = {U_BASE:.0%}, cap = u (L99 - EL)); P(any lender loss) by year")
    yrs = [1, 2, 3, 5, 10]
    out.append(md_table(["PD", "policy", "r", "cap"] + [f"yr {y}" for y in yrs],
                        [[pct(rec["pd"], 0), pol, pct(next(r["reserve_share"] for r in paths if r["annual_pd"] == rec["pd"] and r["policy"] == pol), 0), pct(rec["cap"], 2)]
                         + [pct(next(r["p_lender_loss"] for r in paths if r["annual_pd"] == rec["pd"] and r["policy"] == pol and r["year"] == y), 1) for y in yrs]
                         for rec in recs if rec["rho_case"] == "Basel" for pol in ("covers_EL", "recommended")]))
    out.append("\n## Stale share price: transfer to an early exiter (A = 10,000 USDC, overdue X written off in full)")
    out.append(md_table(["X/A", "w", "transfer w X (USDC)", "stayers' loss rate", "pro-rata loss rate"],
                        [[pct(r["overdue_share"], 0), pct(r["exit_share"], 0), f"{r['transfer']:,.0f}", pct(r["stayer_loss_rate"], 2), pct(r["pro_rata_loss_rate"], 2)] for r in run_rows]))
    out.append("\n## Steady-state overdue-but-not-written-off stock (hazard x u x 30/365)")
    out.append(md_table(["PD", "share of pool assets"], [[pct(r["annual_pd"], 0), pct(r["overdue_stock_share_of_assets"], 2)] for r in overdue]))
    out.append(f"\n## Recommendation inputs (h = 15%, u = {U_BASE:.0%}, fee 0, N = {REC_N} granularity add-on, reserve built over {REC_BUILD_YEARS} years)")
    out.append(md_table(["PD", "per-loan PD", "rho", "s* loan ASRF", "s pool ASRF", "s pool replenished+GA", "recommended", "APR", "r covers EL", "recommended r", "cap (per deposit)", "P(loss) yr 1", "E[APY]", "APY 1st pct", "P(APY<EFFR)", "idle-reserve cost"],
                        [[pct(r["pd"], 0), pct(r["loan_pd_30d"], 2), f"{r['rho']:.4f}", f"{r['s_loan_asrf_bps']:,.0f}", f"{r['s_pool_asrf_bps']:,.0f}", f"{r['s_pool_rep_ga_bps']:,.0f}", f"{r['s_rec_bps']:,.0f}", pct(r["apr"], 2),
                          pct(r["r_el"], 0), pct(r["r_rec"], 0), pct(r["cap"], 2), pct(r["p_loss_year1_rec"], 1), pct(r["expected_apy_rec"], 2), pct(r["apy_p1_rec"], 2), pct(r["p_apy_below_effr_rec"], 1), pct(r["idle_reserve_cost"], 2)] for r in recs]))
    path = os.path.join(RESULTS, "summary.md")
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")
    return path


def main():
    os.makedirs(RESULTS, exist_ok=True)
    os.makedirs(FIGURES, exist_ok=True)
    _style()
    t0 = time.time()
    conv, conv2 = pd_conversion()
    vrows = vasicek_table()
    gran = mc_granularity()
    bf = mc_bruteforce_check()
    rev = revolving_vs_static()
    prem, maxpd = pricing()
    apy = lender_apy_table()
    sec, back = security_mix()
    res = reserve_sizing()
    recs = recommendation()
    recs_hi = recommendation(0.15)
    write_csv("recommendation.csv", recs + recs_hi)
    paths = reserve_paths(recs)
    run_rows, overdue = run_transfer()
    figs = [fig_loss_distribution(), fig_granularity(gran), fig_breakeven(), fig_lender_apy(), fig_security(), fig_reserve()]
    summary = summary_md(conv, conv2, vrows, gran, bf, rev, prem, maxpd, apy, sec, back, res, paths, run_rows, overdue, recs + recs_hi)
    print(f"wrote {len(os.listdir(RESULTS))} files to {RESULTS} and {len(figs)} figures to {FIGURES} in {time.time() - t0:.1f}s")
    print(f"summary: {summary}")
    for r in recs + recs_hi:
        print(f"PD {pct(r['pd'], 0)}, rho {r['rho_case']}: riskPremium {r['s_rec_bps']:.0f} bps (APR {pct(r['apr'], 2)}), reserveBps {1e4 * r['r_rec']:.0f}, cap {pct(r['cap'], 2)} of deposits")


if __name__ == "__main__":
    main()
