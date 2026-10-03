"""The on-chain side of the issuer policy: contract constants, an exact port of
OracleScoreProvider's budget rules, and a small lending-pool model that keeps the history the
issuer reads.

Amounts are integer micro-USDC and scores are integer SCALE units (1e6 = one full line of
`maxLoanAmount`), as in the contracts. Every rule that exists in a contract uses the contract's
integer arithmetic. A call the contract would reject raises `Revert` with the custom-error name.

The pool keeps only what the issuer needs: loans (principal, term, disbursedAt, repaid, status),
`completedLoans`, `defaultedLoans`, `duesPaid`, `creditLoss`, `creditCommitted`,
`activeLoanCount`, `isKYCVerified`, stake and backing edges, and each account's limit by the
contract's formula. It has no share accounting, liquidity or withdrawal queue.
"""

from __future__ import annotations

from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass, field
from enum import IntEnum

# ───────────────────────────── contract constants ─────────────────────────────

USDC = 10**6  # one USDC in micro-USDC
SCALE = 10**6  # OracleScoreProvider.SCALE: one full line of maxLoanAmount
MAX_BATCH = 500  # OracleScoreProvider.MAX_BATCH
BASIS_POINTS = 10_000
CENT = 10_000  # balances under a cent are forgiven at closing
HOUR = 3_600
DAY = 86_400
SECONDS_PER_YEAR = 365 * DAY
GRACE_PERIOD = DAY  # no interest during the first day after disbursement
DEFAULT_LOAN_TERM = 30 * DAY
MIN_LOAN_TERM = DAY
MAX_LOAN_TERM = 365 * DAY
LATE_PERIOD = 30 * DAY  # markDefaulted is allowed this long after the due date
MIN_BACKING = USDC  # an edge is 0 or at least 1 USDC
MAX_BACKERS_PER_BORROWER = 32


def mul_div(x: int, y: int, d: int) -> int:
    """OpenZeppelin Math.mulDiv, floored."""
    return (x * y) // d


def usdc(amount: float) -> int:
    """USDC to micro-USDC."""
    return round(amount * USDC)


class Revert(Exception):
    """A call the contract would revert, carrying the custom-error name."""

    def __init__(self, error: str):
        super().__init__(error)
        self.error = error


# ───────────────────────────── OracleScoreProvider ─────────────────────────────


class ScoreProvider:
    """Port of OracleScoreProvider's report and budget logic (`_applyReport`, `releaseBudget`).

    Staleness, the forwarder and ownership are not modelled; the issuer is assumed to send a
    heartbeat (an empty report) inside every `maxScoreAge`.
    """

    def __init__(self, max_total_score: int, max_increase_per_report: int | None = None):
        self.max_total_score = max_total_score
        self.max_increase_per_report = max_total_score if max_increase_per_report is None else max_increase_per_report
        self.epoch = 0
        self.total_score = 0
        self.total_held = 0
        self.scores: dict[str, int] = {}
        self.budget_held: dict[str, int] = {}

    def set_issuance_limits(self, max_total_score: int, max_increase_per_report: int) -> None:
        self.max_total_score = max_total_score
        self.max_increase_per_report = max_increase_per_report

    def score(self, user: str) -> int:
        return self.scores.get(user, 0)

    def held(self, user: str) -> int:
        return self.budget_held.get(user, 0)

    def apply_report(self, epoch: int, users: Sequence[str], scores: Sequence[int]) -> None:
        """`_applyReport`: atomic, as a revert rolls back every write."""
        if not 0 <= epoch < 2**64:
            raise ValueError("epoch is a uint64")
        if epoch <= self.epoch:
            raise Revert("StaleEpoch")
        if len(users) != len(scores):
            raise Revert("LengthMismatch")
        if len(users) > MAX_BATCH:
            raise Revert("BatchTooLarge")
        total, held, increase = self.total_score, self.total_held, 0
        new_scores: dict[str, int] = {}
        new_held: dict[str, int] = {}
        for user, value in zip(users, scores):
            if not isinstance(value, int) or value < 0:
                raise ValueError("scores are uint256")
            if value > SCALE:
                raise Revert("ScoreTooHigh")
            total = total + value - new_scores.get(user, self.scores.get(user, 0))
            user_held = new_held.get(user, self.budget_held.get(user, 0))
            if value > user_held:
                increase += value - user_held
                held += value - user_held
                new_held[user] = value
            new_scores[user] = value
        if increase > 0 and (held > self.max_total_score or increase > self.max_increase_per_report):
            raise Revert("IssuanceBudgetExceeded")
        self.scores.update(new_scores)
        self.budget_held.update(new_held)
        self.total_score = total
        self.total_held = held
        self.epoch = epoch

    def release_budget(self, users: Sequence[str], usage: Callable[[str], tuple[int, int]]) -> int:
        """`releaseBudget`: `usage(user)` returns (activeLoanCount, creditCommitted) from the pool.
        Returns the total released."""
        if len(users) > MAX_BATCH:
            raise Revert("BatchTooLarge")
        released = 0
        for user in users:
            held = self.budget_held.get(user, 0)
            score = self.scores.get(user, 0)
            loans, committed = usage(user)
            if held <= score or loans != 0 or committed != 0:
                continue
            self.budget_held[user] = score
            self.total_held -= held - score
            released += held - score
        return released

    def release_all(self, usage: Callable[[str], tuple[int, int]]) -> int:
        """Call `releaseBudget` on every account holding budget above its score, in batches."""
        users = [u for u, h in self.budget_held.items() if h > self.scores.get(u, 0)]
        return sum(self.release_budget(users[i : i + MAX_BATCH], usage) for i in range(0, len(users), MAX_BATCH))

    def copy(self) -> ScoreProvider:
        other = ScoreProvider(self.max_total_score, self.max_increase_per_report)
        other.epoch, other.total_score, other.total_held = self.epoch, self.total_score, self.total_held
        other.scores = dict(self.scores)
        other.budget_held = dict(self.budget_held)
        return other


# ───────────────────────────── lending pool ─────────────────────────────


class LoanStatus(IntEnum):
    NONE = 0
    REQUESTED = 1
    ACTIVE = 2
    REPAID = 3
    DEFAULTED = 4
    CANCELLED = 5


@dataclass(slots=True)
class Loan:
    """A loan as `getLoan` / `getLoanTerms` return it, plus two values the issuer derives from
    events: `closed_at` (block time of the closing `LoanRepaid` or `LoanDefaulted`) and `secured`
    (the most secured backing the borrower itself had received while the loan was open, from the
    `Backed` events naming it as borrower). Neither names a backer."""

    loan_id: int
    borrower: str
    principal: int
    term: int
    disbursed_at: int
    interest_rate_bps: int
    status: LoanStatus = LoanStatus.ACTIVE
    repaid: int = 0
    principal_repaid: int = 0
    closed_at: int | None = None
    secured: int = 0

    @property
    def due_at(self) -> int:
        return self.disbursed_at + self.term

    @property
    def interest_paid(self) -> int:
        return self.repaid - self.principal_repaid


@dataclass(slots=True)
class Account:
    kyc_verified: bool = False
    dues_paid: int = 0
    credit_loss: int = 0
    defaulted_loans: int = 0
    completed_loans: int = 0
    active_loan_count: int = 0
    outstanding: int = 0  # _outstandingPrincipal
    credit_committed: int = 0
    stake: int = 0
    stake_committed: int = 0
    loan_ids: list[int] = field(default_factory=list)


class Pool:
    """The parts of DecentralizedMicrocredit the issuer reads, with the contract's limit,
    backing, repayment and default rules. Scores come from the `ScoreProvider` (assumed fresh)."""

    def __init__(
        self,
        provider: ScoreProvider,
        max_loan: int = usdc(100),
        effr_bps: int = 433,
        premium_bps: int = 800,
        reserve_bps: int = 6_500,
        fee_bps: int = 0,
    ):
        self.provider = provider
        self.max_loan = max_loan
        self.effr_bps = effr_bps
        self.premium_bps = premium_bps
        self.reserve_bps = reserve_bps
        self.fee_bps = fee_bps
        self.accounts: dict[str, Account] = {}
        self.loans: list[Loan] = []
        # borrower -> backer -> [secured, unsecured]; dict order is the contract's slot order
        self.backings: dict[str, dict[str, list[int]]] = {}
        self.lender_loss = 0  # written-off principal not recovered from stake (reserve, then lenders)

    # ── accounts ──

    def account(self, addr: str) -> Account:
        acct = self.accounts.get(addr)
        if acct is None:
            acct = self.accounts[addr] = Account()
        return acct

    def mark_kyc_verified(self, addr: str) -> None:
        acct = self.account(addr)
        if acct.kyc_verified:
            raise Revert("AlreadyVerified")
        acct.kyc_verified = True

    def usage(self, addr: str) -> tuple[int, int]:
        """(activeLoanCount, creditCommitted): what `releaseBudget` reads."""
        acct = self.accounts.get(addr)
        return (0, 0) if acct is None else (acct.active_loan_count, acct.credit_committed)

    # ── credit ──

    def granted(self, addr: str) -> int:
        acct = self.account(addr)
        if acct.defaulted_loans:
            return 0
        granted = mul_div(self.max_loan, self.provider.score(addr), SCALE) + acct.dues_paid
        return max(0, granted - acct.credit_loss)

    def secured_in(self, addr: str) -> int:
        return sum(edge[0] for edge in self.backings.get(addr, {}).values())

    def _backing_received(self, addr: str) -> int:
        total = 0
        for backer, (secured, unsecured) in self.backings.get(addr, {}).items():
            total += secured
            if unsecured == 0:
                continue
            b = self.account(backer)
            cover = max(0, self.granted(backer) - b.outstanding)
            total += unsecured if cover >= b.credit_committed else mul_div(unsecured, cover, b.credit_committed)
        return total

    def limit(self, addr: str) -> tuple[int, int]:
        """`getBorrowLimit`: (limit, available)."""
        acct = self.account(addr)
        if acct.defaulted_loans:
            return 0, 0
        limit = max(0, self.granted(addr) - acct.credit_committed) + self._backing_received(addr)
        return limit, max(0, limit - acct.outstanding)

    def free_credit(self, addr: str) -> tuple[int, int]:
        """`getFreeCredit`: (credit, staked)."""
        _, available = self.limit(addr)
        acct = self.account(addr)
        credit = min(max(0, self.granted(addr) - acct.credit_committed), available)
        return credit, acct.stake - acct.stake_committed

    # ── stake and backing ──

    def stake(self, addr: str, amount: int) -> None:
        if amount <= 0:
            raise Revert("ZeroAmount")
        self.account(addr).stake += amount

    def unstake(self, addr: str, amount: int) -> None:
        acct = self.account(addr)
        if amount <= 0 or amount > acct.stake:
            raise Revert("InsufficientStake")
        if acct.stake - amount < acct.stake_committed:
            raise Revert("StakeCommitted")
        acct.stake -= amount

    def back(self, backer: str, borrower: str, amount: int) -> None:
        """`back` / `_setBacking`: set the edge to `amount`, committing free credit first."""
        if backer == borrower:
            raise Revert("SelfBacking")
        if amount != 0 and amount < MIN_BACKING:
            raise Revert("BackingTooSmall")
        edges = self.backings.setdefault(borrower, {})
        if backer not in edges:
            if len(edges) >= MAX_BACKERS_PER_BORROWER:
                raise Revert("TooManyBackers")
            edges[backer] = [0, 0]
        edge = edges[backer]
        current = edge[0] + edge[1]
        b = self.account(backer)
        if amount > current:
            if self.account(borrower).defaulted_loans:
                raise Revert("BorrowerInDefault")
            extra = amount - current
            free_credit, free_stake = self.free_credit(backer)
            from_credit = min(extra, free_credit)
            if extra - from_credit > free_stake:
                raise Revert("InsufficientCredit")
            edge[1] += from_credit
            edge[0] += extra - from_credit
            b.credit_committed += from_credit
            b.stake_committed += extra - from_credit
        elif amount < current:
            cut = current - amount
            from_credit = min(cut, edge[1])
            saved = (list(edge), b.credit_committed, b.stake_committed)
            edge[1] -= from_credit
            edge[0] -= cut - from_credit
            b.credit_committed -= from_credit
            b.stake_committed -= cut - from_credit
            limit, _ = self.limit(borrower)
            if self.account(borrower).outstanding > limit:
                edge[:], b.credit_committed, b.stake_committed = saved
                raise Revert("BackingInUse")
        if amount == 0:
            del edges[backer]
        self._track_secured(borrower)

    def _track_secured(self, borrower: str) -> None:
        secured = self.secured_in(borrower)
        for loan_id in self.account(borrower).loan_ids:
            loan = self.loans[loan_id]
            if loan.status == LoanStatus.ACTIVE and secured > loan.secured:
                loan.secured = secured

    # ── loans ──

    def borrow(self, addr: str, amount: int, now: int, term: int = DEFAULT_LOAN_TERM) -> Loan:
        """`borrowAndDisburseMeta`: originate and disburse at once (liquidity is not modelled)."""
        if amount <= 0:
            raise Revert("ZeroAmount")
        if not MIN_LOAN_TERM <= term <= MAX_LOAN_TERM:
            raise Revert("InvalidTerm")
        acct = self.account(addr)
        if acct.defaulted_loans:
            raise Revert("BorrowerInDefault")
        limit, available = self.limit(addr)
        if limit == 0:
            raise Revert("NoCredit")
        if amount > available:
            raise Revert("BorrowLimitExceeded")
        loan = Loan(len(self.loans), addr, amount, term, now, self.effr_bps + self.premium_bps)
        loan.secured = self.secured_in(addr)
        self.loans.append(loan)
        acct.loan_ids.append(loan.loan_id)
        acct.active_loan_count += 1
        acct.outstanding += amount
        return loan

    def interest_accrued(self, loan: Loan, now: int) -> int:
        elapsed = now - loan.disbursed_at
        if elapsed < GRACE_PERIOD:
            return 0
        return ((loan.principal * loan.interest_rate_bps) // BASIS_POINTS * elapsed) // SECONDS_PER_YEAR

    def outstanding(self, loan: Loan, now: int) -> int:
        if loan.status != LoanStatus.ACTIVE:
            return 0
        return max(0, loan.principal + self.interest_accrued(loan, now) - loan.repaid)

    def repay(self, loan: Loan, now: int, amount: int | None = None) -> int:
        """`_repay`: interest first; closes below a cent. Returns the amount paid."""
        if loan.status != LoanStatus.ACTIVE:
            raise Revert("LoanNotActive")
        owed = self.outstanding(loan, now)
        paid = owed if amount is None else min(amount, owed)
        acct = self.account(loan.borrower)
        if paid > 0:
            interest_due = self.interest_accrued(loan, now) - loan.interest_paid
            interest = min(paid, interest_due)
            principal = paid - interest
            loan.repaid += paid
            loan.principal_repaid += principal
            acct.outstanding -= principal
            acct.dues_paid += (interest * self.reserve_bps) // BASIS_POINTS
        if owed - paid < CENT:
            unpaid = loan.principal - loan.principal_repaid
            acct.outstanding -= unpaid
            acct.active_loan_count -= 1
            acct.completed_loans += 1
            loan.status = LoanStatus.REPAID
            loan.closed_at = now
            self.lender_loss += unpaid
        return paid

    def mark_defaulted(self, loan: Loan, now: int) -> int:
        """`markDefaulted` with `_chargeBackers`. Returns the loss not recovered from stake."""
        if loan.status != LoanStatus.ACTIVE:
            raise Revert("LoanNotActive")
        if now <= loan.disbursed_at + loan.term + LATE_PERIOD:
            raise Revert("NotYetDefaultable")
        written_off = loan.principal - loan.principal_repaid
        acct = self.account(loan.borrower)
        acct.outstanding -= written_off
        acct.active_loan_count -= 1
        acct.defaulted_loans += 1
        loan.status = LoanStatus.DEFAULTED
        loan.closed_at = now
        slashed = self._charge_backers(loan.borrower, written_off)
        self.lender_loss += written_off - slashed
        return written_off - slashed

    def _charge_backers(self, borrower: str, loss: int) -> int:
        edges = self.backings.get(borrower, {})
        total_secured = sum(e[0] for e in edges.values())
        total_unsecured = sum(e[1] for e in edges.values())
        from_stake = min(loss, total_secured)
        from_credit = min(loss - from_stake, total_unsecured)
        release = self.account(borrower).active_loan_count == 0
        recovered = 0
        for backer, edge in list(edges.items()):
            b = self.account(backer)
            slashed = 0 if from_stake == 0 else mul_div(from_stake, edge[0], total_secured)
            charged = 0 if from_credit == 0 else mul_div(from_credit, edge[1], total_unsecured)
            b.stake -= slashed
            recovered += slashed
            b.credit_loss += charged
            rel_secured = edge[0] if release else slashed
            rel_unsecured = edge[1] if release else charged
            b.stake_committed -= rel_secured
            b.credit_committed -= rel_unsecured
            edge[0] -= rel_secured
            edge[1] -= rel_unsecured
        return recovered

    def loans_of(self, addr: str) -> list[Loan]:
        return [self.loans[i] for i in self.account(addr).loan_ids]

    def unsecured_exposure(self, addrs: Iterable[str]) -> int:
        """Lenders' potential loss on these accounts: open principal not covered by secured backing."""
        return sum(max(0, self.account(a).outstanding - self.secured_in(a)) for a in addrs)
