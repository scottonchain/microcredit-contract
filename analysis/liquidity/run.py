"""Run every liquidity experiment and write results/*.csv, results/summary.md and figures/*.png.

    python3 analysis/liquidity/run.py        # about 4 minutes on 4 cores

Experiments (all deterministic; every task derives its seeds from its own parameters):

    static        one borrower at a fresh state: P(max borrowable >= x) and its mean, by regime,
                  over mean degree, q, and a sensitivity grid (n, rewiring, c)
    steady        repeated borrowing with geometric repayment: steady-state success by regime
    equivalence   the issued credit (q) one-hop needs to match each regime at the base q
    sybil         attacker extraction by regime against m Sybils behind g attack edges
"""

from __future__ import annotations

import os

for _var in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_var, "1")

import csv  # noqa: E402
import multiprocessing as mp  # noqa: E402
import sys  # noqa: E402
import time  # noqa: E402
from pathlib import Path  # noqa: E402

import matplotlib  # noqa: E402

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
from matplotlib.ticker import FixedLocator, FuncFormatter, NullLocator  # noqa: E402

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import model as m  # noqa: E402

RESULTS = HERE / "results"
FIGURES = HERE / "figures"

# Realistic base point. maxLoanAmount is 100 USDC (Deploy.s.sol); c = 25 lets a full line back
# four neighbours; a loan of 50 needs at least two full backers under one-hop.
BASE = dict(family="ws", n=1000, degree=8, rewiring=0.1, q=0.2, line=100.0, c=25.0, x=50.0, rho=0.5)
DEGREES = (4, 6, 8, 10, 12)
QS = (0.05, 0.1, 0.2, 0.3, 0.5)
Q_FINE = tuple(np.round(np.arange(0.05, 0.951, 0.05), 2))
SENSITIVITY = [("n", 500), ("n", 2000), ("rewiring", 0.05), ("rewiring", 0.3),
               ("c", 10.0), ("c", 50.0), ("c", 100.0)]
LOADS = (0.25, 0.5, 1.0)
STATIC_REPLICATES, STATIC_BORROWERS = 3, 200
EQUIVALENCE_CAP = 0.99  # a sampled success rate of 1.000 is not a stable target
STEADY_MEASURED, STEADY_BATCHES = 2000, 5  # batches of 400 requests, two mean loan lifetimes at the base
SYBIL_G = (1, 5, 20, 50)
SYBIL_M = (1, 10, 100, 1000)
SYBIL_FAMILIES = ("ws", "ba", "sbm-concentrated")
SYBIL_ENDPOINTS = ("random", "holders", "no credit")
ROOT_SEED = 20261003
REGIME_ORDER = m.REGIMES  # one-hop, 2-hop, 3-hop, unbounded, centralised


def setting(**kw) -> dict:
    return {**BASE, **kw}


def seed_of(*parts) -> int:
    """A stable seed from numbers and strings (Python's hash() is salted per process)."""
    ints = []
    for p in parts:
        if isinstance(p, str):
            ints.extend(p.encode())
        else:
            ints.append(int(round(float(p) * 1000)))
    return int(np.random.SeedSequence([ROOT_SEED, *ints]).generate_state(1)[0])


def population(s: dict, replicate: int) -> m.Network:
    """Graph seed independent of q and c, credit seed independent of q: holder sets are nested
    in q and the graph is shared across q and c (common random numbers)."""
    graph_key = (s["family"], s["n"], s["degree"], s["rewiring"], replicate)
    return m.build_population(s["family"], s["n"], s["degree"], s["q"], s["line"], s["c"],
                              seed_of("graph", *graph_key), rewiring=s["rewiring"],
                              credit_seed=seed_of("credit", *graph_key))


def mean_duration(s: dict) -> float:
    """Steps a loan stays open on average, so that if every request succeeded the open principal
    would be a share rho of all issued credit (Little's law: one request per step)."""
    if "duration" in s:
        return float(s["duration"])
    return s["rho"] * s["q"] * s["n"] * s["line"] / s["x"]


# ───────────────────────────── tasks (run in worker processes) ─────────────────────────────


def borrower_rng(s: dict, rep: int) -> np.random.Generator:
    """The same borrowers for every c, x and loan duration (they do not change who lacks credit)."""
    return np.random.default_rng(seed_of("borrowers", *(v for k, v in s.items() if k not in ("c", "x", "duration")), rep))


def task_static(s: dict) -> dict:
    """Maximum borrowable amount of random borrowers without credit, at a fresh state."""
    values = {r: [] for r in (*REGIME_ORDER, "one-hop-static")}
    checks = 0
    for rep in range(STATIC_REPLICATES):
        net = population(s, rep)
        rng = borrower_rng(s, rep)
        needy = np.flatnonzero(net.credit == 0)
        borrowers = rng.choice(needy, size=min(STATIC_BORROWERS, len(needy)), replace=False)
        fresh = m.State.fresh(net)
        for i, b in enumerate(borrowers):
            v = m.static_values(net, int(b))
            chain = [v["one-hop-static"], v["one-hop"], v["2-hop"], v["3-hop"], v["unbounded"], v["centralised"]]
            assert all(a <= c + 1e-6 for a, c in zip(chain, chain[1:])), (s, int(b), chain)
            if i % 10 == 0:  # path-liable multi-hop is exactly one-hop
                assert abs(m.path_liable(net, fresh, int(b)) - v["one-hop"]) < 1e-6
                checks += 1
            for r in values:
                values[r].append(v[r])
    return {"setting": s, "values": {r: np.array(v) for r, v in values.items()}, "path_liable_checks": checks}


def task_static_onehop(s: dict) -> dict:
    """One-hop only (cheap): used for the fine q grid of the equivalence experiment."""
    vals = []
    for rep in range(STATIC_REPLICATES):
        net = population(s, rep)
        rng = borrower_rng(s, rep)
        needy = np.flatnonzero(net.credit == 0)
        borrowers = rng.choice(needy, size=min(STATIC_BORROWERS, len(needy)), replace=False)
        st = m.State.fresh(net)
        vals.extend(m.onehop(net, st, int(b)).value for b in borrowers)
    return {"setting": s, "values": {"one-hop": np.array(vals)}}


def task_steady(s: dict, regime: str) -> dict:
    """Repeated transactions; the same requests for every regime (seeded by the setting only)."""
    net = population(s, 0)
    duration = mean_duration(s)
    warmup = int(max(3 * duration, 300))
    # the request seed ignores an explicit duration, so the equivalence runs share the base requests
    rng = np.random.default_rng(seed_of("requests", *(v for k, v in s.items() if k != "duration")))
    who, durations = m.request_sequence(warmup + STEADY_MEASURED, np.flatnonzero(net.credit == 0), duration, rng)
    res = m.simulate(net, regime, who, durations, s["x"])
    w = slice(warmup, None)
    ok, routed = res.success[w], res.routed[w]
    batches = ok.reshape(STEADY_BATCHES, -1).mean(axis=1)
    granted = ok.sum() * s["x"]
    direct = ok & ~routed
    nan = float("nan")
    centralised = regime == "centralised"
    return {
        "setting": s,
        "regime": regime,
        "success": float(ok.mean()),
        "se": float(batches.std(ddof=1) / np.sqrt(STEADY_BATCHES)),
        "routed_share": float(routed.sum() / max(ok.sum(), 1)),
        "mean_hops": nan if centralised else float(np.nanmean(res.mean_hops[w][ok])) if ok.any() else nan,
        "slots_per_loan": nan if centralised else float(res.updates[w][ok].mean()) if ok.any() else nan,
        "slots_direct": nan if centralised or not direct.any() else float(res.updates[w][direct].mean()),
        "slots_routed": nan if centralised or not routed.any() else float(res.updates[w][routed].mean()),
        "relayed_share": float(res.relayed[w].sum() / granted) if granted else 0.0,
        "remote_share": float(res.remote[w].sum() / granted) if granted else 0.0,
        "utilisation": float(res.open_principal[w].mean() / net.credit.sum()),
        "duration": duration,
        "warmup": warmup,
    }


def task_sybil(family: str, endpoints_kind: str, g: int) -> list[dict]:
    """Extraction for one honest network and one set of attack edges, for every Sybil count m."""
    s = setting(family=family)
    net = population(s, 0)
    rng = np.random.default_rng(seed_of("sybil", family, endpoints_kind, g))
    pool = {"random": np.arange(net.n), "holders": np.flatnonzero(net.credit > 0),
            "no credit": np.flatnonzero(net.credit == 0)}[endpoints_kind]
    endpoints = rng.choice(pool, size=g, replace=False)
    rows = []
    for size in SYBIL_M:
        attacked, sybils = m.attach_sybils(net, size, endpoints, s["c"], np.random.default_rng(seed_of("ring", size)))
        out = m.sybil_extraction(attacked, sybils)
        rows.append({"family": family, "endpoints": endpoints_kind, "g": g, "m": size,
                     "holder_endpoints": int((net.credit[endpoints] > 0).sum()),
                     "g_times_c": g * s["c"], **out})
    return rows


def run_task(task):
    kind, args = task[0], task[1:]
    return kind, {"static": task_static, "static-onehop": task_static_onehop, "steady": task_steady,
                  "sybil": task_sybil}[kind](*args)


# ───────────────────────────── experiment grid ─────────────────────────────


def static_settings() -> list[dict]:
    out = []
    for family in m.FAMILIES:
        out += [setting(family=family, degree=d) for d in DEGREES]
        out += [setting(family=family, q=q) for q in QS if q != BASE["q"]]
    out += [setting(**{k: v}) for k, v in SENSITIVITY]
    return out


def steady_settings() -> list[dict]:
    out = []
    for family in m.FAMILIES:
        out += [setting(family=family, degree=d) for d in DEGREES]
        out += [setting(family=family, q=q) for q in QS if q != BASE["q"]]
    out += [setting(rho=r) for r in LOADS if r != BASE["rho"]]
    return out


def equivalence_settings() -> list[dict]:
    """One-hop at a fine q grid with the base borrowers' behaviour: each borrower without credit
    asks as often as at the base point, so the mean duration scales with their number."""
    base = mean_duration(BASE)
    return [setting(q=float(q), duration=base * (1 - q) / (1 - BASE["q"])) for q in Q_FINE]


def key(s: dict) -> tuple:
    return tuple(sorted(s.items()))


# ───────────────────────────── aggregation ─────────────────────────────


def summarise_static(result: dict) -> list[dict]:
    s, values = result["setting"], result["values"]
    rows = []
    for regime, v in values.items():
        p = float((v >= s["x"] - 1e-6).mean())
        rows.append({**{k: s[k] for k in ("family", "n", "degree", "rewiring", "q", "c", "x")},
                     "regime": regime, "samples": len(v), "p_borrow_x": p,
                     "se": float(np.sqrt(p * (1 - p) / len(v))),
                     "p_borrow_100": float((v >= 100 - 1e-6).mean()),
                     "mean_max": float(v.mean()), "median_max": float(np.median(v))})
    return rows


def write_csv(path: Path, rows: list[dict]) -> None:
    if not rows:
        return
    fields = list(rows[0].keys())
    with path.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({k: (f"{v:.6g}" if isinstance(v, float) else v) for k, v in row.items()})


def first_q_reaching(qs: np.ndarray, success: np.ndarray, target: float) -> float:
    """Smallest q at which the (monotone envelope of the) one-hop curve reaches target, linearly
    interpolated; nan when the grid never reaches it."""
    env = np.maximum.accumulate(success)
    if env[-1] < target - 1e-9:
        return float("nan")
    i = int(np.argmax(env >= target - 1e-9))
    if i == 0:
        return float(qs[0])
    lo, hi = env[i - 1], env[i]
    return float(qs[i - 1] + (qs[i] - qs[i - 1]) * (target - lo) / (hi - lo))


# ───────────────────────────── figures ─────────────────────────────

SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK_SECONDARY = "#52514e"
INK_MUTED = "#898781"
GRID = "#e1e0d9"
AXIS = "#c3c2b7"
SERIES_COLORS = ("#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4")  # validated order
MARKERS = ("o", "s", "^", "D", "P")
# Nested widths and sizes, drawn widest first, so series that coincide show as concentric bands.
LINE_WIDTHS = (3.4, 2.7, 2.1, 1.6, 1.1)
MARKER_SIZES = (10.5, 8.8, 7.2, 5.8, 4.5)

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


def _line(ax, xs, ys, i, label=None):
    ax.plot(xs, ys, color=SERIES_COLORS[i], linewidth=LINE_WIDTHS[i], marker=MARKERS[i],
            markersize=MARKER_SIZES[i], markeredgecolor=SURFACE, markeredgewidth=1.0,
            solid_capstyle="round", solid_joinstyle="round", label=label, zorder=2 + i)


def _frame(fig, title: str, names, note: str) -> None:
    height = fig.get_figheight()
    fig.suptitle(title, x=0.01, y=1 - 0.1 / height, ha="left", va="top", color=INK)
    handles = [plt.Line2D([], [], color=SERIES_COLORS[i], marker=MARKERS[i], markersize=MARKER_SIZES[i],
                          markeredgecolor=SURFACE, linewidth=LINE_WIDTHS[i], label=name)
               for i, name in enumerate(names)]
    fig.legend(handles=handles, loc="upper left", ncol=len(names), bbox_to_anchor=(0.005, 1 - 0.36 / height))
    fig.text(0.5, 0.08 / height, note, ha="center", va="bottom", fontsize=7.5, color=INK_MUTED)
    fig.tight_layout(rect=(0, 0.3 / height, 1, 1 - 0.5 / height))


def _prob_axis(ax, ylabel=None):
    ax.set_ylim(-0.03, 1.03)
    ax.yaxis.set_major_locator(FixedLocator([0, 0.25, 0.5, 0.75, 1]))
    ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:.0%}"))
    if ylabel:
        ax.set_ylabel(ylabel)


def plot_sweep(static_rows, steady_rows, param: str, values, xlabel: str, filename: str) -> None:
    fig, axes = plt.subplots(2, len(m.FAMILIES), figsize=(4.0 * len(m.FAMILIES), 7.2), sharex=True, sharey=True)
    for col, family in enumerate(m.FAMILIES):
        for row, (rows, ylabel) in enumerate([(static_rows, "P(can borrow 50), fresh network"),
                                              (steady_rows, "steady-state success rate")]):
            ax = axes[row, col]
            for i, regime in enumerate(REGIME_ORDER):
                pts = {}
                for r in rows:
                    if r["family"] != family or r["regime"] != regime:
                        continue
                    other = {k: v for k, v in BASE.items() if k not in (param, "family", "rho", "x")}
                    if all(r.get(k, v) == v for k, v in other.items()) and r.get("rho", BASE["rho"]) == BASE["rho"]:
                        pts[r[param]] = r["p_borrow_x"] if "p_borrow_x" in r else r["success"]
                xs = [x for x in values if x in pts]
                _line(ax, xs, [pts[x] for x in xs], i)
            _prob_axis(ax, ylabel if col == 0 else None)
            ax.xaxis.set_major_locator(FixedLocator(list(values)))
            ax.xaxis.set_minor_locator(NullLocator())
            ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:g}"))
            if row == 0:
                ax.set_title(m.FAMILY_NAMES[family], loc="left")
            if row == 1:
                ax.set_xlabel(xlabel)
    fixed = "mean degree 8" if param == "q" else "q = 0.2"
    _frame(fig, f"Borrowing 50 USDC without own credit, by {xlabel}", REGIME_ORDER,
           f"n = 1000, {fixed}, credit line 100, trust c = 25 per edge. Top: one borrower on a fresh network. "
           "Bottom: repeated loans with geometric repayment, offered load 50% of issued credit.")
    fig.savefig(FIGURES / filename, dpi=150)
    plt.close(fig)


def plot_survival(static_results) -> None:
    shown = [("ws", "Watts-Strogatz"), ("sbm-concentrated", "SBM, credit in half the blocks")]
    fig, axes = plt.subplots(1, len(shown), figsize=(10.5, 4.4), sharey=True)
    grid = np.arange(0, 401, 1)  # amounts are whole USDC at a fresh state, so this traces the steps
    for ax, (family, title) in zip(axes, shown):
        res = static_results[key(setting(family=family))]
        for i, regime in enumerate(REGIME_ORDER[:-1]):
            v = res["values"][regime]
            _line(ax, grid, [(v >= x - 1e-6).mean() for x in grid], i)
        ax.axvline(BASE["x"], color=INK_MUTED, linewidth=0.8)
        ax.text(BASE["x"], 0.6, " loan of 50", color=INK_SECONDARY, fontsize=8, va="bottom")
        ax.set_xlim(0, 400)
        ax.set_xlabel("amount x, USDC")
        ax.set_title(title, loc="left")
        for line in ax.lines:
            line.set_marker("None")
        _prob_axis(ax, "P(max borrowable >= x)" if ax is axes[0] else None)
    _frame(fig, "Probability a borrower without credit can borrow x (fresh network)", REGIME_ORDER[:-1],
           "Base point: n = 1000, mean degree 8, q = 0.2, line 100, c = 25. Centralised is 1 up to 20,000 (all issued credit).")
    for line in fig.legends[0].legend_handles:
        line.set_marker("None")
    fig.savefig(FIGURES / "borrowable_amount.png", dpi=150)
    plt.close(fig)


def plot_equivalence(eq_static, eq_steady, targets_static, targets_steady) -> None:
    fig, axes = plt.subplots(1, 2, figsize=(10.5, 4.4), sharey=True)
    for ax, (curve, targets, title) in zip(axes, [(eq_static, targets_static, "fresh network"),
                                                  (eq_steady, targets_steady, "steady state")]):
        qs = np.array(sorted(curve))
        _line(ax, qs, [curve[q] for q in qs], 0)
        for i, regime in enumerate(REGIME_ORDER[1:4], start=1):
            ax.axhline(targets[regime], color=SERIES_COLORS[i], linewidth=1.2, zorder=1)
            ax.plot([BASE["q"]], [targets[regime]], marker=MARKERS[i], color=SERIES_COLORS[i],
                    markersize=MARKER_SIZES[i], markeredgecolor=SURFACE, zorder=5)
        ax.axvline(BASE["q"], color=INK_MUTED, linewidth=0.8)
        ax.set_xlabel("share of accounts holding credit, q (one-hop)")
        ax.set_title(title, loc="left")
        ax.set_xlim(0, 1)
        _prob_axis(ax, "success rate, loan of 50" if ax is axes[0] else None)
    _frame(fig, "Credit one-hop must issue to match multi-hop at q = 0.2", REGIME_ORDER[:4],
           "Line: one-hop as q grows. Horizontal rules: 2-hop, 3-hop and unbounded at q = 0.2 (marker at q = 0.2). "
           "Watts-Strogatz, n = 1000, degree 8, c = 25.")
    fig.savefig(FIGURES / "equivalent_issuance.png", dpi=150)
    plt.close(fig)


def plot_sybil(rows) -> None:
    fig, axes = plt.subplots(1, 2, figsize=(10.5, 4.4))
    trust = REGIME_ORDER[:4]
    sel = [r for r in rows if r["family"] == "ws" and r["endpoints"] == "random"]
    ax = axes[0]
    g_fixed = 20
    for i, regime in enumerate(trust):
        pts = sorted((r["m"], r[regime]) for r in sel if r["g"] == g_fixed)
        _line(ax, [p[0] for p in pts], [p[1] for p in pts], i)
    ax.axhline(g_fixed * BASE["c"], color=INK_MUTED, linewidth=1.0)
    ax.text(1000, g_fixed * BASE["c"] * 1.03, f"g x c = {g_fixed * BASE['c']:.0f}", color=INK_SECONDARY, fontsize=8,
            va="bottom", ha="right")
    ax.set_xscale("log")
    ax.xaxis.set_major_locator(FixedLocator(list(SYBIL_M)))
    ax.xaxis.set_minor_locator(NullLocator())
    ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:,.0f}"))
    ax.set_ylim(0, g_fixed * BASE["c"] * 1.15)
    ax.set_xlabel("Sybil accounts m")
    ax.set_ylabel("maximum extraction, USDC")
    ax.set_title(f"g = {g_fixed} attack edges, by m", loc="left")
    ax = axes[1]
    for i, regime in enumerate(trust):
        pts = sorted((r["g"], r[regime]) for r in sel if r["m"] == 100)
        _line(ax, [p[0] for p in pts], [p[1] for p in pts], i)
    gs = np.array(SYBIL_G)
    ax.plot(gs, gs * BASE["c"], color=INK_MUTED, linewidth=1.0, zorder=1)
    ax.text(gs[-1], gs[-1] * BASE["c"] * 1.04, "g x c", color=INK_SECONDARY, fontsize=8, va="bottom", ha="center")
    ax.set_ylim(0, gs[-1] * BASE["c"] * 1.15)
    ax.set_xlabel("attack edges g")
    ax.set_title("m = 100 Sybils, by g", loc="left")
    ax.xaxis.set_major_locator(FixedLocator(list(SYBIL_G)))
    _frame(fig, "Sybil extraction is a cut: flat in m, at most g x c", trust,
           "Watts-Strogatz base network, attack edges from random honest accounts, c = 25. "
           "Centralised extraction is all issued credit (20,000) at every m.")
    fig.savefig(FIGURES / "sybil_extraction.png", dpi=150)
    plt.close(fig)


# ───────────────────────────── summary tables ─────────────────────────────


def fmt(v, digits=2, pct=False):
    if v is None or (isinstance(v, float) and np.isnan(v)):
        return "n/a"
    if pct:
        return f"{100 * v:.{max(digits - 2, 0)}f}%" if digits > 2 else f"{100 * v:.0f}%"
    return f"{v:,.{digits}f}"


def md_table(header, rows) -> str:
    out = ["| " + " | ".join(header) + " |", "| " + " | ".join("---" if i == 0 else "---:" for i in range(len(header))) + " |"]
    out += ["| " + " | ".join(str(c) for c in row) + " |" for row in rows]
    return "\n".join(out)


def main() -> None:
    start = time.time()
    RESULTS.mkdir(exist_ok=True)
    FIGURES.mkdir(exist_ok=True)

    steady = steady_settings()
    eq_static = equivalence_settings()
    eq_steady = equivalence_settings()
    tasks = [("steady", s, r) for s in steady for r in ("3-hop", "2-hop", "unbounded")]
    tasks += [("static", s) for s in static_settings()]
    tasks += [("steady", s, r) for s in steady for r in ("one-hop", "centralised")]
    tasks += [("steady", s, "one-hop") for s in eq_steady]
    tasks += [("static-onehop", s) for s in eq_static]
    tasks += [("sybil", f, e, g) for f in SYBIL_FAMILIES for e in SYBIL_ENDPOINTS for g in SYBIL_G]
    workers = os.cpu_count() or 1
    print(f"{len(tasks)} tasks on {workers} processes")
    with mp.Pool(workers) as pool:
        outputs = pool.map(run_task, tasks, chunksize=1)
    print(f"computed in {time.time() - start:.0f} s")

    static_results, steady_rows, eq_static_res, eq_steady_rows, sybil_rows = {}, [], {}, [], []
    eq_keys = {key(s) for s in eq_steady}
    for (kind, out), task in zip(outputs, tasks):
        if kind == "static":
            static_results[key(out["setting"])] = out
        elif kind == "static-onehop":
            eq_static_res[out["setting"]["q"]] = out
        elif kind == "steady":
            s = out["setting"]
            row = {**{k: s[k] for k in ("family", "n", "degree", "rewiring", "q", "c", "x", "rho")}, **out}
            row.pop("setting")
            if key(s) in eq_keys:
                eq_steady_rows.append(row)
            else:
                steady_rows.append(row)
        else:
            sybil_rows.extend(out)

    # ---- static ----
    static_rows = [row for res in static_results.values() for row in summarise_static(res)]
    write_csv(RESULTS / "static.csv", static_rows)
    pl_checks = sum(res["path_liable_checks"] for res in static_results.values())
    samples = sum(len(res["values"]["one-hop"]) for res in static_results.values())
    base_ws = static_results[key(setting())]
    grid = np.arange(0, 401, 5)
    surv = []
    for family in ("ws", "ba", "sbm", "sbm-concentrated"):
        res = static_results[key(setting(family=family))]
        for x in grid:
            surv.append({"family": family, "x": int(x),
                         **{r: float((res["values"][r] >= x - 1e-6).mean()) for r in (*REGIME_ORDER, "one-hop-static")}})
    write_csv(RESULTS / "borrowable_amount.csv", surv)

    # ---- steady ----
    write_csv(RESULTS / "steady.csv", steady_rows)

    # ---- equivalence ----
    def static_p(res, regime="one-hop"):
        v = res["values"][regime]
        return float((v >= BASE["x"] - 1e-6).mean())

    curve_static = {q: static_p(eq_static_res[q]) for q in sorted(eq_static_res)}
    curve_steady = {r["q"]: r["success"] for r in eq_steady_rows}
    targets_static = {r: static_p(base_ws, r) for r in REGIME_ORDER}

    def steady_at(family="ws", **kw):
        s = setting(family=family, **kw)
        return {r["regime"]: r for r in steady_rows if all(r[k] == s[k] for k in ("family", "n", "degree", "rewiring", "q", "c", "x", "rho"))}

    base_steady = steady_at()
    targets_steady = {r: base_steady[r]["success"] for r in REGIME_ORDER}
    qs = np.array(sorted(curve_static))
    eq_rows = []
    for regime in REGIME_ORDER[1:]:
        t_static = min(targets_static[regime], EQUIVALENCE_CAP)
        t_steady = min(targets_steady[regime], EQUIVALENCE_CAP)
        q_static = first_q_reaching(qs, np.array([curve_static[q] for q in qs]), t_static)
        qs2 = np.array(sorted(curve_steady))
        q_steady = first_q_reaching(qs2, np.array([curve_steady[q] for q in qs2]), t_steady)
        eq_rows.append({"regime": regime, "target_static": targets_static[regime], "q_onehop_static": q_static,
                        "issuance_multiple_static": q_static / BASE["q"],
                        "target_steady": targets_steady[regime], "q_onehop_steady": q_steady,
                        "issuance_multiple_steady": q_steady / BASE["q"]})
    write_csv(RESULTS / "equivalence.csv", eq_rows)
    write_csv(RESULTS / "equivalence_curve.csv",
              [{"q": q, "onehop_static": curve_static[q], "onehop_steady": curve_steady.get(q, float("nan"))}
               for q in sorted(curve_static)])

    # ---- sybil checks ----
    trust = REGIME_ORDER[:4]
    by_case = {}
    for r in sybil_rows:
        by_case.setdefault((r["family"], r["endpoints"], r["g"]), []).append(r)
    for case, rs in by_case.items():
        for regime in (*REGIME_ORDER, "path-liable"):
            vals = [r[regime] for r in rs]
            assert max(vals) - min(vals) < 1e-6, (case, regime, vals)
        for r in rs:
            for regime in REGIME_ORDER:
                assert abs(r[regime] - r[f"{regime} cut"]) < 1e-5, (case, regime)
            for regime in trust:
                assert r[regime] <= r["g_times_c"] + 1e-6
            assert abs(r["path-liable"] - r["one-hop"]) < 1e-6
            assert abs(r["one-hop"] - r["holder_endpoints"] * BASE["c"]) < 1e-6
    write_csv(RESULTS / "sybil.csv", sybil_rows)

    # ---- realistic gains table ----
    realistic = []
    for family in m.FAMILIES:
        res = static_results[key(setting(family=family))]
        st = steady_at(family)
        p = {r: static_p(res, r) for r in (*REGIME_ORDER, "one-hop-static")}
        mean = {r: float(res["values"][r].mean()) for r in (*REGIME_ORDER, "one-hop-static")}
        row = {"family": family}
        for r in (*REGIME_ORDER, "one-hop-static"):
            row[f"static_p_{r}"] = p[r]
        for r in REGIME_ORDER:
            row[f"static_mean_{r}"] = mean[r]
        for r in REGIME_ORDER:
            row[f"steady_{r}"] = st[r]["success"]
            row[f"steady_se_{r}"] = st[r]["se"]
        for tag, src in (("static", p), ("steady", {r: st[r]["success"] for r in REGIME_ORDER})):
            for r in ("2-hop", "3-hop", "unbounded"):
                row[f"{tag}_gain_{r}"] = src[r] / src["one-hop"] if src["one-hop"] > 0 else float("inf")
            gap = src["unbounded"] - src["one-hop"]
            row[f"{tag}_gap_closed_by_2hop"] = (src["2-hop"] - src["one-hop"]) / gap if gap > 1e-9 else float("nan")
            row[f"{tag}_gap_closed_by_3hop"] = (src["3-hop"] - src["one-hop"]) / gap if gap > 1e-9 else float("nan")
        for r in ("2-hop", "3-hop", "unbounded"):
            row[f"mean_gain_{r}"] = mean[r] / mean["one-hop"]
        for r in ("one-hop", "2-hop", "3-hop", "unbounded"):
            for f in ("routed_share", "mean_hops", "slots_per_loan", "slots_direct", "slots_routed", "relayed_share", "remote_share", "utilisation"):
                row[f"{r}_{f}"] = st[r][f]
        realistic.append(row)
    write_csv(RESULTS / "realistic.csv", realistic)

    # ---- figures ----
    plot_sweep(static_rows, steady_rows, "degree", DEGREES, "mean degree", "success_vs_degree.png")
    plot_sweep(static_rows, steady_rows, "q", QS, "share of accounts holding credit, q", "success_vs_q.png")
    plot_survival(static_results)
    plot_equivalence(curve_static, curve_steady, targets_static, targets_steady)
    plot_sybil(sybil_rows)

    # ---- facts quoted in the summary ----
    ses = [r["se"] for r in steady_rows]
    conc = population(setting(family="sbm-concentrated", q=0.5), 0)
    across = (conc.credit[conc.tail] > 0) & (conc.credit[conc.head] == 0)
    facts = {"se_min": min(ses), "se_max": max(ses),
             "se_base_max": max(r["se"] for r in steady_rows if r["family"] == "ws" and r["degree"] == 8
                                and r["q"] == BASE["q"] and r["rho"] == BASE["rho"]),
             "conc_cut_edges": int(across.sum()), "conc_cut_capacity": float(conc.cap[across].sum()),
             "conc_demand": 0.5 * conc.credit.sum()}

    # ---- summary.md ----
    write_summary(static_rows, steady_rows, realistic, eq_rows, sybil_rows, pl_checks, samples, facts,
                  time.time() - start)
    print(f"done in {time.time() - start:.0f} s")


def write_summary(static_rows, steady_rows, realistic, eq_rows, sybil_rows, pl_checks, samples, facts, seconds) -> None:
    L = []
    L.append("# Liquidity: the price of the one-hop restriction\n")
    L.append("Generated by `run.py`. Base point: n = 1000, mean degree 8, Watts-Strogatz rewiring 0.1, "
             "q = 0.2 of accounts hold a line of 100, trust c = 25 per edge, loan x = 50, offered load 50% "
             "of issued credit in the steady state. P is the share of borrowers without credit who can "
             "borrow 50; steady is the steady-state success rate of repeated requests.\n")
    L.append(f"Checks passed: every static sample satisfies one-hop-static <= one-hop <= 2-hop <= 3-hop <= "
             f"unbounded <= centralised ({samples:,} borrowers); path-liable multi-hop equals one-hop on "
             f"{pl_checks:,} of them; every Sybil extraction equals its regime's cut, is identical for "
             f"m = 1 to 1,000, and is at most g x c in every trust regime.\n")

    L.append("## 1. Gain over one-hop at the base point\n")
    L.append("Fresh network, one borrower:\n")
    hdr = ["Graph", "one-hop (static commit)", "one-hop", "2-hop", "3-hop", "unbounded", "centralised",
           "2-hop / one-hop", "3-hop / one-hop", "gap closed by 2 hops", "mean max: one / 2 / 3 / unb."]
    rows = []
    for r in realistic:
        rows.append([m.FAMILY_NAMES[r["family"]], fmt(r["static_p_one-hop-static"], 3), fmt(r["static_p_one-hop"], 3),
                     fmt(r["static_p_2-hop"], 3), fmt(r["static_p_3-hop"], 3), fmt(r["static_p_unbounded"], 3),
                     fmt(r["static_p_centralised"], 3), f"{r['static_gain_2-hop']:.2f}x", f"{r['static_gain_3-hop']:.2f}x",
                     fmt(r["static_gap_closed_by_2hop"], 2, pct=True),
                     " / ".join(f"{r[f'static_mean_{x}']:.0f}" for x in ("one-hop", "2-hop", "3-hop", "unbounded"))])
    L.append(md_table(hdr, rows) + "\n")
    L.append(f"Steady state, repeated loans. Standard errors from {STEADY_BATCHES} batch means are {facts['se_min']:.3f} to "
             f"{facts['se_max']:.3f} over all steady runs (at most {facts['se_base_max']:.3f} at the base point).\n")
    hdr = ["Graph", "one-hop", "2-hop", "3-hop", "unbounded", "centralised", "2-hop / one-hop",
           "3-hop / one-hop", "gap closed by 2 hops", "by 3 hops"]
    rows = []
    for r in realistic:
        rows.append([m.FAMILY_NAMES[r["family"]]] + [fmt(r[f"steady_{x}"], 3) for x in REGIME_ORDER]
                    + [f"{r['steady_gain_2-hop']:.2f}x", f"{r['steady_gain_3-hop']:.2f}x",
                       fmt(r["steady_gap_closed_by_2hop"], 2, pct=True), fmt(r["steady_gap_closed_by_3hop"], 2, pct=True)])
    L.append(md_table(hdr, rows) + "\n")

    L.append("## 2. Who stands behind the multi-hop loans, and what they cost on-chain\n")
    L.append("Steady state at the base point. Routed: granted loans that needed a path longer than one arc. "
             "Relayed: share of granted volume entering the borrower from an account with no credit (it chose to "
             "trust the borrower and has nothing to charge). Remote: share supplied by holders not adjacent to the "
             "borrower (they are charged on default but never chose it). Slots: storage slots a loan touches "
             "(one per source and one per arc), for direct and routed loans.\n")
    hdr = ["Graph", "Regime", "routed", "mean hops", "relayed", "remote", "slots per direct loan", "slots per routed loan", "issued credit in use"]
    rows = []
    for r in realistic:
        for x in ("one-hop", "2-hop", "3-hop", "unbounded"):
            rows.append([m.FAMILY_NAMES[r["family"]], x, fmt(r[f"{x}_routed_share"], 2, pct=True), fmt(r[f"{x}_mean_hops"], 2),
                         fmt(r[f"{x}_relayed_share"], 2, pct=True), fmt(r[f"{x}_remote_share"], 2, pct=True),
                         fmt(r[f"{x}_slots_direct"], 1), fmt(r[f"{x}_slots_routed"], 1), fmt(r[f"{x}_utilisation"], 2, pct=True)])
    L.append(md_table(hdr, rows) + "\n")

    L.append("## 3. Issued credit one-hop needs to match multi-hop\n")
    L.append("Watts-Strogatz base network. One-hop is run on a fine q grid (holder sets nested, same graph; in the "
             "steady state every borrower without credit asks as often as at the base point). The multiple is the "
             f"issued credit one-hop needs, relative to q = 0.2, to reach the success rate each regime has at "
             f"q = 0.2, capped at {EQUIVALENCE_CAP:.0%}. By Theorem 2 the loss bound grows with it.\n")
    hdr = ["Regime at q = 0.2", "P, fresh", "one-hop needs q", "multiple", "steady", "one-hop needs q", "multiple"]
    rows = [[r["regime"], fmt(r["target_static"], 3), fmt(r["q_onehop_static"], 2), f"{r['issuance_multiple_static']:.1f}x" if not np.isnan(r["issuance_multiple_static"]) else "not reached by q = 0.95",
             fmt(r["target_steady"], 3), fmt(r["q_onehop_steady"], 2), f"{r['issuance_multiple_steady']:.1f}x" if not np.isnan(r["issuance_multiple_steady"]) else "not reached by q = 0.95"]
            for r in eq_rows]
    L.append(md_table(hdr, rows) + "\n")

    L.append("## 4. Sweeps\n")
    for param, values, label in (("degree", DEGREES, "mean degree"), ("q", QS, "q")):
        L.append(f"### By {label} (other parameters at the base point)\n")
        hdr = ["Graph", label] + [f"P {r}" for r in REGIME_ORDER] + [f"steady {r}" for r in REGIME_ORDER]
        rows = []
        for family in m.FAMILIES:
            for v in values:
                s = setting(family=family, **{param: v})
                sp = {r["regime"]: r for r in static_rows if all(r[k] == s[k] for k in ("family", "n", "degree", "rewiring", "q", "c"))}
                ss = {r["regime"]: r for r in steady_rows if all(r[k] == s[k] for k in ("family", "n", "degree", "rewiring", "q", "c", "rho"))}
                rows.append([m.FAMILY_NAMES[family], f"{v:g}"] + [fmt(sp[r]["p_borrow_x"], 2) for r in REGIME_ORDER]
                            + [fmt(ss[r]["success"], 2) for r in REGIME_ORDER])
        L.append(md_table(hdr, rows) + "\n")
    L.append("In the q sweep the offered load stays at 50% of issued credit, so demand grows with q. In the SBM with "
             f"credit in half the blocks, at q = 0.5 every account there holds credit and every borrower sits in the "
             f"other half: {facts['conc_demand']:,.0f} of demand must cross {facts['conc_cut_edges']} trust arcs "
             f"between the halves, {facts['conc_cut_capacity']:,.0f} of capacity. That cut binds every trust regime alike.\n")
    L.append("### Sensitivity (Watts-Strogatz, fresh network)\n")
    hdr = ["Change from base"] + [f"P {r}" for r in REGIME_ORDER] + ["2-hop / one-hop", "3-hop / one-hop", "mean max one / 2 / 3"]
    rows = []
    for name, v in [("base", None)] + SENSITIVITY:
        s = setting() if v is None else setting(**{name: v})
        sp = {r["regime"]: r for r in static_rows if all(r[k] == s[k] for k in ("family", "n", "degree", "rewiring", "q", "c"))}
        rows.append([("base" if v is None else f"{name} = {v:g}")] + [fmt(sp[r]["p_borrow_x"], 2) for r in REGIME_ORDER]
                    + [f"{sp['2-hop']['p_borrow_x'] / sp['one-hop']['p_borrow_x']:.2f}x",
                       f"{sp['3-hop']['p_borrow_x'] / sp['one-hop']['p_borrow_x']:.2f}x",
                       " / ".join(f"{sp[x]['mean_max']:.0f}" for x in ("one-hop", "2-hop", "3-hop"))])
    L.append(md_table(hdr, rows) + "\n")
    L.append("### Load (Watts-Strogatz base, steady state)\n")
    hdr = ["Offered load"] + list(REGIME_ORDER) + ["2-hop / one-hop", "3-hop / one-hop"]
    rows = []
    for rho in LOADS:
        s = setting(rho=rho)
        ss = {r["regime"]: r for r in steady_rows if all(r[k] == s[k] for k in ("family", "n", "degree", "rewiring", "q", "c", "rho"))}
        rows.append([f"{rho:.0%}"] + [fmt(ss[r]["success"], 3) for r in REGIME_ORDER]
                    + [f"{ss['2-hop']['success'] / ss['one-hop']['success']:.2f}x", f"{ss['3-hop']['success'] / ss['one-hop']['success']:.2f}x"])
    L.append(md_table(hdr, rows) + "\n")

    L.append("## 5. Sybil extraction\n")
    L.append("m Sybils (no credit, unlimited trust among themselves) behind g attack edges of capacity c = 25 from "
             "honest accounts. Extraction is the maximum flow into the Sybil set from a fresh network. Every value "
             "is identical for m = 1, 10, 100 and 1,000, and equals the regime's cut: one-hop's bipartite cut, the "
             "2-hop layered min-cut, the 3-hop LP dual and the unbounded min-cut. Endpoint share: part of the "
             "extraction charged to holders that trusted a Sybil themselves.\n")
    hdr = ["Graph", "Attack edges from", "g", "g x c", "holder endpoints", "one-hop", "2-hop", "3-hop", "unbounded",
           "path-liable", "centralised", "unbounded charged to endpoints"]
    rows = []
    for r in sybil_rows:
        if r["m"] != SYBIL_M[0]:
            continue
        rows.append([m.FAMILY_NAMES[r["family"]], r["endpoints"], r["g"], f"{r['g_times_c']:,.0f}", r["holder_endpoints"],
                     f"{r['one-hop']:,.0f}", f"{r['2-hop']:,.0f}", f"{r['3-hop']:,.1f}", f"{r['unbounded']:,.0f}",
                     f"{r['path-liable']:,.0f}", f"{r['centralised']:,.0f}", fmt(r["unbounded endpoint share"], 2, pct=True)])
    L.append(md_table(hdr, rows) + "\n")
    L.append(f"Runtime: {seconds:.0f} s.\n")
    (RESULTS / "summary.md").write_text("\n".join(L))


if __name__ == "__main__":
    main()
