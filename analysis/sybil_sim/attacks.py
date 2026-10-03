"""Attacks and honest scenarios, run against any mechanism in `mechanisms.py`.

Every attack builds a fresh world (`build_world`), runs a fixed script for the attacker's
accounts, and returns an `Outcome` that measures who gained and who lost:

    net_profit = change in the attacker's wealth: wallet + stake + lender shares, less the
                 capital the attacker brought in (to pay interest, stake or deposit)
               = extracted - interest_paid - stake_lost + lender_pnl

where `extracted` is principal received and never repaid. The other side of the ledger is
honest lenders (share value), honest backers (stake slashed, credit burned), the protocol fee and
the first-loss reserve; `accounting_residual` checks that the two sides balance.

Attackers create accounts for free. Loans run for `DEFAULT_LOAN_TERM` (30 days) unless stated,
and defaults are marked as soon as the contract allows (due date + `LATE_PERIOD`).
"""

from __future__ import annotations

import random
from dataclasses import asdict, dataclass

import networkx as nx

from mechanisms import (
    BASIS_POINTS,
    DAY,
    DEFAULT_LOAN_TERM,
    HOUR,
    LATE_PERIOD,
    MIN_LOAN_TERM,
    SECONDS_PER_YEAR,
    USDC,
    Conservation,
    ConservationDues,
    ConservationReserveDues,
    HermesHistory,
    PageRankVouch,
    Params,
    Protocol,
    Revert,
    Status,
)

ATTACK_SIZES = (1, 2, 4, 8, 16, 32, 64)

LENDER, AVERY, BRIGHTON = "lender", "avery", "brighton"
POOL_DEPOSIT = 1_000_000 * USDC  # deep enough that pool limits never bind
AVERY_LINE = 92 * USDC
BRIGHTON_LINE = 25 * USDC
AVERY_BACKS_BRIGHTON = 50 * USDC

SEED = 100 * USDC  # A4's seed: a stake K or a granted line of this size
COLLUSIVE_LINE = 100 * USDC  # A5's legitimately granted line
GRACE_REPAYMENT = 23 * HOUR  # inside the 24-hour interest-free window
MONTH = 30 * DAY
YEAR_TERM = 365 * DAY
COMMUNITY_SEED = 20261003  # fixed seed for the random honest community (M0 sensitivity)


# ───────────────────────────── worlds ─────────────────────────────


@dataclass
class World:
    name: str
    protocol: Protocol
    lenders: list[str]  # honest lenders
    accounts: list[str]  # honest borrowers and backers


def build_world(mechanism: type[Protocol], world: str = "demo", params: Params = Params()) -> World:
    """The honest state an attack starts from.

    demo       the deploy script's credit: Avery holds a 92 USDC line and backs Brighton with 50;
               Brighton holds 25 of his own. At 21b838d (M0) Brighton had no override and his
               credit came from Avery's vouch, so M0 gives him none of his own.
    unrooted   the same lines but no backing or vouch yet. For M0 the attestation graph has no
               node with personalisation weight, so PageRank falls back to uniform.
    community  demo plus a seeded random community: 5 lenders who deposit 100 USDC and vouch for
               3 members each, and 20 members who vouch for each other with probability 0.1.
               Only meaningful for M0; elsewhere vouches carry no credit and are not attempted.
    """
    m = mechanism(params)
    m.mint(LENDER, POOL_DEPOSIT)
    m.deposit(LENDER, POOL_DEPOSIT)
    m.grant_line(AVERY, AVERY_LINE)
    if not isinstance(m, PageRankVouch):
        m.grant_line(BRIGHTON, BRIGHTON_LINE)
    if world in ("demo", "community"):
        m.back(AVERY, BRIGHTON, AVERY_BACKS_BRIGHTON)
    lenders, accounts = [LENDER], [AVERY, BRIGHTON]
    if world == "community":
        community_lenders, members = _add_community(m)
        lenders += community_lenders
        accounts += members
    elif world not in ("demo", "unrooted"):
        raise ValueError(f"unknown world {world!r}")
    return World(world, m, lenders, accounts)


def _add_community(m: Protocol) -> tuple[list[str], list[str]]:
    rng = random.Random(COMMUNITY_SEED)
    lenders = [f"community_lender_{i}" for i in range(5)]
    members = [f"community_member_{i}" for i in range(20)]
    for lender in lenders:
        m.mint(lender, 100 * USDC)
        m.deposit(lender, 100 * USDC)
    if isinstance(m, PageRankVouch):
        graph = nx.gnp_random_graph(len(members), 0.1, seed=COMMUNITY_SEED, directed=True)
        with m.batch():
            for lender in lenders:
                for member in rng.sample(members, 3):
                    m.back(lender, member, 1)
            for u, v in graph.edges:
                m.back(members[u], members[v], 1)
    return lenders, members


def sybils(prefix: str, n: int) -> list[str]:
    return [f"{prefix}_{i}" for i in range(n)]


# ───────────────────────────── measurement ─────────────────────────────


@dataclass(frozen=True)
class Outcome:
    """One attack run. Money is in USDC; losses are positive when someone is worse off."""

    mechanism: str
    attack: str
    variant: str
    world: str
    n: int
    accounts: int  # attacker accounts used
    net_profit: float
    extracted: float  # principal received and never repaid
    interest_paid: float
    stake_lost: float  # attacker stake slashed
    lender_pnl: float  # attacker's own lender position: withdrawals + value - deposits
    honest_lender_loss: float
    honest_stake_lost: float
    honest_credit_burned: float  # honest backers' credit charged (creditLoss)
    honest_capacity_change: float  # change in honest accounts' borrow limits
    protocol_fees: float
    reserve_change: float
    reverted_calls: int  # attacker calls the contract rejected
    accounting_residual: float  # attacker + every other party; 0 up to share rounding

    def row(self) -> dict:
        return asdict(self)


def _to_usdc(amount: int) -> float:
    return round(amount / USDC, 6)


class Harness:
    """Runs one attacker script on a world and settles the accounts afterwards."""

    def __init__(self, world: World, attacker: list[str]):
        self.world = world
        self.m = world.protocol
        self.attacker = attacker
        self.honest_lenders = [a for a in world.lenders if a not in attacker]
        self.honest_accounts = [a for a in world.accounts if a not in attacker]
        self.loans: list[int] = []
        self.reverted = 0
        self._start = self._snapshot()

    # ── attacker actions ──

    def back(self, pairs: list[tuple[str, str]], amount: int) -> None:
        """Try every backing (or vouch); the contract may reject some."""
        with self.m.batch():
            for backer, borrower in pairs:
                try:
                    self.m.back(backer, borrower, amount)
                except Revert:
                    self.reverted += 1

    def borrow(self, account: str, amount: int, term: int = DEFAULT_LOAN_TERM) -> int:
        loan_id = self.m.borrow(account, amount, term)
        self.loans.append(loan_id)
        return loan_id

    def repay_in_full(self, loan_id: int) -> None:
        """Repay with the principal received plus whatever interest the attacker has to bring."""
        loan = self.m.loans[loan_id]
        shortfall = self.m.amount_owed(loan_id) - self.m.wallet[loan.borrower]
        if shortfall > 0:
            self.m.mint(loan.borrower, shortfall)
        self.m.repay(loan_id)

    def extract_all(self, accounts: list[str], term: int = DEFAULT_LOAN_TERM) -> None:
        """Every account borrows everything it is allowed to."""
        for account in accounts:
            _, available = self.m.borrow_limit(account)
            if available > 0:
                self.borrow(account, available, term)

    def exit_positions(self) -> None:
        """Withdraw the attacker's lender shares and unstake every free stake."""
        for account in self.attacker:
            if self.m.shares_of[account]:
                self.m.withdraw(account)
            free = self.m.free_stake(account)
            if free > 0:
                self.m.unstake(account, free)

    def default_all(self) -> None:
        """Exit first (as a lender would, while the loans still count at par), then default."""
        self.exit_positions()
        open_loans = [self.m.loans[i] for i in self.loans if self.m.loans[i].status is Status.ACTIVE]
        if open_loans:
            self.m.now = max(self.m.now, max(loan.due_at for loan in open_loans) + LATE_PERIOD + 1)
            for loan in open_loans:
                self.m.mark_defaulted(loan.id)
        self.exit_positions()  # stake released by the defaults

    # ── settlement ──

    def _wealth(self, accounts: list[str]) -> int:
        m = self.m
        return sum(m.wallet[a] + m.stake_balance(a) + m.lender_balance(a) - m.minted[a] for a in accounts)

    def _snapshot(self) -> dict[str, int]:
        m = self.m
        return {
            "attacker": self._wealth(self.attacker),
            "extracted": sum(m.received[a] - m.principal_paid[a] for a in self.attacker),
            "interest": sum(m.interest_paid[a] for a in self.attacker),
            "stake_lost": sum(m.slashed[a] for a in self.attacker),
            "honest_lenders": sum(m.lender_balance(a) for a in self.honest_lenders),
            "honest_others": self._wealth(self.honest_accounts),
            "honest_stake_lost": sum(m.slashed[a] for a in self.honest_accounts),
            "honest_credit_burned": sum(m.credit_loss[a] for a in self.honest_accounts),
            "honest_capacity": sum(m.borrow_limit(a)[0] for a in self.honest_accounts),
            "fees": m.protocol_fees,
            "reserve": m.first_loss_reserve,
        }

    def outcome(self, attack: str, variant: str, n: int) -> Outcome:
        start, end = self._start, self._snapshot()
        delta = {k: end[k] - start[k] for k in start}
        extracted, interest, stake_lost = delta["extracted"], delta["interest"], delta["stake_lost"]
        lender_pnl = delta["attacker"] - (extracted - interest - stake_lost)
        residual = (
            delta["attacker"] + delta["honest_lenders"] + delta["honest_others"] + delta["fees"] + delta["reserve"]
        )
        return Outcome(
            mechanism=f"{self.m.key} {self.m.name}",
            attack=attack,
            variant=variant,
            world=self.world.name,
            n=n,
            accounts=len(self.attacker),
            net_profit=_to_usdc(delta["attacker"]),
            extracted=_to_usdc(extracted),
            interest_paid=_to_usdc(interest),
            stake_lost=_to_usdc(stake_lost),
            lender_pnl=_to_usdc(lender_pnl),
            honest_lender_loss=_to_usdc(-delta["honest_lenders"]),
            honest_stake_lost=_to_usdc(delta["honest_stake_lost"]),
            honest_credit_burned=_to_usdc(delta["honest_credit_burned"]),
            honest_capacity_change=_to_usdc(delta["honest_capacity"]),
            protocol_fees=_to_usdc(delta["fees"]),
            reserve_change=_to_usdc(delta["reserve"]),
            reverted_calls=self.reverted,
            accounting_residual=_to_usdc(residual),
        )


def _harness(mechanism: type[Protocol], world: str, params: Params, attacker: list[str]) -> Harness:
    return Harness(build_world(mechanism, world, params), attacker)


# ───────────────────────────── attacks ─────────────────────────────


def ring(
    mechanism: type[Protocol], n: int, world: str = "demo", params: Params = Params(), beneficiary: bool = True
) -> Outcome:
    """A1: n fresh accounts back each other in a ring (and, by default, all back one
    beneficiary); then every account borrows its maximum and defaults."""
    members = sybils("ring", n)
    target = ["ring_beneficiary"] if beneficiary else []
    h = _harness(mechanism, world, params, members + target)
    pairs = [(members[i], members[(i + 1) % n]) for i in range(n)] if n > 1 else []
    pairs += [(member, target[0]) for member in members] if beneficiary else []
    h.back(pairs, params.max_loan)
    h.extract_all(members + target)
    h.default_all()
    return h.outcome("A1 ring", "ring + beneficiary" if beneficiary else "pure ring", n)


def stranger_lift(mechanism: type[Protocol], n: int, world: str = "demo", params: Params = Params()) -> Outcome:
    """A2: two fresh, unrooted accounts back each of n fresh strangers; then every account
    borrows its maximum and defaults."""
    vouchers, strangers = sybils("voucher", 2), sybils("stranger", n)
    h = _harness(mechanism, world, params, vouchers + strangers)
    h.back([(v, s) for s in strangers for v in vouchers], params.max_loan)
    h.extract_all(strangers + vouchers)
    h.default_all()
    return h.outcome("A2 stranger lift", "", n)


def deposit_roots(
    mechanism: type[Protocol], n: int, world: str = "demo", params: Params = Params(), beneficiary: bool = True
) -> Outcome:
    """A3: n accounts each deposit 100 USDC as lenders (in M0 that makes them PageRank roots) and
    back each other in a ring (and, by default, all back one beneficiary); they withdraw the
    deposits, then all borrow and default. M0 recomputes PageRank only on attestations, so the
    scores borrowed against still include the withdrawn deposits."""
    roots = sybils("root", n)
    target = ["root_beneficiary"] if beneficiary else []
    h = _harness(mechanism, world, params, roots + target)
    for root in roots:
        h.m.mint(root, 100 * USDC)
        h.m.deposit(root, 100 * USDC)
    pairs = [(roots[i], roots[(i + 1) % n]) for i in range(n)] if n > 1 else []
    pairs += [(root, target[0]) for root in roots] if beneficiary else []
    h.back(pairs, params.max_loan)
    h.exit_positions()
    h.extract_all(roots + target)
    h.default_all()
    return h.outcome("A3 deposit roots", "ring + beneficiary" if beneficiary else "pure ring", n)


def wash_farm(
    mechanism: type[Protocol],
    n: int,
    seed: str = "stake",
    timing: str = "grace",
    cycles: int = 1,
    world: str = "demo",
    params: Params = Params(),
) -> Outcome | None:
    """A4: one seed (a 100 USDC stake, or an account with a 100 USDC line) backs fresh account i,
    which borrows its maximum and repays inside the 24-hour grace period (or after 30 days, with
    interest); the backing is withdrawn and reused for account i + 1. Each account runs `cycles`
    such loans (4 is what M1 needs to reach its ceiling of 100). Finally every account borrows
    its own credit and defaults, and a stake seed is unstaked. Returns None for M0 with a stake
    seed: M0 had no stake."""
    if seed == "stake" and not mechanism.supports_stake:
        return None
    seed_account, farmed = "seed", sybils("farmed", n)
    h = _harness(mechanism, world, params, [seed_account] + farmed)
    m = h.m
    if seed == "stake":
        m.mint(seed_account, SEED)
        m.stake(seed_account, SEED)
    else:
        m.grant_line(seed_account, SEED)
    hold = GRACE_REPAYMENT if timing == "grace" else MONTH

    for account in farmed:
        for _ in range(cycles):
            m.back(seed_account, account, m.backable(seed_account))
            _, available = m.borrow_limit(account)
            if available > 0:
                loan_id = h.borrow(account, available)
                m.advance(hold)
                h.repay_in_full(loan_id)
            m.back(seed_account, account, 0)

    h.extract_all(farmed + [seed_account])
    h.default_all()
    variant = f"{seed} seed, {'grace' if timing == 'grace' else '30-day'} repayment"
    return h.outcome("A4 wash farm", variant + (f", {cycles} cycles" if cycles > 1 else ""), n)


def collusive_backer(mechanism: type[Protocol], n: int, world: str = "demo", params: Params = Params()) -> Outcome:
    """A5: an account with a legitimate 100 USDC line splits its backing over n of its own fresh
    accounts; everyone (the backer included) borrows the maximum and defaults."""
    backer, farmed = "colluder", sybils("colluded", n)
    h = _harness(mechanism, world, params, [backer] + farmed)
    h.m.grant_line(backer, COLLUSIVE_LINE)
    total = h.m.backable(backer)
    with h.m.batch():
        for i, account in enumerate(farmed):
            h.m.back(backer, account, total // n + (1 if i < total % n else 0))
    h.extract_all(farmed + [backer])
    h.default_all()
    return h.outcome("A5 collusive backer", "", n)


def exit_scam(
    mechanism: type[Protocol], n: int, timing: str = "30d", world: str = "demo", params: Params = Params()
) -> Outcome:
    """A6: Brighton (25 USDC of his own, 50 from Avery) repays n loans of his full available
    amount, each after 30 days with interest (or inside the grace period), then borrows
    everything he can and defaults."""
    h = _harness(mechanism, world, params, [BRIGHTON])
    hold = GRACE_REPAYMENT if timing == "grace" else MONTH
    for _ in range(n):
        _, available = h.m.borrow_limit(BRIGHTON)
        loan_id = h.borrow(BRIGHTON, available)
        h.m.advance(hold)
        h.repay_in_full(loan_id)
    h.extract_all([BRIGHTON])
    h.default_all()
    variant = "grace repayments" if timing == "grace" else "30-day repayments"
    return h.outcome("A6 exit scam", variant, n)


def self_lending(
    mechanism: type[Protocol],
    n: int,
    lender_share_bps: int = 5_000,
    world: str = "demo",
    params: Params = Params(),
) -> Outcome | None:
    """A7: the attacker is also a lender owning `lender_share_bps` of the pool. Its stake (100 USDC
    per account, never at risk and unstaked at the end) backs n fresh accounts with 100 USDC each;
    they borrow it for a year and repay with interest, of which the attacker earns its pool share
    back as a lender. Each account then borrows the credit its history earned; the attacker
    withdraws its lender position while those loans still count at par, and they default.
    Returns None for M0, which had no stake."""
    if not mechanism.supports_stake:
        return None
    staker, whale, farmed = "farm_staker", "farm_lender", sybils("dues", n)
    h = _harness(mechanism, world, params, [staker, whale] + farmed)
    m = h.m
    if lender_share_bps:
        whale_deposit = m.total_assets() * lender_share_bps // (BASIS_POINTS - lender_share_bps)
        m.mint(whale, whale_deposit)
        m.deposit(whale, whale_deposit)
    m.mint(staker, SEED * n)
    m.stake(staker, SEED * n)
    loans = []
    for account in farmed:
        m.back(staker, account, SEED)
        loans.append(h.borrow(account, SEED, YEAR_TERM))
    m.advance(YEAR_TERM)
    for account, loan_id in zip(farmed, loans):
        h.repay_in_full(loan_id)
        m.back(staker, account, 0)
    h.extract_all(farmed)
    h.default_all()
    return h.outcome("A7 self-lending dues", f"lender share {lender_share_bps / 100:g}%", n)


def year_interest(params: Params = Params()) -> int:
    """Interest on one A7 / reserve-drain loan: 100 USDC for a year (micro-USDC)."""
    return SEED * params.apr_bps // BASIS_POINTS * YEAR_TERM // SECONDS_PER_YEAR


def self_lending_theory(mechanism: type[Protocol], params: Params, lender_share_bps: int) -> float:
    """A7 profit per account in USDC: the credit the history earned, less the interest, plus the
    attacker's share of the part of that interest that reaches lenders' shares."""
    interest = year_interest(params) / USDC
    s, f, r = lender_share_bps / BASIS_POINTS, params.protocol_fee_bps / BASIS_POINTS, params.reserve_bps / BASIS_POINTS
    earned = {
        HermesHistory: SEED / USDC / 4,  # 25% of the 100 USDC repaid
        Conservation: 0.0,
        ConservationDues: interest * (1 - f),
        ConservationReserveDues: interest * r,
    }[mechanism]
    return earned - interest + s * (1 - f - r) * interest


def reserve_drain(
    mechanism: type[Protocol],
    n: int,
    lender_share_bps: int = 7_500,
    drain: float = 1.0,
    via: str = "defaults",
    initial_reserve: int = 0,
    farm: bool = True,
    world: str = "demo",
    params: Params = Params(),
) -> Outcome | None:
    """Residual case for M3r: A7, but the reserve the farm paid into reaches lenders' shares
    while the attacker is still a lender.

    Timeline: an honest issuer has funded `initial_reserve`; the attacker owns `lender_share_bps`
    of the pool. Its stake backs n fresh accounts that borrow 100 USDC for a year and repay with
    interest, putting `n * r * I` into the reserve; they borrow their dues at once. Then the
    reserve shrinks by `initial_reserve + drain * n * r * I`, either because honest borrowers
    default on that much (`via="defaults"`: lines of at most 100 USDC, one-day terms, absorbed by
    the reserve first) or because the owner releases that much to lenders (`via="release"`). The
    attacker withdraws as a lender, and its dues loans default. With `farm=False` the attacker
    only lends: the counterfactual that isolates what the farm itself gains (the owner can then
    release at most the earlier reserve). Returns None for mechanisms without stake.
    """
    if not mechanism.supports_stake:
        return None
    built = build_world(mechanism, world, params)
    m = built.protocol
    if initial_reserve:
        m.mint("issuer", initial_reserve)
        m.fund_reserve("issuer", initial_reserve)
    farm_reserve = n * (year_interest(params) * params.reserve_bps // BASIS_POINTS)
    drained = initial_reserve + round(drain * farm_reserve)
    others_loss = drained if via == "defaults" else 0
    others = sybils("other_borrower", -(-others_loss // SEED))
    for i, other in enumerate(others):
        m.grant_line(other, min(SEED, others_loss - i * SEED))
    built.accounts += others

    staker, whale, farmed = "farm_staker", "farm_lender", sybils("dues", n)
    h = Harness(built, [staker, whale] + farmed)
    if lender_share_bps:
        whale_deposit = m.total_assets() * lender_share_bps // (BASIS_POINTS - lender_share_bps)
        m.mint(whale, whale_deposit)
        m.deposit(whale, whale_deposit)
    if farm:
        m.mint(staker, SEED * n)
        m.stake(staker, SEED * n)
        loans = []
        for account in farmed:
            m.back(staker, account, SEED)
            loans.append(h.borrow(account, SEED, YEAR_TERM))
    m.advance(YEAR_TERM)
    if farm:
        for account, loan_id in zip(farmed, loans):
            h.repay_in_full(loan_id)
            m.back(staker, account, 0)
        h.extract_all(farmed)

    other_loans = [m.borrow(other, m.borrow_limit(other)[1], MIN_LOAN_TERM) for other in others]
    m.advance(MIN_LOAN_TERM + LATE_PERIOD + 1)
    for loan_id in other_loans:  # absorbed by the reserve while the attacker still lends
        m.mark_defaulted(loan_id)
    if via == "release":
        m.release_reserve(min(drained, m.free_reserve()))
    h.default_all()  # the attacker exits as a lender, then its dues loans default

    variant = f"via {via}, lender share {lender_share_bps / 100:g}%, drain {drain:g}"
    variant += "" if farm else ", counterfactual"
    return h.outcome("A7 reserve drain", variant, n)


def reserve_drain_theory(
    n: int, lender_share_bps: int, drain: float, initial_reserve: int = 0, params: Params = Params()
) -> tuple[float, float]:
    """Closed form for `reserve_drain` on M3r, relative to the counterfactual (USDC); the same
    for both routes.

    With I the interest per account and c = min(n r I, max(0, L - R0)) the part of the farm's
    reserve contribution that reaches lenders' shares, through other borrowers' losses or a
    release L beyond the earlier reserve R0:

        attacker profit      = n I (r - 1 + s (1 - f - r)) + s c
        honest lenders' loss = attacker profit + f n I

    With c = n r I (drain >= 1) the profit is n I (r - 1 + s (1 - f)).
    """
    interest = year_interest(params) / USDC
    s, f, r = lender_share_bps / BASIS_POINTS, params.protocol_fee_bps / BASIS_POINTS, params.reserve_bps / BASIS_POINTS
    farm_reserve = n * (year_interest(params) * params.reserve_bps // BASIS_POINTS) / USDC
    consumed = min(farm_reserve, max(0.0, round(drain * farm_reserve * USDC) / USDC))
    profit = n * interest * (r - 1 + s * (1 - f - r)) + s * consumed
    return profit, profit + f * n * interest


# ───────────────────────────── honest scenarios ─────────────────────────────


def honest_backing(mechanism: type[Protocol], params: Params = Params()) -> dict:
    """H1: Avery (line 92) backs Brighton with 50 (demo world). Brighton's limit, Avery's
    remaining limit, and Avery's limit once Brighton has borrowed 50 of what she backs."""
    m = build_world(mechanism, "demo", params).protocol
    brighton_limit, _ = m.borrow_limit(BRIGHTON)
    avery_limit, _ = m.borrow_limit(AVERY)
    m.borrow(BRIGHTON, min(AVERY_BACKS_BRIGHTON, m.borrow_limit(BRIGHTON)[1]))
    avery_after, _ = m.borrow_limit(AVERY)
    return {
        "mechanism": f"{mechanism.key} {mechanism.name}",
        "brighton_limit": _to_usdc(brighton_limit),
        "avery_limit": _to_usdc(avery_limit),
        "avery_limit_after_brighton_borrows_50": _to_usdc(avery_after),
        "total_capacity": _to_usdc(brighton_limit + avery_limit),
    }


def honest_history(
    mechanism: type[Protocol], start: str = "line", months: int = 12, params: Params = Params()
) -> list[dict]:
    """H2: Harper borrows 50 USDC for 30 days and repays with interest, `months` times in a row.
    `start="line"`: Harper holds a 50 USDC line. `start="backed"`: Harper holds nothing and an
    honest backer (line 92) backs her with 50. Returns her own credit after each month."""
    harper, backer = "harper", "casey"
    m = build_world(mechanism, "demo", params).protocol
    if start == "line":
        m.grant_line(harper, 50 * USDC)
    else:
        m.grant_line(backer, AVERY_LINE)
        m.back(backer, harper, 50 * USDC)
    rows, interest = [], 0
    for month in range(months + 1):
        rows.append(
            {
                "mechanism": f"{mechanism.key} {mechanism.name}",
                "start": start,
                "month": month,
                "own_credit": _to_usdc(m.granted_credit(harper)),
                "limit": _to_usdc(m.borrow_limit(harper)[0]),
                "interest_paid": _to_usdc(interest),
            }
        )
        if month == months:
            break
        loan_id = m.borrow(harper, 50 * USDC)
        m.advance(MONTH)
        owed = m.amount_owed(loan_id)
        m.mint(harper, max(0, owed - m.wallet[harper]))
        m.repay(loan_id)
        interest += owed - 50 * USDC
    return rows
