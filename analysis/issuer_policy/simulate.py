"""Monthly simulation of the issuer policy against honest borrowers and attackers.

Each month the issuer reads the chain, plans a report and publishes it to the provider port;
borrowers then act in the pool model. Timeline of month m (t_m = m * 30 days):

    t_m            due repayments and defaults settle; a keeper calls releaseBudget on everyone
    t_m            the issuer reads the chain and plans
    t_m + 2 min    a quarter of on-time borrowers repay at the last minute (inside the window)
    t_m + 5 min    a griefer front-runs the report with releaseBudget on everyone
    t_m + 10 min   the report lands (a revert would be counted, and none happens)
    t_m + 1 h      borrowers borrow for 30 days

Agents:

- honest verified borrowers: tier, true annual PD from the tier's population (policy.PD_GRID,
  policy.TIER_PD_WEIGHTS). Each cycle they borrow with probability `activity`: they default with
  the cycle PD (drawing their whole limit first), repay late with late_ratio times that, and
  otherwise repay on time an exponential draw of mean `demand_mean`, capped at their limit.
- identity buyers: buy an identity in a tier at k_t, borrow `ref_principal` (or their limit) and
  repay on time each month to build evidence, then in their bust-out month draw their whole limit
  (line plus dues) and never repay.
- a recycled-seed farm: unverified accounts that a staked seed backs in turn; half repay four
  times a month inside the 24-hour window, half hold 30-day loans. One bought identity runs the
  same farm on itself.
"""

from __future__ import annotations

import heapq
import math
from dataclasses import dataclass, field

import numpy as np

import policy as pol
from model import DAY, LATE_PERIOD, SCALE, USDC, LoanStatus, Pool, Revert, ScoreProvider, usdc

BASE_SEED = 20261003
MONTH = 30 * DAY
T0 = 1_790_000_000  # an arbitrary start time
MINUTE = 60
HOUR = 3_600


def rng_for(*tags: int) -> np.random.Generator:
    return np.random.default_rng(np.random.SeedSequence((BASE_SEED, *tags)))


def address(kind: int, i: int) -> str:
    return f"0x{kind:02x}{i:038x}"


HONEST, ATTACKER, FARM, SEED, CONTROL = 0x10, 0xA0, 0xF0, 0x5E, 0xC0


@dataclass(frozen=True)
class AttackSpec:
    tier: str
    n: int
    bust_month: int  # the month the identities draw everything and stop repaying


@dataclass(frozen=True)
class SimConfig:
    months: int = 24
    n_honest: int = 600
    tier_mix: tuple[tuple[str, float], ...] = (("basic", 0.4), ("standard", 0.4), ("enhanced", 0.2))
    activity: float = 0.85
    budget_lines: float = 150.0  # maxTotalScore, in full lines
    increase_lines: float = 40.0  # maxIncreasePerReport, in full lines
    attacks: tuple[AttackSpec, ...] = ()
    n_farm: int = 8  # unverified accounts in the recycled-seed farm
    farm_grace_cycles: int = 4
    last_minute_share: float = 0.25  # on-time repayments that land between plan and report
    front_run: bool = True
    seed: int = 0
    params: pol.PolicyParams = field(default_factory=pol.PolicyParams)


@dataclass
class Honest:
    addr: str
    tier: str
    pd_annual: float
    p_default: float
    p_late: float
    active: np.ndarray | None = None  # per-month uniforms: borrows this month if < activity
    outcome: np.ndarray | None = None  # per-month uniforms: default, late or on time
    demand: np.ndarray | None = None  # per-month normal-times draw, USDC
    last_minute: np.ndarray | None = None  # per-month uniforms: repays inside the report window


@dataclass
class Attacker:
    addr: str
    tier: str
    bust_month: int
    interest_paid: int = 0
    extracted: int = 0
    line_at_bust: float = 0.0
    dues_at_bust: int = 0


@dataclass
class SimResult:
    config: SimConfig
    honest: list[Honest]
    attackers: list[Attacker]
    monthly: list[dict]  # one row per month: budget, exposure, losses, income, reports
    lines: np.ndarray  # honest line (USDC) after each report, shape (months, n_honest)
    alive: np.ndarray  # honest not defaulted at each report
    post_pd: np.ndarray  # honest posterior annual PD at each report (nan if not eligible)
    cycles: list[tuple]  # (month, addr index, predicted cycle PD, true cycle PD, defaulted)
    farm: list[dict]  # recycled-seed farm accounts at the end
    rejections: int
    front_run_released: int
    pool: Pool
    provider: ScoreProvider


class Simulation:
    def __init__(self, cfg: SimConfig):
        self.cfg = cfg
        self.p = cfg.params
        self.rng = rng_for(1, cfg.seed)
        self.provider = ScoreProvider(int(cfg.budget_lines * SCALE), int(cfg.increase_lines * SCALE))
        self.pool = Pool(
            self.provider,
            max_loan=self.p.max_loan,
            effr_bps=self.p.effr_bps,
            premium_bps=self.p.premium_bps,
        )
        self.registry = pol.IdentityRegistry()
        self.events: list[tuple[int, int, str, int]] = []  # (time, seq, kind, loan_id)
        self._seq = 0
        self.honest: list[Honest] = []
        self.attackers: list[Attacker] = []
        self.owner: dict[str, tuple[str, int]] = {}
        self.month_loss = {"honest": 0, "attacker": 0, "other": 0}
        self.month_income = 0
        self._setup()

    # ── world ──

    def _verify(self, addr: str, tier: str, identity_id: str) -> None:
        self.pool.mark_kyc_verified(addr)
        self.registry.bind(identity_id, tier, addr)

    def _setup(self) -> None:
        cfg, rng = self.cfg, self.rng
        tiers = [t for t, _ in cfg.tier_mix]
        mix = np.array([w for _, w in cfg.tier_mix])
        tier_idx = rng.choice(len(tiers), size=cfg.n_honest, p=mix / mix.sum())
        for i in range(cfg.n_honest):
            tier = tiers[tier_idx[i]]
            w = np.array(pol.TIER_PD_WEIGHTS[tier])
            pd = pol.PD_GRID[rng.choice(len(pol.PD_GRID), p=w / w.sum())]
            p = pol.cycle_pd(pd)
            h = Honest(address(HONEST, i), tier, pd, p, self.p.late_ratio * p)
            # Common random numbers: each borrower's monthly draws do not depend on its lines, so
            # runs that differ only in budget or attackers face the same borrowers and defaults.
            draws = rng_for(2, cfg.seed, i)
            h.active = draws.random(cfg.months)
            h.outcome = draws.random(cfg.months)
            h.demand = draws.exponential(self.p.demand_mean, cfg.months)
            h.last_minute = draws.random(cfg.months)
            self._verify(h.addr, tier, f"h{i}")
            self.honest.append(h)
            self.owner[h.addr] = ("honest", i)
        j = 0
        for spec in cfg.attacks:
            for _ in range(spec.n):
                a = Attacker(address(ATTACKER, j), spec.tier, spec.bust_month)
                self._verify(a.addr, spec.tier, f"a{j}")
                self.attackers.append(a)
                self.owner[a.addr] = ("attacker", j)
                j += 1
        # Recycled-seed farm: a seed stakes once and backs each farm account in turn.
        self.seed_addr = address(SEED, 0)
        self.pool.stake(self.seed_addr, usdc(100) * (cfg.n_farm + 1))
        self.farm = [address(FARM, i) for i in range(cfg.n_farm)]
        # One bought basic identity farms the same way; a fresh basic identity is its control.
        self.verified_farm = address(FARM, 0xFFFF)
        self._verify(self.verified_farm, "basic", "vf")
        self.control = address(CONTROL, 0)
        self._verify(self.control, "basic", "ctl")
        self.all_addrs = (
            [h.addr for h in self.honest]
            + [a.addr for a in self.attackers]
            + self.farm
            + [self.verified_farm, self.control, self.seed_addr]
        )

    def _schedule(self, time: int, kind: str, loan_id: int) -> None:
        self._seq += 1
        heapq.heappush(self.events, (time, self._seq, kind, loan_id))

    def _settle(self, until: int) -> None:
        while self.events and self.events[0][0] <= until:
            time, _, kind, loan_id = heapq.heappop(self.events)
            loan = self.pool.loans[loan_id]
            who = self.owner.get(loan.borrower, ("other", -1))[0]
            if kind == "repay":
                self.pool.repay(loan, time)
                if who in ("honest", "attacker"):
                    self.month_income += loan.interest_paid * self.p.premium_bps // loan.interest_rate_bps
                if who == "attacker":
                    self.attackers[self.owner[loan.borrower][1]].interest_paid += loan.interest_paid
            else:
                self.month_loss[who] += self.pool.mark_defaulted(loan, time)

    # ── one month ──

    def run(self) -> SimResult:
        cfg, p = self.cfg, self.p
        n = len(self.honest)
        lines = np.zeros((cfg.months, n))
        alive = np.zeros((cfg.months, n), dtype=bool)
        post_pd = np.full((cfg.months, n), np.nan)
        monthly, cycles = [], []
        rejections = front_released = 0
        verified = [h.addr for h in self.honest] + [a.addr for a in self.attackers]
        for m in range(cfg.months):
            now = T0 + m * MONTH
            self.month_loss = {"honest": 0, "attacker": 0, "other": 0}
            self.month_income = 0
            self._settle(now)
            self._farm_cut()
            kept = self.provider.release_all(self.pool.usage)

            belief = self.provider.copy()  # what the issuer reads
            views = [pol.read_account(self.pool, self.registry, a) for a in self.all_addrs]
            plan = pol.plan_report(views, belief, p, now)

            self._settle(now + 2 * MINUTE)  # last-minute repayments land after the read
            if cfg.front_run:
                front_released += self.provider.release_all(self.pool.usage)
            for report in plan.reports:
                try:
                    self.provider.apply_report(*report)
                except Revert:
                    rejections += 1

            for i, h in enumerate(self.honest):
                t = plan.targets[h.addr]
                lines[m, i] = self.provider.score(h.addr) * p.max_loan_usdc / SCALE
                alive[m, i] = self.pool.account(h.addr).defaulted_loans == 0
                post_pd[m, i] = pol.annual_pd(t.pd_cycle) if not math.isnan(t.pd_cycle) else np.nan

            borrow_at = now + HOUR
            for i, h in enumerate(self.honest):
                c = self._honest_borrow(h, borrow_at, m)
                if c is not None:
                    cycles.append((m, i, plan.targets[h.addr].pd_cycle, h.p_default, c))
            for a in self.attackers:
                self._attacker_act(a, borrow_at, m)
            self._farm_act(now + 2 * HOUR)

            exposure = self.pool.unsecured_exposure(verified)
            dues = sum(self.pool.account(a).dues_paid for a in verified)
            bound = self.provider.total_held * p.max_loan // SCALE + dues
            if exposure > bound:  # Theorem 2' on the oracle's lines; never happens
                raise AssertionError(f"month {m}: exposure {exposure} above held budget {bound}")
            monthly.append(
                {
                    "month": m,
                    "epoch": self.provider.epoch,
                    "reports": len(plan.reports),
                    "users_in_reports": sum(len(r[1]) for r in plan.reports),
                    "increase": plan.increase / SCALE,
                    "budget_used": plan.budget_used / SCALE,
                    "max_increase": self.provider.max_increase_per_report / SCALE,
                    "released_by_keeper": kept / SCALE,
                    "total_held": self.provider.total_held / SCALE,
                    "total_score": self.provider.total_score / SCALE,
                    "max_total": self.provider.max_total_score / SCALE,
                    "exposure_usdc": exposure / USDC,
                    "exposure_bound_usdc": bound / USDC,
                    "loss_honest_usdc": self.month_loss["honest"] / USDC,
                    "loss_attacker_usdc": self.month_loss["attacker"] / USDC,
                    "premium_income_usdc": self.month_income / USDC,
                    "expected_profit_usdc": plan.expected_profit,
                }
            )
        # Let every open loan settle: repayments and defaults after the last report.
        tail = {"honest": 0, "attacker": 0, "income": 0}
        self.month_loss = {"honest": 0, "attacker": 0, "other": 0}
        self.month_income = 0
        self._settle(T0 + (cfg.months + 3) * MONTH)
        tail.update(honest=self.month_loss["honest"], attacker=self.month_loss["attacker"], income=self.month_income)
        monthly.append(
            {
                "month": cfg.months,
                "loss_honest_usdc": tail["honest"] / USDC,
                "loss_attacker_usdc": tail["attacker"] / USDC,
                "premium_income_usdc": tail["income"] / USDC,
            }
        )
        return SimResult(
            config=cfg,
            honest=self.honest,
            attackers=self.attackers,
            monthly=monthly,
            lines=lines,
            alive=alive,
            post_pd=post_pd,
            cycles=cycles,
            farm=self._farm_summary(T0 + cfg.months * MONTH),
            rejections=rejections,
            front_run_released=front_released,
            pool=self.pool,
            provider=self.provider,
        )

    # ── agents ──

    def _open(self, addr: str) -> bool:
        return self.pool.account(addr).active_loan_count > 0

    def _honest_borrow(self, h: Honest, at: int, m: int) -> int | None:
        """Borrow for one cycle; returns 1 if this cycle ends in default, 0 otherwise, None if idle."""
        if self.pool.account(h.addr).defaulted_loans or self._open(h.addr):
            return None
        if h.active[m] >= self.cfg.activity:
            return None
        _, available = self.pool.limit(h.addr)
        if available < USDC:
            return None
        u = h.outcome[m]
        demand = max(USDC, int(h.demand[m] * USDC))
        if u < h.p_default:
            loan = self.pool.borrow(h.addr, available, at)
            self._schedule(loan.due_at + LATE_PERIOD + 1, "default", loan.loan_id)
            return 1
        loan = self.pool.borrow(h.addr, min(available, demand), at)
        if u < h.p_default + h.p_late:
            self._schedule(at + 45 * DAY, "repay", loan.loan_id)
        elif h.last_minute[m] < self.cfg.last_minute_share:
            self._schedule(T0 + (m + 1) * MONTH + 2 * MINUTE, "repay", loan.loan_id)
        else:
            self._schedule(at + 29 * DAY, "repay", loan.loan_id)
        return 0

    def _attacker_act(self, a: Attacker, at: int, m: int) -> None:
        if m > a.bust_month or self._open(a.addr):
            return
        _, available = self.pool.limit(a.addr)
        if m == a.bust_month:
            a.line_at_bust = self.provider.score(a.addr) * self.p.max_loan_usdc / SCALE
            a.dues_at_bust = self.pool.account(a.addr).dues_paid
            if available > 0:
                loan = self.pool.borrow(a.addr, available, at)
                a.extracted = available
                self._schedule(loan.due_at + LATE_PERIOD + 1, "default", loan.loan_id)
            return
        amount = min(available, self.p.ref_principal)
        if amount >= USDC:  # hold it the whole term, repay at the last minute: a full trial
            loan = self.pool.borrow(a.addr, amount, at)
            self._schedule(T0 + (m + 1) * MONTH + 2 * MINUTE, "repay", loan.loan_id)

    def _farm_act(self, start: int) -> None:
        """The seed backs each farm account with 100 of stake; it borrows 100 and repays."""
        targets = self.farm + [self.verified_farm]
        for k, addr in enumerate(targets):
            if self._open(addr):
                continue
            self.pool.back(self.seed_addr, addr, usdc(100))
            if k % 2 == 0:  # inside the 24-hour interest-free window, several times
                t = start
                for _ in range(self.cfg.farm_grace_cycles):
                    loan = self.pool.borrow(addr, usdc(100), t)
                    self.pool.repay(loan, t + 23 * HOUR)
                    t += DAY
            else:  # a 30-day secured loan, interest paid
                loan = self.pool.borrow(addr, usdc(100), start)
                self._schedule(start + 29 * DAY, "repay", loan.loan_id)

    def _farm_cut(self) -> None:
        for addr in self.farm + [self.verified_farm]:
            if not self._open(addr) and self.pool.backings.get(addr, {}).get(self.seed_addr):
                self.pool.back(self.seed_addr, addr, 0)

    def _farm_summary(self, now: int) -> list[dict]:
        rows = []
        for addr in self.farm + [self.verified_farm, self.control]:
            loans = self.pool.loans_of(addr)
            repaid = [x for x in loans if x.status == LoanStatus.REPAID]
            view = pol.read_account(self.pool, self.registry, addr)
            t = pol.target(view, now, self.p)
            good, bad = pol.evidence(view, now, self.p)
            naive = min(100.0, 0.25 * sum(x.principal for x in repaid) / USDC)  # reviewer's 25% rule
            rows.append(
                {
                    "account": "verified farm" if addr == self.verified_farm else ("control" if addr == self.control else "unverified farm"),
                    "address": addr,
                    "kyc_verified": view.kyc_verified,
                    "tier": view.tier or "",
                    "completed_loans": self.pool.account(addr).completed_loans,
                    "grace_closes": sum(1 for x in repaid if x.closed_at - x.disbursed_at < DAY),
                    "repaid_principal_usdc": sum(x.principal for x in repaid) / USDC,
                    "dues_usdc": self.pool.account(addr).dues_paid / USDC,
                    "evidence_good": good,
                    "evidence_bad": bad,
                    "naive_25pct_line_usdc": naive,
                    "policy_target_usdc": t.score * self.p.max_loan_usdc / SCALE,
                    "published_line_usdc": self.provider.score(addr) * self.p.max_loan_usdc / SCALE,
                    "reason": t.reason,
                }
            )
        return rows


def simulate(cfg: SimConfig) -> SimResult:
    return Simulation(cfg).run()


# ───────────────────────────── attacker accounting ─────────────────────────────


def attacker_profit(result: SimResult, cost_factor: float = 1.0) -> float:
    """Net profit of all identity buyers: principal extracted less interest paid less identity
    cost (k_t * cost_factor per identity; cost_factor < 1 is the issuer overestimating k_t)."""
    p = result.config.params
    total = 0.0
    for a in result.attackers:
        total += (a.extracted - a.interest_paid) / USDC - cost_factor * p.tiers[a.tier].identity_cost
    return total


def best_bust_month(tier: str, params: pol.PolicyParams, months: int = 24) -> tuple[int, list[dict]]:
    """Each bust-out month for one identity in `tier` with no competition for budget: one
    identity per month, a budget that never binds. Returns the month that maximises principal
    extracted less interest (identity cost is sunk, so the best month is the same at any k_t)."""
    cfg = SimConfig(
        months=months,
        n_honest=0,
        attacks=tuple(AttackSpec(tier, 1, b) for b in range(months)),
        budget_lines=1_000.0,
        increase_lines=1_000.0,
        n_farm=0,
        params=params,
    )
    res = simulate(cfg)
    rows = []
    for a in res.attackers:
        rows.append(
            {
                "tier": tier,
                "bust_month": a.bust_month,
                "line_at_bust_usdc": a.line_at_bust,
                "extracted_usdc": a.extracted / USDC,
                "interest_paid_usdc": a.interest_paid / USDC,
                "gross_usdc": (a.extracted - a.interest_paid) / USDC,
                "identity_cost_usdc": params.tiers[tier].identity_cost,
            }
        )
    best = max(rows, key=lambda r: (r["gross_usdc"], -r["bust_month"]))
    return best["bust_month"], rows
