"""Reference issuer policy for OracleScoreProvider: on-chain history plus identity to credit lines.

The policy has four steps, each a pure function of what the issuer reads:

1. Eligibility (Theorem 3). An account gets a line only if the pool marks it `isKYCVerified` and
   the issuer's identity registry holds a costly identity for it, in a tier with an identity cost
   k_t. One address per identity; a default on any address of an identity ends the identity.
2. Evidence (risk lenders bore). Each closed loan of the account itself is a fractional
   Bernoulli trial. It weighs by its unsecured principal (up to `ref_principal`), by the time it
   was outstanding (up to `trial_days`), and by its age (half-life). A loan closed inside the
   24-hour interest-free window weighs 0, and stake-secured principal weighs 0. Loans of other
   accounts, including accounts this one backed, are never read.
3. PD (Beta-Binomial). A trial is "bad" when the loan was repaid after its due date. The bad-event
   rate theta has a Beta prior per tier, and the posterior after weighted evidence is
   Beta(alpha + bad, beta + good). A bad event is a default with probability 1/(1 + late_ratio),
   so the default probability per 30-day cycle is E[theta] / (1 + late_ratio).
4. Line (expected profit). Borrowers use E[min(line, D)] in normal times (D exponential with mean
   `demand_mean`), but draw the whole line before a default (LGD 100% on the line). Expected profit
   per cycle is i * mu * (1 - exp(-line/mu)) - p * line, with i the risk premium per cycle, so
   the best line is mu * ln(i / p) when p < i, and 0 otherwise. The line is capped by the tier's
   cap_t <= k_t and the budget is allocated by `allocate.allocate`.

The policy never reads the backing graph. Its one backing-derived input is `Loan.secured`, the
account's own incoming secured total while the loan was open, which can only lower a weight.
"""

from __future__ import annotations

import math
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass, field

import numpy as np

import allocate as alloc
from model import (
    DAY,
    GRACE_PERIOD,
    MAX_BATCH,
    SCALE,
    USDC,
    Loan,
    LoanStatus,
    Pool,
    Revert,
    ScoreProvider,
    usdc,
)

# ───────────────────────────── parameters ─────────────────────────────

CYCLE_DAYS = 30.0
PD_GRID = (0.01, 0.02, 0.05, 0.10, 0.20)  # annual PDs of the reference population
# Share of each tier's population at each PD in PD_GRID: the issuer's base rates per tier.
TIER_PD_WEIGHTS = {
    "basic": (0.15, 0.25, 0.30, 0.15, 0.15),
    "standard": (0.25, 0.30, 0.25, 0.12, 0.08),
    "enhanced": (0.35, 0.35, 0.20, 0.08, 0.02),
}
# Identity cost k_t in USDC: what a profit-seeking attacker pays for one identity in the tier
# (market price plus expected penalty). Illustrative, not estimates.
IDENTITY_COST = {"basic": 15.0, "standard": 40.0, "enhanced": 120.0}


def cycle_pd(annual_pd: float, days: float = CYCLE_DAYS) -> float:
    """Default probability per loan cycle under a constant hazard (analysis/credit_risk, H)."""
    return 1.0 - (1.0 - annual_pd) ** (days / 365.0)


def annual_pd(p_cycle: float, days: float = CYCLE_DAYS) -> float:
    return 1.0 - (1.0 - p_cycle) ** (365.0 / days)


def fit_beta_prior(pds: Sequence[float], weights: Sequence[float], late_ratio: float) -> tuple[float, float]:
    """Beta(alpha, beta) for the bad-event rate theta = (1 + late_ratio) * cycle PD, by moments."""
    theta = np.array([(1.0 + late_ratio) * cycle_pd(p) for p in pds])
    w = np.asarray(weights, dtype=float) / float(np.sum(weights))
    mean = float(w @ theta)
    var = float(w @ theta**2) - mean**2
    strength = mean * (1.0 - mean) / var - 1.0
    return mean * strength, (1.0 - mean) * strength


@dataclass(frozen=True)
class Tier:
    name: str
    identity_cost: float  # k_t, USDC
    cap: float  # cap_t, USDC; incentive compatible when min(cap_t, maxLoanAmount) <= k_t
    prior_alpha: float
    prior_beta: float


def default_tiers(late_ratio: float = 2.0, cap_multiple: float = 1.0) -> dict[str, Tier]:
    """Tiers with cap_t = cap_multiple * k_t. cap_multiple <= 1 is incentive compatible."""
    tiers = {}
    for name, weights in TIER_PD_WEIGHTS.items():
        a, b = fit_beta_prior(PD_GRID, weights, late_ratio)
        k = IDENTITY_COST[name]
        tiers[name] = Tier(name, k, cap_multiple * k, a, b)
    return tiers


@dataclass(frozen=True)
class PolicyParams:
    tiers: Mapping[str, Tier] = field(default_factory=default_tiers)
    max_loan: int = usdc(100)  # DecentralizedMicrocredit.maxLoanAmount
    effr_bps: int = 433
    premium_bps: int = 800  # DeployProduction default (analysis/credit_risk, annual PD 5%)
    late_ratio: float = 2.0  # late repayments per default, among bad events
    ref_principal: int = usdc(10)  # unsecured principal that makes a full trial
    trial_days: float = CYCLE_DAYS  # time outstanding that makes a full trial
    half_life_days: float = 365.0  # evidence loses half its weight per year
    demand_mean: float = 50.0  # mu, USDC: mean of a borrower's normal-times draw
    increment: int = SCALE // 100  # allocation step, score units (1 USDC at maxLoan 100)

    @property
    def max_loan_usdc(self) -> float:
        return self.max_loan / USDC

    @property
    def premium_per_cycle(self) -> float:
        """i: risk premium earned per drawn USDC per cycle."""
        return self.premium_bps / 10_000 * self.trial_days / 365.0

    def cap_score(self, tier: Tier) -> int:
        return min(SCALE, int(tier.cap * USDC * SCALE // self.max_loan))

    def cap_usdc(self, tier: Tier) -> float:
        return self.cap_score(tier) * self.max_loan_usdc / SCALE


def incentive_compatible(tier: Tier, params: PolicyParams) -> bool:
    """IC condition: the most an identity can ever be issued is at most what it costs."""
    return params.cap_usdc(tier) <= tier.identity_cost


def byzantine_loss_bound(identities: Mapping[str, int], params: PolicyParams) -> float:
    """Lifetime issuer loss an attacker holding these identities (count per tier) can cause on
    the lines issued to them: sum of caps. Dues are paid by the attacker into the reserve."""
    return sum(n * params.cap_usdc(params.tiers[t]) for t, n in identities.items())


# ───────────────────────────── what the issuer reads ─────────────────────────────


@dataclass
class Identity:
    identity_id: str
    tier: str
    addresses: list[str] = field(default_factory=list)  # bound addresses, first is the live one
    revoked: bool = False


class IdentityRegistry:
    """The issuer's own record of costly identities (off-chain). One person, one identity_id:
    deduplication across addresses is the identity provider's job."""

    def __init__(self) -> None:
        self.identities: dict[str, Identity] = {}
        self.by_address: dict[str, str] = {}

    def bind(self, identity_id: str, tier: str, address: str) -> None:
        ident = self.identities.setdefault(identity_id, Identity(identity_id, tier))
        if address not in ident.addresses:
            ident.addresses.append(address)
        self.by_address[address] = identity_id


@dataclass(frozen=True)
class AccountView:
    """Everything the policy may use about one account. It carries no backing edge, no backer,
    and no other account's loans."""

    address: str
    kyc_verified: bool  # isKYCVerified
    tier: str | None  # costly identity tier from the registry, None without one
    identity_ok: bool  # the identity's live address, not revoked, no default on any of its addresses
    defaulted: bool  # defaultedLoans != 0
    loans: tuple[Loan, ...]  # the account's own loans


def read_account(pool: Pool, registry: IdentityRegistry, address: str) -> AccountView:
    acct = pool.account(address)
    ident_id = registry.by_address.get(address)
    tier, ok = None, False
    if ident_id is not None:
        ident = registry.identities[ident_id]
        tier = ident.tier
        ok = (
            not ident.revoked
            and ident.addresses[0] == address
            and all(pool.account(a).defaulted_loans == 0 for a in ident.addresses)
        )
    return AccountView(
        address=address,
        kyc_verified=acct.kyc_verified,
        tier=tier,
        identity_ok=ok,
        defaulted=acct.defaulted_loans != 0,
        loans=tuple(pool.loans_of(address)),
    )


# ───────────────────────────── evidence and PD ─────────────────────────────


def loan_evidence(loan: Loan, now: int, params: PolicyParams) -> tuple[float, float]:
    """(good, bad) trial weight of one loan of the account itself.

    good = recency * min(1, unsecured / ref_principal) * min(1, time outstanding / trial_days),
    and 0 inside the interest-free window or when no interest was paid.
    bad (repaid after the due date) = recency * min(1, principal / ref_principal) *
    min(1, term / trial_days): lateness is not discounted for stake, so stake cannot hide it.
    Open and defaulted loans carry no trial: a default ends the identity.
    """
    if loan.status != LoanStatus.REPAID or loan.closed_at is None:
        return 0.0, 0.0
    age_days = (now - loan.closed_at) / DAY
    recency = 0.5 ** (age_days / params.half_life_days)
    trial = params.trial_days * DAY
    if loan.closed_at > loan.due_at:
        size = min(1.0, loan.principal / params.ref_principal)
        return 0.0, recency * size * min(1.0, loan.term / trial)
    elapsed = loan.closed_at - loan.disbursed_at
    if elapsed < GRACE_PERIOD or loan.interest_paid == 0:
        return 0.0, 0.0
    unsecured = max(0, loan.principal - loan.secured)
    size = min(1.0, unsecured / params.ref_principal)
    return recency * size * min(1.0, min(elapsed, loan.term) / trial), 0.0


def evidence(view: AccountView, now: int, params: PolicyParams) -> tuple[float, float]:
    good = bad = 0.0
    for loan in view.loans:
        g, b = loan_evidence(loan, now, params)
        good += g
        bad += b
    return good, bad


def posterior(view: AccountView, now: int, params: PolicyParams) -> tuple[float, float]:
    """Beta posterior (alpha, beta) of the bad-event rate theta."""
    tier = params.tiers[view.tier] if view.tier in params.tiers else None
    if tier is None:
        raise ValueError("no prior without a tier")
    good, bad = evidence(view, now, params)
    return tier.prior_alpha + bad, tier.prior_beta + good


def pd_cycle(view: AccountView, now: int, params: PolicyParams) -> float:
    """Posterior mean default probability per 30-day cycle."""
    a, b = posterior(view, now, params)
    return a / (a + b) / (1.0 + params.late_ratio)


def is_overdue(view: AccountView, now: int) -> bool:
    return any(loan.status == LoanStatus.ACTIVE and now > loan.due_at for loan in view.loans)


# ───────────────────────────── line sizing ─────────────────────────────


def expected_profit(line_usdc: float, p: float, params: PolicyParams) -> float:
    """Expected issuer profit per cycle of a line: premium on normal-times use, minus the whole
    line lost at default (LGD 100%)."""
    mu, i = params.demand_mean, params.premium_per_cycle
    return i * mu * (1.0 - math.exp(-line_usdc / mu)) - p * line_usdc


def best_line_usdc(p: float, params: PolicyParams) -> float:
    """argmax of expected_profit over line >= 0: mu * ln(i / p) when p < i, else 0."""
    i = params.premium_per_cycle
    return params.demand_mean * math.log(i / p) if 0 < p < i else 0.0


@dataclass(frozen=True)
class Target:
    score: int  # the line the policy wants, before the budget, in score units
    pd_cycle: float  # posterior default probability per cycle (nan when not eligible)
    reason: str  # "line", "unprofitable", or why the account is not eligible


def target(view: AccountView, now: int, params: PolicyParams) -> Target:
    """The account's profit-maximising line under its tier cap, ignoring the budget."""
    if not view.kyc_verified:
        return Target(0, math.nan, "unverified")
    if view.tier is None or view.tier not in params.tiers:
        return Target(0, math.nan, "no_tier")
    if not view.identity_ok or view.defaulted:
        return Target(0, math.nan, "identity_ended")
    p = pd_cycle(view, now, params)
    if is_overdue(view, now):
        return Target(0, p, "overdue")
    line = min(best_line_usdc(p, params), params.cap_usdc(params.tiers[view.tier]))
    score = min(params.cap_score(params.tiers[view.tier]), int(line * USDC * SCALE // params.max_loan))
    return Target(score, p, "line" if score > 0 else "unprofitable")


# ───────────────────────────── reports ─────────────────────────────

Report = tuple[int, list[str], list[int]]


@dataclass
class Plan:
    reports: list[Report]
    new_scores: dict[str, int]
    targets: dict[str, Target]
    increase: int  # sum of raises over current scores (what the per-report cap is checked against)
    budget_used: int  # sum of raises over held budget (what totalHeld grows by)
    expected_profit: float  # per cycle, USDC, over every line in the plan


def plan_report(
    views: Iterable[AccountView],
    belief: ScoreProvider,
    params: PolicyParams,
    now: int,
) -> Plan:
    """Plan the next report(s) against the issuer's belief of the provider's state.

    `belief` is the provider state the issuer last read (scores, budgetHeld, totalHeld, epoch,
    limits). Between that read and the report landing only `releaseBudget` can change it, and it
    only lowers held budget, so the plan is checked against two bracketing states: the belief as
    read, and the belief with every account's held budget released down to its score. The raise
    cap is applied per cycle across all batches, against current scores.
    """
    views = list(views)
    targets = {v.address: target(v, now, params) for v in views}
    addrs = list(targets)
    current = np.array([belief.score(a) for a in addrs], dtype=np.int64)
    held = np.array([belief.held(a) for a in addrs], dtype=np.int64)
    want = np.array([targets[a].score for a in addrs], dtype=np.int64)
    pds = np.array([targets[a].pd_cycle for a in addrs], dtype=float)
    cap_increase, cap_budget = alloc.capacities(
        belief.max_total_score, belief.total_held, belief.max_increase_per_report
    )
    new = alloc.allocate(current, held, want, pds, cap_increase, cap_budget, params)

    changes = [(a, int(n), int(c)) for a, n, c in zip(addrs, new, current) if n != c]
    changes.sort(key=lambda x: (x[1] > x[2], x[0]))  # lowerings first, then by address
    reports: list[Report] = []
    epoch = belief.epoch
    for i in range(0, len(changes), MAX_BATCH):
        chunk = changes[i : i + MAX_BATCH]
        epoch += 1
        reports.append((epoch, [a for a, _, _ in chunk], [n for _, n, _ in chunk]))
    _dry_run(reports, belief)

    new_scores = dict(zip(addrs, (int(x) for x in new)))
    line_usdc = new * params.max_loan_usdc / SCALE
    profit = sum(
        expected_profit(float(x), float(p), params) for x, p in zip(line_usdc, pds) if x > 0 and not math.isnan(p)
    )
    return Plan(
        reports=reports,
        new_scores=new_scores,
        targets=targets,
        increase=int(np.maximum(new - current, 0).sum()),
        budget_used=int(np.maximum(new - held, 0).sum()),
        expected_profit=profit,
    )


def _dry_run(reports: Sequence[Report], belief: ScoreProvider) -> None:
    """Apply the reports to the two bracketing states; a revert here is a planner bug."""
    worst = belief.copy()
    worst.total_held -= sum(h - worst.scores.get(u, 0) for u, h in worst.budget_held.items())
    worst.budget_held = {u: worst.scores.get(u, 0) for u in worst.budget_held}
    for state in (belief.copy(), worst):
        for epoch, users, scores in reports:
            try:
                state.apply_report(epoch, users, scores)
            except Revert as exc:  # pragma: no cover - would be a bug in allocate
                raise AssertionError(f"planned report would revert: {exc.error}") from exc


def heartbeat(belief: ScoreProvider) -> Report:
    """An empty report: keeps scores fresh inside maxScoreAge and never touches the budget."""
    return (belief.epoch + 1, [], [])


def report_json(report: Report) -> dict:
    epoch, users, scores = report
    return {"epoch": epoch, "users": list(users), "scores": [int(s) for s in scores]}


def encode_report(report: Report) -> str | None:
    """abi.encode(uint64 epoch, address[] users, uint256[] scores) as 0x-hex, or None when
    eth_abi is not installed."""
    try:
        from eth_abi import encode  # type: ignore[import-not-found]
    except ImportError:
        return None
    epoch, users, scores = report
    return "0x" + encode(["uint64", "address[]", "uint256[]"], [epoch, list(users), [int(s) for s in scores]]).hex()
