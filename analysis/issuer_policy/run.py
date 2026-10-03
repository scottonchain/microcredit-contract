"""Reproduce every table and figure of the issuer-policy analysis.

    cd analysis/issuer_policy && python3 run.py

Writes results/*.csv, results/summary.md, results/report_example.json and figures/*.png.
Deterministic: every draw is seeded from simulate.BASE_SEED and a run's seed.
"""

from __future__ import annotations

import csv
import json
import math
import os
import time
from dataclasses import replace

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
from scipy.stats import beta as beta_dist  # noqa: E402

import allocate as alloc  # noqa: E402
import policy as pol  # noqa: E402
import simulate as sim  # noqa: E402
from model import DAY, SCALE, USDC, Loan, LoanStatus, usdc  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "results")
FIGURES = os.path.join(HERE, "figures")

P = pol.PolicyParams()
TIERS = list(P.tiers)
BASE = dict(n_honest=1_000, budget_lines=250.0, increase_lines=60.0, n_farm=8)
CAL_SEEDS = (0, 1, 2)
SWEEP = dict(n_honest=600, budget_lines=150.0, increase_lines=40.0, n_farm=2)
N_ATTACK = (1, 2, 4, 8, 16, 32, 64)
BUDGETS = (25, 50, 100, 150, 200, 300, 400)
VIOLATION = 4.0  # the violating regime: identities really cost k_t / 4

# chart palette (dataviz reference instance, light mode; validated, as in analysis/credit_risk)
SURFACE, INK, INK2, MUTED, GRID, AXIS = "#fcfcfb", "#0b0b0b", "#52514e", "#898781", "#e1e0d9", "#c3c2b7"
CAT = ["#2a78d6", "#eb6834", "#1baf7a"]
ORD5 = ["#86b6ef", "#5598e7", "#2a78d6", "#1c5cab", "#0d366b"]


# ───────────────────────────── helpers ─────────────────────────────


def write_csv(name: str, rows: list[dict]) -> None:
    keys: list[str] = []
    for r in rows:
        keys += [k for k in r if k not in keys]
    with open(os.path.join(RESULTS, name), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys, restval="")
        w.writeheader()
        for r in rows:
            w.writerow({k: (f"{v:.6g}" if isinstance(v, float) else v) for k, v in r.items()})


def md_table(rows: list[dict], cols: list[tuple[str, str, str]]) -> str:
    """cols: (key, header, format)."""
    out = ["| " + " | ".join(h for _, h, _ in cols) + " |", "| " + " | ".join("---:" if f else "---" for _, _, f in cols) + " |"]
    for r in rows:
        cells = []
        for k, _, f in cols:
            v = r.get(k, "")
            cells.append(format(v, f) if f and isinstance(v, (int, float)) and not (isinstance(v, float) and math.isnan(v)) else str(v))
        out.append("| " + " | ".join(cells) + " |")
    return "\n".join(out)


def style(ax, title: str, xlabel: str, ylabel: str) -> None:
    ax.set_facecolor(SURFACE)
    ax.set_title(title, color=INK, fontsize=11, loc="left")
    ax.set_xlabel(xlabel, color=INK2, fontsize=9)
    ax.set_ylabel(ylabel, color=INK2, fontsize=9)
    ax.grid(True, color=GRID, linewidth=0.6)
    ax.set_axisbelow(True)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(AXIS)
    ax.tick_params(colors=INK2, labelsize=8)


def figure(ncols: int, width: float = 5.2, height: float = 3.8):
    fig, axes = plt.subplots(1, ncols, figsize=(width * ncols, height), facecolor=SURFACE)
    return fig, np.atleast_1d(axes)


def save(fig, name: str, rect=(0, 0, 1, 1)) -> None:
    fig.tight_layout(rect=rect)
    fig.savefig(os.path.join(FIGURES, name), dpi=150, facecolor=SURFACE)
    plt.close(fig)


def total(res: sim.SimResult, key: str) -> float:
    return float(sum(r.get(key, 0.0) for r in res.monthly))


# ───────────────────────────── experiments ─────────────────────────────


def tier_table() -> list[dict]:
    rows = []
    for name, t in P.tiers.items():
        m = t.prior_alpha / (t.prior_alpha + t.prior_beta)
        p = m / (1 + P.late_ratio)
        rows.append(
            {
                "tier": name,
                "identity_cost_usdc": t.identity_cost,
                "cap_usdc": P.cap_usdc(t),
                "incentive_compatible": pol.incentive_compatible(t, P),
                "prior_alpha": t.prior_alpha,
                "prior_beta": t.prior_beta,
                "prior_strength_trials": t.prior_alpha + t.prior_beta,
                "prior_annual_pd": pol.annual_pd(p),
                "start_line_usdc": min(pol.best_line_usdc(p, P), P.cap_usdc(t)),
                "line_after_24_trials_usdc": min(pol.best_line_usdc(t.prior_alpha / (t.prior_alpha + t.prior_beta + 24) / 3, P), P.cap_usdc(t)),
            }
        )
    return rows


def evidence_routes() -> list[dict]:
    """Each farming route, the weight the policy gives it, and the interest it costs per trial."""
    now = 1_800_000_000

    def loan(principal, held_days, secured=0.0, age_days=0.0, term_days=30.0):
        closed = now - int(age_days * DAY)
        disbursed = closed - int(held_days * DAY)
        p = usdc(principal)
        elapsed = int(held_days * DAY)
        interest = 0 if elapsed < DAY else p * 1233 // 10_000 * elapsed // (365 * DAY)
        return Loan(0, "0x", p, int(term_days * DAY), disbursed, 1233, LoanStatus.REPAID, p + interest, p, closed, usdc(secured))

    routes = [
        ("reference: 100 unsecured, 30 days", loan(100, 30), "a full trial"),
        ("100 repaid inside the 24-hour window", loan(100, 23 / 24), "free and recyclable (Theorem 3)"),
        ("100 fully stake-secured, 30 days", loan(100, 30, secured=100), "lenders bore no risk; stake is recyclable"),
        ("100 with 95 stake-secured, 30 days", loan(100, 30, secured=95), "only 5 at risk"),
        ("1 unsecured, 30 days", loan(1, 30), "dust loans"),
        ("100 unsecured, 3 days", loan(100, 3), "short loans"),
        ("100 unsecured, 30 days, two years ago", loan(100, 30, age_days=730), "aged or bought history"),
        ("100 late (repaid at day 45), stake-secured", loan(100, 45, secured=100), "bad evidence: never discounted for stake"),
    ]
    rows = []
    for name, ln, why in routes:
        g, b = pol.loan_evidence(ln, now, P)
        rows.append(
            {
                "route": name,
                "why": why,
                "good_weight": g,
                "bad_weight": b,
                "interest_paid_usdc": ln.interest_paid / USDC,
                "interest_per_trial_usdc": (ln.interest_paid / USDC / g) if g > 0 else math.inf,
            }
        )
    rows.append(
        {
            "route": "loans of an account it backed",
            "why": "guarantor records: back your own fresh account",
            "good_weight": 0.0,
            "bad_weight": 0.0,
            "interest_paid_usdc": math.nan,
            "interest_per_trial_usdc": math.inf,
        }
    )
    return rows


def base_runs():
    best = {t: sim.best_bust_month(t, P) for t in TIERS}
    attacks = tuple(sim.AttackSpec(t, 8, best[t][0]) for t in TIERS)
    runs = [sim.simulate(sim.SimConfig(seed=s, attacks=attacks, **BASE)) for s in CAL_SEEDS]
    return best, runs


def honest_lines(res: sim.SimResult) -> list[dict]:
    rows = []
    pds = np.array([h.pd_annual for h in res.honest])
    for m in range(res.config.months):
        for pd in pol.PD_GRID:
            idx = pds == pd
            alive = res.alive[m, idx]
            rows.append(
                {
                    "month": m,
                    "true_annual_pd": pd,
                    "n": int(idx.sum()),
                    "alive_share": float(alive.mean()),
                    "mean_line_alive_usdc": float(res.lines[m, idx][alive].mean()),
                    "mean_line_all_usdc": float(res.lines[m, idx].mean()),
                    "share_with_line": float((res.lines[m, idx] > 0).mean()),
                    "mean_posterior_annual_pd_alive": float(np.nanmean(res.post_pd[m, idx][alive])),
                }
            )
    return rows


def lines_by_tier(res: sim.SimResult) -> list[dict]:
    rows = []
    pds = np.array([h.pd_annual for h in res.honest])
    tiers = np.array([h.tier for h in res.honest])
    for t in TIERS:
        for pd in pol.PD_GRID:
            idx = (tiers == t) & (pds == pd)
            if not idx.any():
                continue
            row = {"tier": t, "true_annual_pd": pd, "n": int(idx.sum())}
            for m in (0, 6, 12, res.config.months - 1):
                alive = res.alive[m, idx]
                row[f"line_m{m}"] = float(res.lines[m, idx][alive].mean()) if alive.any() else math.nan
            row["alive_end"] = float(res.alive[-1, idx].mean())
            rows.append(row)
    return rows


def calibration(runs: list[sim.SimResult], bins: int = 10) -> list[dict]:
    c = np.array([(x[2], x[3], x[4]) for r in runs for x in r.cycles], dtype=float)
    edges = np.quantile(c[:, 0], np.linspace(0, 1, bins + 1))
    which = np.clip(np.searchsorted(edges, c[:, 0], side="right") - 1, 0, bins - 1)
    rows = []
    for b in range(bins):
        sel = which == b
        n, k = int(sel.sum()), int(c[sel, 2].sum())
        lo = beta_dist.ppf(0.025, k, n - k + 1) if k > 0 else 0.0  # Clopper-Pearson
        hi = beta_dist.ppf(0.975, k + 1, n - k)
        rows.append(
            {
                "bin": b,
                "cycles": n,
                "defaults": k,
                "mean_predicted_cycle_pd": float(c[sel, 0].mean()),
                "mean_true_cycle_pd": float(c[sel, 1].mean()),
                "realised_default_rate": k / n,
                "ci95_low": float(lo),
                "ci95_high": float(hi),
            }
        )
    rows.append(
        {
            "bin": "all",
            "cycles": len(c),
            "defaults": int(c[:, 2].sum()),
            "mean_predicted_cycle_pd": float(c[:, 0].mean()),
            "mean_true_cycle_pd": float(c[:, 1].mean()),
            "realised_default_rate": float(c[:, 2].mean()),
            "ci95_low": float(beta_dist.ppf(0.025, c[:, 2].sum(), len(c) - c[:, 2].sum() + 1)),
            "ci95_high": float(beta_dist.ppf(0.975, c[:, 2].sum() + 1, len(c) - c[:, 2].sum())),
        }
    )
    return rows


def attack_sweep(best: dict) -> list[dict]:
    rows = []
    for t in TIERS:
        bust = best[t][0]
        for n in N_ATTACK:
            res = sim.simulate(sim.SimConfig(attacks=(sim.AttackSpec(t, n, bust),), **SWEEP))
            assert res.rejections == 0
            k = P.tiers[t].identity_cost
            extracted = sum(a.extracted for a in res.attackers) / USDC
            interest = sum(a.interest_paid for a in res.attackers) / USDC
            dues = sum(a.dues_at_bust for a in res.attackers) / USDC
            rows.append(
                {
                    "tier": t,
                    "identities": n,
                    "bust_month": bust,
                    "identity_cost_usdc": k,
                    "mean_line_at_bust_usdc": float(np.mean([a.line_at_bust for a in res.attackers])),
                    "extracted_usdc": extracted,
                    "interest_paid_usdc": interest,
                    "profit_ic_usdc": sim.attacker_profit(res, 1.0),
                    "profit_violated_usdc": sim.attacker_profit(res, 1.0 / VIOLATION),
                    "lender_loss_on_attackers_usdc": total(res, "loss_attacker_usdc"),
                    "attacker_dues_usdc": dues,
                    "loss_on_issued_lines_usdc": total(res, "loss_attacker_usdc") - dues,
                    "byzantine_bound_usdc": pol.byzantine_loss_bound({t: n}, P),
                }
            )
    return rows


def run_economics(res: sim.SimResult) -> dict:
    """Exposure, losses and income of the honest book over one run (settlement included)."""
    cfg = res.config
    months = [r for r in res.monthly if "total_held" in r]
    pds = np.array([h.pd_annual for h in res.honest])
    lines = res.lines
    return {
        "mean_total_held_usdc": float(np.mean([r["total_held"] for r in months])) * P.max_loan_usdc,
        "mean_exposure_usdc": float(np.mean([r["exposure_usdc"] for r in months])),
        "honest_loss_usdc": total(res, "loss_honest_usdc"),
        "premium_income_usdc": total(res, "premium_income_usdc"),
        # the model's expected profit of the lines it published, for borrowers active `activity` of cycles
        "model_expected_profit_usdc": cfg.activity * sum(r["expected_profit_usdc"] for r in months),
        "share_with_line_end": float((lines[-1] > 0).mean()),
        "line_weighted_true_pd": float((lines * pds).sum() / lines.sum()) if lines.sum() else math.nan,
        "years": cfg.months / 12,
    }


def budget_sweep(seeds=CAL_SEEDS) -> tuple[list[dict], list[sim.SimResult]]:
    rows, runs = [], []
    for b in BUDGETS:
        per_seed = []
        for s in seeds:
            cfg = sim.SimConfig(**{**SWEEP, "budget_lines": float(b), "increase_lines": max(10.0, b / 4), "seed": s})
            res = sim.simulate(cfg)
            assert res.rejections == 0
            per_seed.append(run_economics(res))
            runs.append(res)
        e = {k: float(np.mean([x[k] for x in per_seed])) for k in per_seed[0]}
        budget_usdc = b * P.max_loan_usdc
        rows.append(
            {
                "budget_lines": b,
                "budget_usdc": budget_usdc,
                "max_increase_lines": max(10.0, b / 4),
                "seeds": len(seeds),
                **{k: v for k, v in e.items() if k != "years"},
                "issuer_profit_usdc": e["premium_income_usdc"] - e["honest_loss_usdc"],
                "loss_rate_per_exposure_year": e["honest_loss_usdc"] / (e["mean_exposure_usdc"] * e["years"]),
                "loss_per_budget_year": e["honest_loss_usdc"] / (budget_usdc * e["years"]),
            }
        )
    return rows, runs


def greedy_vs_lp(trials: int = 200) -> dict:
    rng = np.random.default_rng((sim.BASE_SEED, 9))
    gaps = []
    for _ in range(trials):
        n = 30
        cur = rng.integers(0, SCALE // 2, n) * (rng.random(n) < 0.6)
        held = cur + rng.integers(0, SCALE // 4, n) * (rng.random(n) < 0.4)
        pds = rng.uniform(0.0005, 0.006, n)
        tgt = np.array([min(SCALE, int(pol.best_line_usdc(p, P) * USDC * SCALE // P.max_loan)) for p in pds])
        want = int(np.maximum(tgt - cur, 0).sum())
        cap_inc, cap_bud = int(rng.uniform(0.2, 0.9) * want), int(rng.uniform(0.1, 0.8) * want)
        new = alloc.allocate(cur, held, tgt, pds, cap_inc, cap_bud, P)
        _, lp = alloc.allocate_lp(cur, held, tgt, pds, cap_inc, cap_bud, P)
        g = alloc.raise_profit(cur, held, new, tgt, pds, P)
        gaps.append(max(0.0, (lp - g) / lp) if lp > 0 else 0.0)
    return {"trials": trials, "max_gap": float(max(gaps)), "mean_gap": float(np.mean(gaps))}


# ───────────────────────────── figures ─────────────────────────────


def fig_honest(rows: list[dict]) -> None:
    fig, (a1, a2) = figure(2)
    months = sorted({r["month"] for r in rows})
    for i, pd in enumerate(pol.PD_GRID):
        sel = [r for r in rows if r["true_annual_pd"] == pd]
        y1 = [r["mean_line_alive_usdc"] for r in sel]
        y2 = [100 * r["mean_posterior_annual_pd_alive"] for r in sel]
        label = f"{pd:.0%}"
        a1.plot(months, y1, color=ORD5[i], linewidth=2, label=label)
        a1.annotate(label, (months[-1], y1[-1]), xytext=(4, 0), textcoords="offset points", va="center", fontsize=8, color=INK2)
        a2.plot(months, y2, color=ORD5[i], linewidth=2, label=label)
        a2.annotate(label, (months[-1], y2[-1]), xytext=(4, 0), textcoords="offset points", va="center", fontsize=8, color=INK2)
    style(a1, "Line of surviving honest borrowers", "month (report)", "mean line, USDC")
    style(a2, "Posterior annual PD of survivors", "month (report)", "mean posterior annual PD, %")
    a1.set_xlim(0, months[-1] + 2.5)
    a2.set_xlim(0, months[-1] + 2.5)
    handles, labels = a1.get_legend_handles_labels()
    fig.legend(handles, labels, title="true annual PD", fontsize=8, title_fontsize=8, frameon=False, loc="lower center", ncol=5)
    save(fig, "honest_lines.png", rect=(0, 0.12, 1, 1))


def fig_calibration(rows: list[dict]) -> None:
    fig, (ax,) = figure(1, 5.6, 4.4)
    bins = [r for r in rows if r["bin"] != "all"]
    x = np.array([100 * r["mean_predicted_cycle_pd"] for r in bins])
    real = np.array([100 * r["realised_default_rate"] for r in bins])
    lo = np.array([100 * r["ci95_low"] for r in bins])
    hi = np.array([100 * r["ci95_high"] for r in bins])
    true = np.array([100 * r["mean_true_cycle_pd"] for r in bins])
    top = max(hi.max(), x.max()) * 1.05
    ax.plot([0, top], [0, top], color=MUTED, linewidth=1, linestyle="--", label="perfect calibration")
    ax.errorbar(x, real, yerr=[real - lo, hi - real], fmt="o", color=CAT[0], ecolor=CAT[0], elinewidth=1, capsize=3, markersize=6, label="realised default rate (95% CI)")
    ax.plot(x, true, "s", color=CAT[1], markersize=6, label="mean true PD of the bin")
    style(ax, "Posterior calibration (honest borrower-cycles)", "predicted default probability per 30-day cycle, %", "per cycle, %")
    ax.set_xlim(0, top)
    ax.set_ylim(0, top)
    ax.legend(fontsize=8, frameon=False, loc="upper left")
    save(fig, "calibration.png")


def fig_attack(rows: list[dict]) -> None:
    fig, axes = figure(2)
    for ax, key, title in (
        (axes[0], "profit_ic_usdc", "Caps respect k_t (cap_t <= k_t)"),
        (axes[1], "profit_violated_usdc", f"k_t overestimated {VIOLATION:.0f}x (cap_t = {VIOLATION:.0f} x true cost)"),
    ):
        for i, t in enumerate(TIERS):
            sel = [r for r in rows if r["tier"] == t]
            xs = [r["identities"] for r in sel]
            ys = [r[key] for r in sel]
            ax.plot(xs, ys, marker="o", markersize=5, color=CAT[i], linewidth=2, label=t)
            ax.annotate(t, (xs[-1], ys[-1]), xytext=(4, 0), textcoords="offset points", va="center", fontsize=8, color=INK2)
        ax.axhline(0, color=INK2, linewidth=0.8)
        ax.set_xticks([0, 8, 16, 32, 48, 64])
        style(ax, title, "identities bought", "attacker net profit, USDC")
        ax.legend(title="tier", fontsize=8, title_fontsize=8, frameon=False, loc="lower left" if key == "profit_ic_usdc" else "upper left")
        ax.set_xlim(0, 76)
    save(fig, "attacker_profit.png")


def fig_budget(base: sim.SimResult, rows: list[dict]) -> None:
    fig, (a1, a2) = figure(2)
    months = [r for r in base.monthly if "total_held" in r]
    m = [r["month"] for r in months]
    scale = P.max_loan_usdc
    a1.plot(m, [r["max_total"] * scale for r in months], color=INK2, linestyle="--", linewidth=1.2, label="budget (maxTotalScore)")
    a1.plot(m, [r["total_held"] * scale for r in months], color=CAT[0], linewidth=2, label="budget held (totalHeld)")
    a1.plot(m, [r["total_score"] * scale for r in months], color=CAT[1], linewidth=2, label="current lines (totalScore)")
    a1.plot(m, [r["exposure_usdc"] for r in months], color=CAT[2], linewidth=2, label="unsecured exposure")
    style(a1, "Budget, held budget and exposure (base run)", "month (report)", "USDC")
    a1.set_ylim(0, None)
    a1.legend(fontsize=8, frameon=False, loc="lower right")
    b = [r["budget_lines"] * scale for r in rows]
    a2.plot(b, [100 * r["loss_rate_per_exposure_year"] for r in rows], marker="o", markersize=5, color=CAT[0], linewidth=2, label="loss per exposure-year")
    a2.plot(b, [100 * r["loss_per_budget_year"] for r in rows], marker="o", markersize=5, color=CAT[1], linewidth=2, label="loss per budget-year")
    a2.plot(b, [100 * r["line_weighted_true_pd"] for r in rows], marker="o", markersize=5, color=CAT[2], linewidth=2, label="line-weighted true annual PD")
    style(a2, "Issuer loss rate against budget (600 honest, 3 seeds)", "budget, USDC (log scale)", "% per year")
    a2.set_xscale("log")
    a2.xaxis.set_minor_locator(matplotlib.ticker.NullLocator())
    a2.set_xticks(b, [f"{x / 1000:g}k" for x in b])
    a2.set_ylim(0, None)
    a2.legend(fontsize=8, frameon=False, loc="lower left")
    save(fig, "budget.png")


# ───────────────────────────── summary ─────────────────────────────


def main() -> None:
    os.makedirs(RESULTS, exist_ok=True)
    os.makedirs(FIGURES, exist_ok=True)
    started = time.time()

    tiers = tier_table()
    write_csv("tiers.csv", tiers)
    routes = evidence_routes()
    write_csv("evidence_routes.csv", routes)

    best, runs = base_runs()
    base = runs[0]
    bust_rows = [r for t in TIERS for r in best[t][1]]
    write_csv("attacker_bust_month.csv", bust_rows)
    hl = honest_lines(base)
    write_csv("honest_lines.csv", hl)
    bt = lines_by_tier(base)
    write_csv("honest_lines_by_tier.csv", bt)
    cal = calibration(runs)
    write_csv("calibration.csv", cal)
    write_csv("monthly_base.csv", base.monthly)
    write_csv("farm.csv", base.farm)
    base_attackers = [
        {
            "tier": a.tier,
            "bust_month": a.bust_month,
            "line_at_bust_usdc": a.line_at_bust,
            "extracted_usdc": a.extracted / USDC,
            "interest_paid_usdc": a.interest_paid / USDC,
            "profit_ic_usdc": (a.extracted - a.interest_paid) / USDC - P.tiers[a.tier].identity_cost,
        }
        for a in base.attackers
    ]
    write_csv("base_attackers.csv", base_attackers)

    attack = attack_sweep(best)
    write_csv("attacker_profit.csv", attack)
    budget, budget_runs = budget_sweep()
    write_csv("budget_sweep.csv", budget)
    lp = greedy_vs_lp()

    all_runs = runs + budget_runs
    reports = sum(r["reports"] for res in all_runs for r in res.monthly if "reports" in r)
    rejections = sum(res.rejections for res in all_runs)
    front = sum(res.front_run_released for res in all_runs) / SCALE
    max_inc_use = max(r["increase"] / r["max_increase"] for res in all_runs for r in res.monthly if "increase" in r)
    max_held_use = max(r["total_held"] / r["max_total"] for res in all_runs for r in res.monthly if "total_held" in r)
    max_exp_use = max(r["exposure_usdc"] / r["exposure_bound_usdc"] for res in all_runs for r in res.monthly if r.get("exposure_bound_usdc"))
    assert rejections == 0

    # an example report: the first one of the base run, as the provider decodes it
    s0 = sim.Simulation(sim.SimConfig(seed=0, **BASE))
    views = [pol.read_account(s0.pool, s0.registry, a) for a in s0.all_addrs]
    plan0 = pol.plan_report(views, s0.provider.copy(), P, sim.T0)
    example = pol.report_json(plan0.reports[0])
    example_out = {
        "format": "abi.encode(uint64 epoch, address[] users, uint256[] scores)",
        "epoch": example["epoch"],
        "count": len(example["users"]),
        "users_first_5": example["users"][:5],
        "scores_first_5": example["scores"][:5],
        "abi_hex": pol.encode_report(plan0.reports[0]),
        "note": "abi_hex is null when eth_abi is not installed",
    }
    with open(os.path.join(RESULTS, "report_example.json"), "w") as f:
        json.dump(example_out, f, indent=2)

    fig_honest(hl)
    fig_calibration(cal)
    fig_attack(attack)
    fig_budget(base, budget)

    # ── summary.md ──
    def pct(x):
        return f"{100 * x:.2f}%"

    end = base.config.months - 1
    hl_end = [r for r in hl if r["month"] in (0, 6, 12, end)]
    pivot = []
    for pd in pol.PD_GRID:
        row = {"pd": f"{pd:.0%}"}
        for r in hl_end:
            if r["true_annual_pd"] == pd:
                row[f"m{r['month']}"] = r["mean_line_alive_usdc"]
                row[f"pd{r['month']}"] = 100 * r["mean_posterior_annual_pd_alive"]
                if r["month"] == end:
                    row["alive"] = r["alive_share"]
                    row["n"] = r["n"]
        pivot.append(row)
    cal_all = cal[-1]
    base_loss_h = sum(total(r, "loss_honest_usdc") for r in runs) / len(runs)
    base_loss_a = sum(total(r, "loss_attacker_usdc") for r in runs) / len(runs)
    base_inc = sum(total(r, "premium_income_usdc") for r in runs) / len(runs)
    base_model = sum(run_economics(r)["model_expected_profit_usdc"] for r in runs) / len(runs)
    bust_best = [max(best[t][1], key=lambda r: r["gross_usdc"]) for t in TIERS]
    for r in bust_best:
        r["profit_ic"] = r["gross_usdc"] - r["identity_cost_usdc"]
        r["profit_violated"] = r["gross_usdc"] - r["identity_cost_usdc"] / VIOLATION
    farm_rows = base.farm
    farm_show = [farm_rows[0], farm_rows[1], [r for r in farm_rows if r["account"] == "verified farm"][0], [r for r in farm_rows if r["account"] == "control"][0]]
    farm_show[0] = {**farm_show[0], "account": "unverified farm, grace window"}
    farm_show[1] = {**farm_show[1], "account": "unverified farm, 30-day"}
    attack_show = [r for r in attack if r["identities"] in (1, 8, 64)]

    lines = [
        "# Issuer policy: results",
        "",
        f"Generated by `run.py` in {time.time() - started:.0f} s. Parameters: maxLoanAmount {P.max_loan_usdc:.0f} USDC, "
        f"APR {(P.effr_bps + P.premium_bps) / 100:.2f}% (risk premium {P.premium_bps} bps), reserve share 65%, "
        f"late ratio {P.late_ratio:g}, reference principal {P.ref_principal / USDC:g} USDC, trial {P.trial_days:g} days, "
        f"half-life {P.half_life_days:g} days, demand mean {P.demand_mean:g} USDC.",
        "",
        "## Contract rules over every simulated report",
        "",
        f"- Reports planned and published: {reports} across {len(all_runs)} runs (base and budget sweep); the attack sweep asserts the same. "
        f"Rejected by the contract port: **{rejections}**.",
        f"- Every report was published after a griefer's `releaseBudget` front-run; the front-runs released {front:.2f} lines in total.",
        f"- Highest raise used per report: {max_inc_use:.0%} of `maxIncreasePerReport`. Highest held budget: {max_held_use:.0%} of `maxTotalScore`.",
        f"- Highest unsecured exposure relative to held budget plus dues (Theorem 2'): {max_exp_use:.0%}.",
        f"- Greedy allocation against the linear programme on {lp['trials']} random instances with both caps binding: "
        f"mean gap {100 * lp['mean_gap']:.4f}%, worst {100 * lp['max_gap']:.4f}% (integer rounding).",
        "",
        "## Tiers",
        "",
        md_table(
            tiers,
            [
                ("tier", "Tier", ""),
                ("identity_cost_usdc", "k_t (USDC)", ".0f"),
                ("cap_usdc", "cap_t (USDC)", ".0f"),
                ("incentive_compatible", "IC", ""),
                ("prior_alpha", "prior α", ".3f"),
                ("prior_beta", "prior β", ".1f"),
                ("prior_annual_pd", "prior annual PD", ".2%"),
                ("start_line_usdc", "start line", ".1f"),
                ("line_after_24_trials_usdc", "line after 24 clean trials", ".1f"),
            ],
        ),
        "",
        "## Theorem 3: farms earn nothing",
        "",
        md_table(
            farm_show,
            [
                ("account", "Account", ""),
                ("completed_loans", "completedLoans", "d"),
                ("grace_closes", "closed in 24 h", "d"),
                ("repaid_principal_usdc", "principal repaid", ".0f"),
                ("dues_usdc", "dues (contract)", ".2f"),
                ("evidence_good", "evidence", ".2f"),
                ("naive_25pct_line_usdc", "'25% of principal' line", ".0f"),
                ("published_line_usdc", "policy line", ".2f"),
                ("reason", "reason", ""),
            ],
        ),
        "",
        "## Evidence weights by route",
        "",
        md_table(
            routes,
            [
                ("route", "Loan", ""),
                ("good_weight", "good", ".3f"),
                ("bad_weight", "bad", ".3f"),
                ("interest_paid_usdc", "interest paid", ".3f"),
                ("interest_per_trial_usdc", "interest per trial", ".3f"),
                ("why", "route it closes", ""),
            ],
        ),
        "",
        "## Honest borrowers (base run, seed 0, 1,000 honest)",
        "",
        "Mean line of surviving borrowers (USDC) and mean posterior annual PD (%), by true annual PD:",
        "",
        md_table(
            pivot,
            [
                ("pd", "true PD", ""),
                ("n", "n", "d"),
                ("m0", "line m0", ".1f"),
                ("m6", "line m6", ".1f"),
                ("m12", "line m12", ".1f"),
                (f"m{end}", f"line m{end}", ".1f"),
                ("pd0", "post. PD m0", ".2f"),
                (f"pd{end}", f"post. PD m{end}", ".2f"),
                ("alive", f"alive m{end}", ".1%"),
            ],
        ),
        "",
        "By tier (line of survivors, USDC):",
        "",
        md_table(
            bt,
            [("tier", "tier", ""), ("true_annual_pd", "true PD", ".0%"), ("n", "n", "d"), ("line_m0", "m0", ".1f"), ("line_m12", "m12", ".1f"), (f"line_m{end}", f"m{end}", ".1f"), ("alive_end", "alive", ".1%")],
        ),
        "",
        f"Calibration over {cal_all['cycles']:,} honest borrower-cycles in {len(CAL_SEEDS)} seeds: mean predicted default probability "
        f"{pct(cal_all['mean_predicted_cycle_pd'])} per cycle, mean true {pct(cal_all['mean_true_cycle_pd'])}, realised "
        f"{pct(cal_all['realised_default_rate'])} ({cal_all['defaults']} defaults, 95% CI {pct(cal_all['ci95_low'])} to {pct(cal_all['ci95_high'])}).",
        "",
        md_table(
            cal[:-1],
            [
                ("bin", "decile", "d"),
                ("cycles", "cycles", "d"),
                ("defaults", "defaults", "d"),
                ("mean_predicted_cycle_pd", "predicted", ".3%"),
                ("mean_true_cycle_pd", "true", ".3%"),
                ("realised_default_rate", "realised", ".3%"),
                ("ci95_low", "CI low", ".3%"),
                ("ci95_high", "CI high", ".3%"),
            ],
        ),
        "",
        f"Base runs (mean of {len(runs)} seeds, 24 reports plus settlement): honest losses {base_loss_h:,.0f} USDC, losses on the 24 "
        f"bought identities {base_loss_a:,.0f} USDC, premium income {base_inc:,.0f} USDC. Realised profit on the honest book "
        f"{base_inc - base_loss_h:,.0f} USDC against the model's expected {base_model:,.0f} USDC.",
        "",
        "## Attackers who buy identities",
        "",
        "Best bust-out month for one identity with no competition for budget (the identity cost is sunk, so it is the same month in both regimes):",
        "",
        md_table(
            bust_best,
            [
                ("tier", "tier", ""),
                ("bust_month", "bust month", "d"),
                ("line_at_bust_usdc", "line at bust", ".2f"),
                ("extracted_usdc", "extracted", ".2f"),
                ("interest_paid_usdc", "interest paid", ".2f"),
                ("identity_cost_usdc", "k_t", ".0f"),
                ("profit_ic", "profit at k_t", ".2f"),
                ("profit_violated", f"profit at k_t/{VIOLATION:.0f}", ".2f"),
            ],
        ),
        "",
        "Identities bought, in a world of 600 honest borrowers (budget 150 lines, 40 per report):",
        "",
        md_table(
            attack_show,
            [
                ("tier", "tier", ""),
                ("identities", "identities", "d"),
                ("mean_line_at_bust_usdc", "line at bust", ".2f"),
                ("extracted_usdc", "extracted", ".1f"),
                ("interest_paid_usdc", "interest", ".1f"),
                ("profit_ic_usdc", "profit at k_t", ".1f"),
                ("profit_violated_usdc", f"profit at k_t/{VIOLATION:.0f}", ".1f"),
                ("lender_loss_on_attackers_usdc", "lenders' loss", ".1f"),
                ("attacker_dues_usdc", "their dues", ".1f"),
                ("loss_on_issued_lines_usdc", "loss on issued lines", ".1f"),
                ("byzantine_bound_usdc", "bound n·cap_t", ".0f"),
            ],
        ),
        "",
        "## Budget",
        "",
        md_table(
            budget,
            [
                ("budget_usdc", "budget (USDC)", ",.0f"),
                ("max_increase_lines", "raise cap (lines)", ".0f"),
                ("mean_total_held_usdc", "mean held", ",.0f"),
                ("mean_exposure_usdc", "mean exposure", ",.0f"),
                ("honest_loss_usdc", "loss", ",.0f"),
                ("premium_income_usdc", "premium", ",.0f"),
                ("issuer_profit_usdc", "profit", ",.0f"),
                ("model_expected_profit_usdc", "model profit", ",.0f"),
                ("loss_rate_per_exposure_year", "loss / exposure-yr", ".2%"),
                ("loss_per_budget_year", "loss / budget-yr", ".2%"),
                ("line_weighted_true_pd", "line-weighted true PD", ".2%"),
                ("share_with_line_end", "with a line (end)", ".0%"),
            ],
        ),
        "",
        "Mean of 3 seeds per budget, 600 honest borrowers, 24 reports plus settlement. Every seed faces the same "
        "borrowers and the same monthly draws at every budget (common random numbers). \"model profit\" is the "
        "plan's expected profit, i * E[min(line, D)] - p * line summed over published lines, times the activity rate.",
        "",
        f"Example report (`results/report_example.json`): epoch {example_out['epoch']}, {example_out['count']} users; "
        f"first users {example_out['users_first_5'][:2]} with scores {example_out['scores_first_5'][:2]}.",
        "",
    ]
    with open(os.path.join(RESULTS, "summary.md"), "w") as f:
        f.write("\n".join(lines))
    print("\n".join(lines))
    print(f"\ndone in {time.time() - started:.1f} s")


if __name__ == "__main__":
    main()
