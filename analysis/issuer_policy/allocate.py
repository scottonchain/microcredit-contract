"""Budget allocation: which line raises the next report makes.

Inputs per account, in score units: the current score S, the budget held H >= S, and the target
T (the profit-maximising line under the tier cap). Lowering is free: an account with T <= S gets
T. Raises are cut into segments of `params.increment`, split at H. Each segment has a marginal
expected profit per USDC of line (the average of i * exp(-x / mu) - p over the segment, which
falls as the line grows) and two costs:

- the per-report raise cap, for every unit above S (robust: a `releaseBudget` that lands before
  the report can lower H to S, and the contract then counts the whole raise above S);
- the issuance budget, for every unit above H (units up to H are already held, Theorem 2').

Greedy: take segments in order of marginal profit and skip what no longer fits. This is the
optimum of the linear programme over the segments, up to integer rounding. Every segment uses the
raise cap and only those above H use the budget, so the greedy stops taking budget segments at
some marginal profit m_b and all segments at m_i <= m_b. Those are the KKT conditions with
multipliers lambda_inc = m_i and lambda_bud = m_b - m_i. `allocate_lp` solves the programme with
scipy to check it.
"""

from __future__ import annotations

import numpy as np
from scipy.optimize import linprog

from model import SCALE


def _segments(current, held, target, params):
    """Segments (account, lo, hi) of every raise, split at held budget."""
    acct, lo, hi = [], [], []
    for a in np.nonzero(target > current)[0]:
        s, h, t = int(current[a]), int(held[a]), int(target[a])
        bounds = np.arange(s, t, params.increment, dtype=np.int64)
        bounds = np.union1d(bounds, [t] + ([h] if s < h < t else []))
        acct.append(np.full(len(bounds) - 1, a, dtype=np.int64))
        lo.append(bounds[:-1])
        hi.append(bounds[1:])
    if not acct:
        empty = np.zeros(0, dtype=np.int64)
        return empty, empty, empty
    return np.concatenate(acct), np.concatenate(lo), np.concatenate(hi)


def marginal_profit(lo, hi, p, params) -> np.ndarray:
    """Average marginal expected profit per USDC of line over [lo, hi] (score units)."""
    scale = params.max_loan_usdc / SCALE
    x0, x1 = lo * scale, hi * scale
    mu, i = params.demand_mean, params.premium_per_cycle
    return (i * mu * (np.exp(-x0 / mu) - np.exp(-x1 / mu)) - p * (x1 - x0)) / (x1 - x0)


def capacities(max_total: int, total_held: int, max_increase: int) -> tuple[int, int]:
    """(raise cap, budget room) for a plan. When governance has cut maxTotalScore below
    totalHeld, no score may rise at all: a release landing first would turn even a raise within
    held budget into an increase, and the contract checks every increase against the whole held
    total."""
    if total_held > max_total:
        return 0, 0
    return int(max_increase), int(max_total - total_held)


def allocate(current, held, target, pd_cycle, cap_increase: int, cap_budget: int, params) -> np.ndarray:
    """New scores: lowerings as targeted, raises greedily by marginal profit within both caps.
    A segment with no positive marginal profit is never taken."""
    current = np.asarray(current, dtype=np.int64)
    held = np.maximum(np.asarray(held, dtype=np.int64), current)
    target = np.asarray(target, dtype=np.int64)
    new = np.where(target <= current, target, current)
    acct, lo, hi = _segments(current, held, target, params)
    if len(acct) == 0:
        return new
    mp = marginal_profit(lo, hi, np.asarray(pd_cycle, dtype=float)[acct], params)
    keep = mp > 0  # a prefix of each account's segments, since mp falls as the line grows
    acct, lo, hi, mp = acct[keep], lo[keep], hi[keep], mp[keep]
    if len(acct) == 0:
        return new
    width = hi - lo
    uses_budget = lo >= held[acct]  # segments are split at H, so each is wholly above or below
    if width.sum() <= cap_increase and width[uses_budget].sum() <= cap_budget:
        np.maximum.at(new, acct, hi)
        return new

    order = np.lexsort((lo, acct, -mp))
    room_inc, room_bud = int(cap_increase), int(cap_budget)
    closed = np.zeros(len(current), dtype=bool)
    for k in order:
        a = acct[k]
        if closed[a] or lo[k] != new[a]:
            closed[a] = True
            continue
        take = min(int(width[k]), room_inc, room_bud if uses_budget[k] else room_inc)
        if take <= 0:
            closed[a] = True
            continue
        new[a] += take
        room_inc -= take
        if uses_budget[k]:
            room_bud -= take
        if take < width[k]:
            closed[a] = True
        if room_inc == 0:
            break
    return new


def allocate_lp(current, held, target, pd_cycle, cap_increase: int, cap_budget: int, params):
    """The same allocation as a linear programme over the segments (scipy HiGHS).
    Returns (new scores, objective in USDC per cycle)."""
    current = np.asarray(current, dtype=np.int64)
    held = np.maximum(np.asarray(held, dtype=np.int64), current)
    target = np.asarray(target, dtype=np.int64)
    new = np.where(target <= current, target, current).astype(float)
    acct, lo, hi = _segments(current, held, target, params)
    if len(acct) == 0:
        return new, 0.0
    scale = params.max_loan_usdc / SCALE  # solve in USDC: score units put costs below HiGHS tolerances
    width = (hi - lo) * scale
    uses_budget = (lo >= held[acct]).astype(float)
    mp = marginal_profit(lo, hi, np.asarray(pd_cycle, dtype=float)[acct], params)
    width = np.where(mp > 0, width, 0.0)
    res = linprog(
        -mp,
        A_ub=np.vstack([np.ones_like(width), uses_budget]),
        b_ub=[min(cap_increase, 1e15) * scale, min(cap_budget, 1e15) * scale],
        bounds=list(zip(np.zeros_like(width), width)),
        method="highs",
    )
    if not res.success:  # pragma: no cover
        raise RuntimeError(res.message)
    np.add.at(new, acct, res.x / scale)
    return new, float(-res.fun)


def raise_profit(current, held, new, target, pd_cycle, params) -> float:
    """Objective of an allocation: marginal profit summed over the raised segments (USDC/cycle)."""
    current = np.asarray(current, dtype=np.int64)
    held = np.maximum(np.asarray(held, dtype=np.int64), current)
    acct, lo, hi = _segments(current, held, np.asarray(target, dtype=np.int64), params)
    if len(acct) == 0:
        return 0.0
    new = np.asarray(new, dtype=float)
    taken = np.clip(new[acct] - lo, 0, hi - lo)
    mp = marginal_profit(lo, hi, np.asarray(pd_cycle, dtype=float)[acct], params)
    return float((mp * taken).sum() * params.max_loan_usdc / SCALE)
