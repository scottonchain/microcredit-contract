#!/usr/bin/env python3
"""Run every attack and honest scenario; write results/*.csv, results/summary.md, figures/*.png.

    python3 analysis/sybil_sim/run.py

Deterministic: the only randomness is the M0 community world, which uses a fixed seed.
"""

from __future__ import annotations

import csv
import itertools
from collections import defaultdict
from collections.abc import Callable
from dataclasses import dataclass
from functools import partial
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.ticker import FixedLocator, FuncFormatter, NullLocator  # noqa: E402

import attacks as atk  # noqa: E402
from mechanisms import (  # noqa: E402
    MECHANISMS,
    Conservation,
    ConservationDues,
    ConservationReserveDues,
    EarmarkedReserveDues,
    HermesHistory,
    PageRankVouch,
    Params,
    label,
)

HERE = Path(__file__).resolve().parent
RESULTS = HERE / "results"
FIGURES = HERE / "figures"


@dataclass(frozen=True)
class Scenario:
    attack: str  # "A1 ring", as in Outcome.attack
    variant: str
    run: Callable  # (mechanism, n) -> Outcome | None
    main: bool = False  # shown in the overview figure and the headline table


SCENARIOS = [
    Scenario("A1 ring", "ring + beneficiary", atk.ring, main=True),
    Scenario("A1 ring", "pure ring", partial(atk.ring, beneficiary=False)),
    Scenario("A2 stranger lift", "", atk.stranger_lift, main=True),
    Scenario("A3 deposit roots", "ring + beneficiary", atk.deposit_roots, main=True),
    Scenario("A3 deposit roots", "pure ring", partial(atk.deposit_roots, beneficiary=False)),
    Scenario("A4 wash farm", "stake seed, grace repayment", partial(atk.wash_farm, seed="stake"), main=True),
    Scenario("A4 wash farm", "stake seed, 30-day repayment", partial(atk.wash_farm, seed="stake", timing="30d")),
    Scenario("A4 wash farm", "line seed, grace repayment", partial(atk.wash_farm, seed="line"), main=True),
    Scenario("A4 wash farm", "line seed, 30-day repayment", partial(atk.wash_farm, seed="line", timing="30d")),
    Scenario("A4 wash farm", "stake seed, grace repayment, 4 cycles", partial(atk.wash_farm, cycles=4)),
    Scenario("A4 wash farm", "stake seed, 30-day repayment, 4 cycles", partial(atk.wash_farm, timing="30d", cycles=4)),
    Scenario("A5 collusive backer", "", atk.collusive_backer, main=True),
    Scenario("A6 exit scam", "30-day repayments", atk.exit_scam, main=True),
    Scenario("A6 exit scam", "grace repayments", partial(atk.exit_scam, timing="grace")),
    Scenario("A7 self-lending dues", "lender share 50%", atk.self_lending, main=True),
]

M0_WORLDS = ("demo", "unrooted", "community")
M0_SCENARIOS = [s for s in SCENARIOS if s.attack[:2] in ("A1", "A2", "A3", "A5")]

# A7 sensitivity: who earns the interest back, and where the rest of it goes
LENDER_SHARES_BPS = (0, 1_000, 2_500, 5_000, 7_500, 9_000)
FEE_RESERVE_CASES = (  # (protocol_fee_bps, reserve_bps)
    (1_000, 3_000),  # this study's default
    (0, 3_000),  # the deploy script
    (1_000, 0),
    (0, 0),
    (0, 8_000),  # MAX_RESERVE_BPS
)
A7_ACCOUNTS = 8

# Residual case for M3r: the reserve the farm paid into reaches lenders before the farm defaults
DRAIN_CASES = (  # (protocol_fee_bps, reserve_bps, description)
    (0, 3_000, "deployed"),
    (1_000, 3_000, "study default"),
    (0, 5_500, "calibration's full recommendation"),
    (0, 8_000, "maximum reserve"),
)
DRAIN_SHARES_BPS = (0, 2_500, 5_000, 7_000, 7_500, 8_000, 9_000, 9_500)
DRAINS = (0.0, 0.5, 1.0, 2.0)
DRAIN_ROUTES = ("defaults", "release")
DRAIN_ACCOUNTS = 8


# ───────────────────────────── experiments ─────────────────────────────


def run_attacks() -> list[atk.Outcome]:
    rows = []
    for scenario in SCENARIOS:
        for mechanism in MECHANISMS:
            for n in atk.ATTACK_SIZES:
                outcome = scenario.run(mechanism, n)
                if outcome is not None:
                    assert outcome.variant == scenario.variant, (outcome.variant, scenario.variant)
                    rows.append(outcome)
    return rows


def run_m0_worlds() -> list[atk.Outcome]:
    return [
        scenario.run(PageRankVouch, n, world=world)
        for scenario in M0_SCENARIOS
        for world in M0_WORLDS
        for n in atk.ATTACK_SIZES
    ]


def run_a7_sensitivity() -> list[dict]:
    """A7 profit per farmed account over lender share, fee and reserve, simulated and closed form."""
    rows = []
    for mechanism in (HermesHistory, Conservation, ConservationDues, ConservationReserveDues):
        for fee_bps, reserve_bps in FEE_RESERVE_CASES:
            params = Params(protocol_fee_bps=fee_bps, reserve_bps=reserve_bps)
            for share_bps in LENDER_SHARES_BPS:
                outcome = atk.self_lending(mechanism, A7_ACCOUNTS, lender_share_bps=share_bps, params=params)
                interest = outcome.interest_paid / A7_ACCOUNTS
                rows.append(
                    {
                        "mechanism": outcome.mechanism,
                        "protocol_fee_pct": fee_bps / 100,
                        "reserve_pct": reserve_bps / 100,
                        "lender_share_pct": share_bps / 100,
                        "interest_per_account": round(interest, 6),
                        "profit_per_account": round(outcome.net_profit / A7_ACCOUNTS, 6),
                        "closed_form": round(atk.self_lending_theory(mechanism, params, share_bps), 6),
                        "honest_lender_loss_per_account": round(outcome.honest_lender_loss / A7_ACCOUNTS, 6),
                        "accounting_residual": outcome.accounting_residual,
                    }
                )
    return rows


def run_reserve_drain() -> list[dict]:
    """M3r residual case, per farmed account: the attack, its counterfactual (same lender, no
    farm), the difference, and the closed form for the difference. M3e (earmarked reserve, a
    proposal) runs the same grid; earmarking keeps the farm's contribution from being drained,
    so its closed form is the drain-0 one."""
    rows = []
    n = DRAIN_ACCOUNTS
    grid = itertools.product(
        (ConservationReserveDues, EarmarkedReserveDues), DRAIN_ROUTES, DRAIN_CASES, DRAIN_SHARES_BPS, DRAINS
    )
    for mechanism, via, (fee_bps, reserve_bps, case), share_bps, drain in grid:
        params = Params(protocol_fee_bps=fee_bps, reserve_bps=reserve_bps)
        f, r = fee_bps / 10_000, reserve_bps / 10_000
        run = partial(atk.reserve_drain, mechanism, n, share_bps, drain, via, params=params)
        attack, baseline = run(), run(farm=False)
        drained = drain if mechanism is ConservationReserveDues else 0.0
        profit, honest_loss = atk.reserve_drain_theory(n, share_bps, drained, params=params)
        rows.append(
            {
                "mechanism": label(mechanism),
                "via": via,
                "case": case,
                "protocol_fee_pct": fee_bps / 100,
                "reserve_pct": reserve_bps / 100,
                "lender_share_pct": share_bps / 100,
                "drain": drain,
                "breakeven_share_pct": round(100 * (1 - r) / (1 - f), 4),
                "attack_profit": round(attack.net_profit / n, 6),
                "counterfactual_profit": round(baseline.net_profit / n, 6),
                "farm_gain": round((attack.net_profit - baseline.net_profit) / n, 6),
                "farm_gain_closed_form": round(profit / n, 6),
                "honest_lender_loss_increase": round((attack.honest_lender_loss - baseline.honest_lender_loss) / n, 6),
                "honest_lender_loss_closed_form": round(honest_loss / n, 6),
                "accounting_residual": max(abs(attack.accounting_residual), abs(baseline.accounting_residual)),
            }
        )
    return rows


def run_honest() -> tuple[list[dict], list[dict]]:
    backing = [atk.honest_backing(mechanism) for mechanism in MECHANISMS]
    history = [
        row for mechanism in MECHANISMS for start in ("line", "backed") for row in atk.honest_history(mechanism, start)
    ]
    return backing, history


# ───────────────────────────── output ─────────────────────────────


def write_csv(path: Path, rows: list[dict]) -> None:
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def profit_table(outcomes: list[atk.Outcome]) -> dict[tuple[str, str], dict[str, dict[int, float]]]:
    """{(attack, variant): {mechanism: {n: net_profit}}}, in SCENARIOS order."""
    table: dict[tuple[str, str], dict[str, dict[int, float]]] = defaultdict(lambda: defaultdict(dict))
    for o in outcomes:
        table[(o.attack, o.variant)][o.mechanism][o.n] = o.net_profit
    return table


def mechanism_labels() -> list[str]:
    return [label(m) for m in MECHANISMS]


def legend_labels() -> list[str]:
    return [label(m, status=True) for m in MECHANISMS]


def _cell(value: float | None) -> str:
    return "n/a" if value is None else f"{value:,.2f}"


def summary_markdown(outcomes, m0_outcomes, sensitivity, drain_rows, backing, history) -> str:
    labels = mechanism_labels()
    keys = [m.key for m in MECHANISMS]
    table = profit_table(outcomes)
    params = Params()
    lines = ["# Results", "", "Generated by `run.py`. USDC; attacker net profit unless stated.", ""]
    lines += [
        f"Protocol fee {params.protocol_fee_bps / 100:g}%, reserve share {params.reserve_bps / 100:g}% of interest "
        "(the deploy script sets fee 0, reserve 30%). Mechanisms:",
        "",
    ]
    lines += [f"- {label(m, status=True)}" for m in MECHANISMS] + [""]

    lines += ["## Attacker net profit at n = 1 and n = 64", ""]
    lines += ["| Attack | Variant | " + " | ".join(f"{k} n=1 | {k} n=64" for k in keys) + " |"]
    lines += ["| --- | --- | " + " | ".join("---: | ---:" for _ in keys) + " |"]
    for scenario in SCENARIOS:
        by_mech = table[(scenario.attack, scenario.variant)]
        cells = []
        for name in labels:
            series = by_mech.get(name)
            cells += [_cell(series[1]) if series else "n/a", _cell(series[64]) if series else "n/a"]
        lines.append(f"| {scenario.attack} | {scenario.variant or '-'} | " + " | ".join(cells) + " |")

    lines += ["", "## Marginal profit per extra attacker account, (p(64) - p(32)) / 32", ""]
    lines += [
        "| Attack | Variant | " + " | ".join(keys) + " |",
        "| --- | --- | " + " | ".join("---:" for _ in keys) + " |",
    ]
    for scenario in SCENARIOS:
        by_mech = table[(scenario.attack, scenario.variant)]
        cells = [_cell((by_mech[name][64] - by_mech[name][32]) / 32) if name in by_mech else "n/a" for name in labels]
        lines.append(f"| {scenario.attack} | {scenario.variant or '-'} | " + " | ".join(cells) + " |")

    lines += ["", "## M0 by honest world (attacker net profit at n = 1 / 8 / 64)", ""]
    lines += [
        "| Attack | Variant | " + " | ".join(M0_WORLDS) + " |",
        "| --- | --- | " + " | ".join("---:" for _ in M0_WORLDS) + " |",
    ]
    m0 = defaultdict(dict)
    for o in m0_outcomes:
        m0[(o.attack, o.variant, o.world)][o.n] = o.net_profit
    for scenario in M0_SCENARIOS:
        cells = []
        for world in M0_WORLDS:
            p = m0[(scenario.attack, scenario.variant, world)]
            cells.append(f"{p[1]:,.1f} / {p[8]:,.1f} / {p[64]:,.1f}")
        lines.append(f"| {scenario.attack} | {scenario.variant or '-'} | " + " | ".join(cells) + " |")

    lines += ["", "## A7 sensitivity: profit per farmed account (one 100 USDC loan for a year)", ""]
    lines += ["| Mechanism | Fee % | Reserve % | " + " | ".join(f"s={s / 100:g}%" for s in LENDER_SHARES_BPS) + " |"]
    lines += ["| --- | ---: | ---: | " + " | ".join("---:" for _ in LENDER_SHARES_BPS) + " |"]
    grouped = defaultdict(list)
    for row in sensitivity:
        grouped[(row["mechanism"], row["protocol_fee_pct"], row["reserve_pct"])].append(row["profit_per_account"])
    for (mech, fee, reserve), profits in grouped.items():
        lines.append(f"| {mech} | {fee:g} | {reserve:g} | " + " | ".join(f"{p:.3f}" for p in profits) + " |")

    lines += ["", "## M3r residual case: farm gain per account over the same lender doing nothing", ""]
    lines += [
        "Via other borrowers' defaults; the release route gives the same numbers. Closed form: "
        "I (r - 1 + s (1 - f - r)) + s c / n, with c = min(n r I, drained beyond the earlier reserve).",
        "",
    ]
    lines += [
        "| Case | Fee % | Reserve % | Drain | s* % | " + " | ".join(f"s={s / 100:g}%" for s in DRAIN_SHARES_BPS) + " |"
    ]
    lines += ["| --- | ---: | ---: | ---: | ---: | " + " | ".join("---:" for _ in DRAIN_SHARES_BPS) + " |"]
    m3r, m3e = label(ConservationReserveDues), label(EarmarkedReserveDues)
    grouped = defaultdict(list)
    for row in drain_rows:
        if row["mechanism"] == m3r and row["via"] == "defaults":
            key = (row["case"], row["protocol_fee_pct"], row["reserve_pct"], row["drain"], row["breakeven_share_pct"])
            grouped[key].append(row["farm_gain"])
    for (case, fee, reserve, drain, breakeven), gains in grouped.items():
        lines.append(
            f"| {case} | {fee:g} | {reserve:g} | {drain:g} | {breakeven:.1f} | "
            + " | ".join(f"{g:.3f}" for g in gains)
            + " |"
        )
    lines += ["", "Absolute attacker profit per account via `releaseReserve`, drain 1, no other losses:", ""]
    lines += ["| Case | " + " | ".join(f"s={s / 100:g}%" for s in DRAIN_SHARES_BPS) + " |"]
    lines += ["| --- | " + " | ".join("---:" for _ in DRAIN_SHARES_BPS) + " |"]
    released = defaultdict(list)
    for row in drain_rows:
        if row["mechanism"] == m3r and row["via"] == "release" and row["drain"] == 1.0:
            released[row["case"]].append(row["attack_profit"])
    for case, profits in released.items():
        lines.append(f"| {case} | " + " | ".join(f"{p:.3f}" for p in profits) + " |")
    best = max((r for r in drain_rows if r["mechanism"] == m3e), key=lambda r: r["farm_gain"])
    lines += [
        "",
        f"{label(EarmarkedReserveDues, status=True)}: the largest farm gain over the same grid (both routes) is "
        f"{best['farm_gain']:.3f} per account ({best['case']}, s = {best['lender_share_pct']:g}%).",
    ]

    lines += ["", "## H1: Avery (line 92) backs Brighton with 50", ""]
    lines += ["| Mechanism | Brighton limit | Avery limit | Avery after Brighton borrows 50 | Sum of limits |"]
    lines += ["| --- | ---: | ---: | ---: | ---: |"]
    for row in backing:
        lines.append(
            f"| {row['mechanism']} | {row['brighton_limit']:.2f} | {row['avery_limit']:.2f} | "
            f"{row['avery_limit_after_brighton_borrows_50']:.2f} | {row['total_capacity']:.2f} |"
        )

    lines += ["", "## H2: own credit after 12 repaid 30-day loans of 50 USDC", ""]
    lines += [
        "| Mechanism | Start: own line 50 | Start: no line, backed 50 | Interest paid |",
        "| --- | ---: | ---: | ---: |",
    ]
    final = {(r["mechanism"], r["start"]): r for r in history if r["month"] == 12}
    for name in labels:
        line, backed = final[(name, "line")], final[(name, "backed")]
        lines.append(
            f"| {name} | {line['own_credit']:.2f} | {backed['own_credit']:.2f} | {line['interest_paid']:.2f} |"
        )
    return "\n".join(lines) + "\n"


# ───────────────────────────── figures ─────────────────────────────

SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK_SECONDARY = "#52514e"
INK_MUTED = "#898781"
GRID = "#e1e0d9"
AXIS = "#c3c2b7"
SERIES_COLORS = ("#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300")  # validated order
MARKERS = ("o", "s", "^", "D", "P", "v")
# Nested widths and sizes, drawn widest first, so series that coincide show as concentric bands.
LINE_WIDTHS = (3.6, 2.9, 2.3, 1.8, 1.4, 1.0)
MARKER_SIZES = (11.5, 9.5, 7.8, 6.3, 5.0, 3.8)

plt.rcParams.update(
    {
        "figure.facecolor": SURFACE,
        "axes.facecolor": SURFACE,
        "savefig.facecolor": SURFACE,
        "axes.edgecolor": AXIS,
        "axes.labelcolor": INK_SECONDARY,
        "axes.titlecolor": INK,
        "axes.titlesize": 10,
        "axes.labelsize": 9,
        "axes.grid": True,
        "grid.color": GRID,
        "grid.linewidth": 0.8,
        "xtick.color": INK_MUTED,
        "ytick.color": INK_MUTED,
        "xtick.labelsize": 8,
        "ytick.labelsize": 8,
        "legend.frameon": False,
        "legend.fontsize": 8,
        "font.family": "sans-serif",
        "axes.spines.top": False,
        "axes.spines.right": False,
    }
)


def _profit_ylim(values: list[float]) -> tuple[float, float]:
    """Symlog limits that leave room for the most negative value without wasting space."""
    low = min(values, default=0)
    bottom = next((b for b in (-0.5, -15, -150, -1_500) if low >= b / 1.5), -15_000)
    return bottom, 15_000


X_LABELS = {"A6 exit scam": "loans repaid before the exit, m"}  # n counts accounts everywhere else


def _style_profit_axes(ax, ylabel: bool = True, xlabel: str = "attacker accounts n") -> None:
    ax.set_xscale("log", base=2)
    ax.xaxis.set_major_locator(FixedLocator(atk.ATTACK_SIZES))
    ax.xaxis.set_minor_locator(NullLocator())
    ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:g}"))
    ax.set_yscale("symlog", linthresh=1, linscale=0.6)
    ax.yaxis.set_major_locator(FixedLocator([-1_000, -100, -10, -1, 0, 1, 10, 100, 1_000, 10_000]))
    ax.yaxis.set_minor_locator(NullLocator())
    ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:,.0f}"))
    ax.axhline(0, color=AXIS, linewidth=1)
    ax.set_xlabel(xlabel)
    if ylabel:
        ax.set_ylabel("net profit, USDC (symlog)")


def _plot_series(ax, series: dict[str, dict[int, float]], names: list[str]) -> None:
    for i, name in enumerate(names):
        if name not in series:
            continue
        points = series[name]
        xs = sorted(points)
        ax.plot(
            xs,
            [points[x] for x in xs],
            color=SERIES_COLORS[i],
            linewidth=LINE_WIDTHS[i],
            marker=MARKERS[i],
            markersize=MARKER_SIZES[i],
            markeredgecolor=SURFACE,
            markeredgewidth=1.0,
            solid_capstyle="round",
            solid_joinstyle="round",
            label=name,
        )


def _frame(fig, title: str, names: list[str], ncol: int, note: str) -> None:
    """Title, legend and footnote at fixed distances (in inches) from the figure edges."""
    height = fig.get_figheight()
    legend_rows = -(-len(names) // ncol)
    fig.suptitle(title, x=0.01, y=1 - 0.1 / height, ha="left", va="top", color=INK)
    handles = [
        plt.Line2D(
            [],
            [],
            color=SERIES_COLORS[i],
            marker=MARKERS[i],
            markersize=MARKER_SIZES[i],
            markeredgecolor=SURFACE,
            linewidth=LINE_WIDTHS[i],
            label=name,
        )
        for i, name in enumerate(names)
    ]
    fig.legend(handles=handles, loc="upper left", ncol=ncol, bbox_to_anchor=(0.005, 1 - 0.38 / height))
    fig.text(0.5, 0.08 / height, note, ha="center", va="bottom", fontsize=7.5, color=INK_MUTED)
    fig.tight_layout(rect=(0, 0.28 / height, 1, 1 - (0.55 + 0.17 * legend_rows) / height))


def plot_attacks(outcomes: list[atk.Outcome]) -> None:
    table = profit_table(outcomes)
    names, legend = mechanism_labels(), legend_labels()
    note = (
        "Demo world. Coinciding series are drawn as nested bands. M0's A1 and A2 depend on the honest graph: "
        "see M0_worlds.png. Values in results/attacks.csv."
    )

    main = [s for s in SCENARIOS if s.main]
    fig, axes = plt.subplots(2, 4, figsize=(15, 7.4), sharey=True)
    for ax, scenario in zip(axes.flat, main):
        _plot_series(ax, table[(scenario.attack, scenario.variant)], names)
        ax.set_title(f"{scenario.attack}" + (f"\n{scenario.variant}" if scenario.variant else "\n "), loc="left")
        _style_profit_axes(ax, ylabel=ax in axes[:, 0], xlabel=X_LABELS.get(scenario.attack, "attacker accounts n"))
    axes.flat[0].set_ylim(
        *_profit_ylim(
            [o.net_profit for o in outcomes if any(o.attack == s.attack and o.variant == s.variant for s in main)]
        )
    )
    _frame(fig, "Attacker net profit against the number of attacker accounts", legend, 3, note)
    fig.savefig(FIGURES / "attacks_overview.png", dpi=150)
    plt.close(fig)

    by_attack = defaultdict(list)
    for scenario in SCENARIOS:
        by_attack[scenario.attack].append(scenario)
    for attack, scenarios in by_attack.items():
        cols = min(3, len(scenarios))
        rows = -(-len(scenarios) // cols)
        fig, axes = plt.subplots(rows, cols, figsize=(4.6 * cols + 0.6, 3.4 * rows + 1.4), sharey=True, squeeze=False)
        for ax, scenario in zip(axes.flat, scenarios):
            _plot_series(ax, table[(scenario.attack, scenario.variant)], names)
            ax.set_title(scenario.variant or attack, loc="left")
            _style_profit_axes(ax, ylabel=ax in axes[:, 0], xlabel=X_LABELS.get(attack, "attacker accounts n"))
        for ax in list(axes.flat)[len(scenarios) :]:
            ax.set_visible(False)
        axes.flat[0].set_ylim(*_profit_ylim([o.net_profit for o in outcomes if o.attack == attack]))
        _frame(
            fig,
            f"{attack}: attacker net profit",
            legend if cols > 1 else names,
            3 if cols > 1 else 2,
            note if cols > 1 else "",
        )
        fig.savefig(FIGURES / f"{attack.split()[0]}_{'_'.join(attack.split()[1:])}.png", dpi=150)
        plt.close(fig)


def plot_m0_worlds(m0_outcomes: list[atk.Outcome]) -> None:
    series = defaultdict(lambda: defaultdict(dict))
    for o in m0_outcomes:
        series[(o.attack, o.variant)][o.world][o.n] = o.net_profit
    fig, axes = plt.subplots(2, 3, figsize=(13, 7.4), sharey=True)
    for ax, scenario in zip(axes.flat, M0_SCENARIOS):
        _plot_series(ax, series[(scenario.attack, scenario.variant)], list(M0_WORLDS))
        ax.set_title(scenario.attack + (f"\n{scenario.variant}" if scenario.variant else "\n "), loc="left")
        _style_profit_axes(ax, ylabel=ax in axes[:, 0])
    axes.flat[0].set_ylim(*_profit_ylim([o.net_profit for o in m0_outcomes]))
    _frame(
        fig,
        "M0 pagerank_vouch: attacker net profit by honest world",
        list(M0_WORLDS),
        3,
        "demo: Avery (override) vouches for Brighton. unrooted: no weighted node, uniform fallback. "
        "community: seeded random graph with 5 depositing lenders.",
    )
    fig.savefig(FIGURES / "M0_worlds.png", dpi=150)
    plt.close(fig)


def plot_a7_sensitivity(rows: list[dict]) -> None:
    panels = (
        (ConservationDues, "M3 (superseded): dues = interest net of fee"),
        (ConservationReserveDues, "M3r (implemented, after a87d812): dues = reserve share"),
    )
    fig, axes = plt.subplots(1, 2, figsize=(11, 4.4), sharey=True)
    for ax, (mechanism, title) in zip(axes, panels):
        name = f"{mechanism.key} {mechanism.name}"
        for i, (fee, reserve) in enumerate(FEE_RESERVE_CASES):
            points = [
                r
                for r in rows
                if r["mechanism"] == name and r["protocol_fee_pct"] == fee / 100 and r["reserve_pct"] == reserve / 100
            ]
            ax.plot(
                [r["lender_share_pct"] for r in points],
                [r["profit_per_account"] for r in points],
                color=SERIES_COLORS[i],
                linewidth=LINE_WIDTHS[i],
                marker=MARKERS[i],
                markersize=MARKER_SIZES[i],
                markeredgecolor=SURFACE,
                markeredgewidth=1.0,
                label=f"fee {fee / 100:g}%, reserve {reserve / 100:g}%",
            )
        ax.axhline(0, color=AXIS, linewidth=1)
        ax.set_xlabel("attacker's share of the lending pool, %")
        ax.set_title(title, loc="left")
    axes[0].set_ylabel("profit per farmed account, USDC")
    axes[0].legend(loc="upper left")
    fig.suptitle(
        "A7: an attacker who is also a lender farms earned credit (one 100 USDC loan-year, 9.33 interest, per account)",
        x=0.01,
        ha="left",
        color=INK,
    )
    fig.tight_layout(rect=(0, 0, 1, 0.94))
    fig.savefig(FIGURES / "A7_sensitivity.png", dpi=150)
    plt.close(fig)


def plot_reserve_drain(rows: list[dict]) -> None:
    shown = [case for case in DRAIN_CASES if case[2] != "calibration's full recommendation"]
    fig, axes = plt.subplots(1, len(shown), figsize=(4.6 * len(shown), 4.4), sharey=True)
    for ax, (fee, reserve, case) in zip(axes, shown):
        breakeven = 100 * (1 - reserve / 10_000) / (1 - fee / 10_000)
        for i, drain in enumerate(DRAINS):
            points = [
                r
                for r in rows
                if r["mechanism"] == label(ConservationReserveDues)
                and r["via"] == "defaults"
                and r["case"] == case
                and r["drain"] == drain
            ]
            ax.plot(
                [r["lender_share_pct"] for r in points],
                [r["farm_gain"] for r in points],
                color=SERIES_COLORS[i],
                linewidth=LINE_WIDTHS[i],
                marker=MARKERS[i],
                markersize=MARKER_SIZES[i],
                markeredgecolor=SURFACE,
                markeredgewidth=1.0,
                label=f"drain {drain:g}" + (" (reserve exhausted)" if drain >= 1 else ""),
            )
        ax.axhline(0, color=AXIS, linewidth=1)
        ax.axvline(breakeven, color=INK_MUTED, linewidth=0.8)
        ax.text(breakeven, ax.get_ylim()[0], f" s* = {breakeven:.1f}%", color=INK_SECONDARY, fontsize=8, va="bottom")
        ax.set_title(f"{case}: fee {fee / 100:g}%, reserve {reserve / 100:g}%", loc="left")
        ax.set_xlabel("attacker's share of the lending pool, %")
    axes[0].set_ylabel("farm gain per account, USDC")
    axes[0].legend(loc="upper left")
    fig.suptitle(
        "M3r residual case: what farming dues gains a lender whose reserve contribution is drained "
        "(other defaults or a release)",
        x=0.01,
        ha="left",
        color=INK,
    )
    fig.tight_layout(rect=(0, 0, 1, 0.93))
    fig.savefig(FIGURES / "M3r_reserve_drain.png", dpi=150)
    plt.close(fig)


def plot_history(history: list[dict]) -> None:
    shown = [label(m) for m in (HermesHistory, Conservation, ConservationDues, ConservationReserveDues)]
    all_names = mechanism_labels()
    fig, axes = plt.subplots(1, 2, figsize=(11, 4.2), sharey=True)
    for ax, start, title in zip(
        axes, ("line", "backed"), ("Harper holds a 50 USDC line", "Harper holds nothing; a backer commits 50")
    ):
        for name in shown:
            i = all_names.index(name)
            points = [r for r in history if r["mechanism"] == name and r["start"] == start]
            ax.plot(
                [r["month"] for r in points],
                [r["own_credit"] for r in points],
                color=SERIES_COLORS[i],
                linewidth=LINE_WIDTHS[i],
                marker=MARKERS[i],
                markersize=MARKER_SIZES[i],
                markeredgecolor=SURFACE,
                markeredgewidth=1.0,
                label=name,
            )
        ax.set_title(title, loc="left")
        ax.set_xlabel("month (one 50 USDC, 30-day loan repaid per month)")
        ax.set_xticks(range(0, 13, 2))
        ax.set_ylim(-5, 110)
    axes[0].set_ylabel("own credit, USDC")
    axes[1].legend(loc="center right")
    fig.suptitle("H2: own credit an honest borrower builds by repaying", x=0.01, ha="left", color=INK)
    fig.tight_layout(rect=(0, 0, 1, 0.94))
    fig.savefig(FIGURES / "H2_history.png", dpi=150)
    plt.close(fig)


# ───────────────────────────── main ─────────────────────────────


def main() -> None:
    RESULTS.mkdir(exist_ok=True)
    FIGURES.mkdir(exist_ok=True)

    outcomes = run_attacks()
    m0_outcomes = run_m0_worlds()
    sensitivity = run_a7_sensitivity()
    drain_rows = run_reserve_drain()
    backing, history = run_honest()

    worst = max(abs(o.accounting_residual) for o in outcomes + m0_outcomes)
    assert worst <= 1e-5, f"accounting does not balance: residual {worst} USDC"
    gap = max(abs(r["profit_per_account"] - r["closed_form"]) for r in sensitivity)
    assert gap <= 1e-4, f"A7 simulation departs from its closed form by {gap} USDC"
    gap = max(
        max(
            abs(r["farm_gain"] - r["farm_gain_closed_form"]),
            abs(r["honest_lender_loss_increase"] - r["honest_lender_loss_closed_form"]),
        )
        for r in drain_rows
    )
    assert gap <= 1e-5, f"reserve-drain simulation departs from its closed form by {gap} USDC"
    assert max(r["accounting_residual"] for r in drain_rows) <= 1e-5

    write_csv(RESULTS / "attacks.csv", [o.row() for o in outcomes])
    write_csv(RESULTS / "m0_worlds.csv", [o.row() for o in m0_outcomes])
    write_csv(RESULTS / "a7_sensitivity.csv", sensitivity)
    write_csv(RESULTS / "m3r_reserve_drain.csv", drain_rows)
    write_csv(RESULTS / "honest_h1_backing.csv", backing)
    write_csv(RESULTS / "honest_h2_history.csv", history)
    summary = summary_markdown(outcomes, m0_outcomes, sensitivity, drain_rows, backing, history)
    (RESULTS / "summary.md").write_text(summary)

    plot_attacks(outcomes)
    plot_m0_worlds(m0_outcomes)
    plot_a7_sensitivity(sensitivity)
    plot_reserve_drain(drain_rows)
    plot_history(history)

    print(summary)
    print(f"Wrote {len(outcomes)} attack runs, {len(m0_outcomes)} M0 world runs to {RESULTS} and figures to {FIGURES}")


if __name__ == "__main__":
    main()
