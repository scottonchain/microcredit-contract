"""Credit mechanisms for a collateral-free lending pool, as small state machines.

Each mechanism is a subclass of `Protocol`, which holds what every design shares: one lending
pool with ERC4626-style shares, fixed-APR simple-interest loans with a one-day interest-free
grace period, interest-first repayment, and default after `LATE_PERIOD`. The subclasses differ
only in where a borrower's limit comes from and what a default charges:

    M0   PageRankVouch            the vouching + PageRank design up to commit 21b838d
    M1   HermesHistory            M2 plus "each repaid loan adds 25% of its principal, up to 100"
    M2   Conservation             the conservation design of f0538ae, without earned credit
    M3   ConservationDues         M2 plus dues = interest net of the protocol fee (superseded)
    M3r  ConservationReserveDues  M2 plus dues = the reserve share of interest (implemented)
    M4   CreditNetwork            multi-hop credit network: limit = max-flow from credit sources
    M3e  EarmarkedReserveDues     M3r with the reserve behind dues in use earmarked (a proposal)

Amounts are integer micro-USDC (6 decimals) and every formula that exists in a contract uses the
contract's integer arithmetic (floor division, `mul_div`), so values match Forge tests exactly.
A call the contract would reject raises `Revert` carrying the contract's custom-error name.
"""

from __future__ import annotations

import contextlib
from collections import defaultdict
from collections.abc import Iterator
from dataclasses import dataclass
from enum import Enum

import networkx as nx

# ───────────────────────────── contract constants ─────────────────────────────

USDC = 10**6  # one USDC in micro-USDC
SCALE = 10**6  # credit scores and attestation weights (1e6 = 100%)
BASIS_POINTS = 10_000
CENT = 10_000  # balances under one cent are forgiven on repayment
HOUR = 3_600
DAY = 86_400
SECONDS_PER_YEAR = 365 * DAY
GRACE_PERIOD = DAY  # no interest during the first day after disbursement
DEFAULT_LOAN_TERM = 30 * DAY
MIN_LOAN_TERM = DAY
MAX_LOAN_TERM = 365 * DAY
LATE_PERIOD = 30 * DAY  # a loan can be marked defaulted this long after its due date
MAX_BACKERS_PER_BORROWER = 32
LENDING_UTILIZATION_CAP_BPS = 9_000
LIQUIDITY_BUFFER_BPS = 500
VIRTUAL_SHARES = 10**6  # ERC4626 virtual offset, as in the contract
VIRTUAL_ASSETS = 1


def mul_div(x: int, y: int, d: int, *, round_up: bool = False) -> int:
    """OpenZeppelin Math.mulDiv: x * y / d, floored (or ceiled) without overflow concerns."""
    q, r = divmod(x * y, d)
    return q + 1 if round_up and r else q


def usdc(amount: float) -> int:
    """USDC -> micro-USDC."""
    return round(amount * USDC)


@dataclass(frozen=True)
class Params:
    """Economic parameters shared by every mechanism: the deploy script's, except the protocol
    fee, which the deploy script leaves at 0 and this study sets to 10% (both are varied in A7)."""

    max_loan: int = 100 * USDC  # maxLoanAmount: the line at a 100% credit score
    effr_bps: int = 433
    risk_premium_bps: int = 500
    protocol_fee_bps: int = 1_000  # share of repaid interest kept by the protocol
    reserve_bps: int = 3_000  # share of repaid interest that funds the first-loss reserve

    @property
    def apr_bps(self) -> int:
        return self.effr_bps + self.risk_premium_bps


class Revert(Exception):
    """A call the contract would revert. `error` is the contract's custom-error name."""

    @property
    def error(self) -> str:
        return self.args[0]


class Status(Enum):
    ACTIVE = "active"
    REPAID = "repaid"
    DEFAULTED = "defaulted"


@dataclass
class Loan:
    id: int
    borrower: str
    principal: int
    rate_bps: int
    term: int
    disbursed_at: int
    repaid: int = 0  # interest and principal
    principal_repaid: int = 0
    status: Status = Status.ACTIVE

    @property
    def due_at(self) -> int:
        return self.disbursed_at + self.term


# ───────────────────────────── shared pool and loans ─────────────────────────────


class Protocol:
    """Lending pool, loans and wallets shared by every mechanism.

    Loans are created and disbursed in one step, as `borrowAndDisburseMeta` does, so nothing is
    ever reserved. The withdrawal queue is not modelled: the pool is deep enough that no
    withdrawal in these experiments has to wait.
    """

    key = "base"
    name = "base"
    status = ""  # where the design comes from, for tables and legends
    supports_stake = False
    blocks_defaulters = True  # a default bars the borrower from borrowing again

    def __init__(self, params: Params = Params()):
        self.p = params
        self.now = 0
        self.wallet: defaultdict[str, int] = defaultdict(int)
        self.minted: defaultdict[str, int] = defaultdict(int)  # external capital brought in

        # pool: totalAssets = lender_cash + total_lent_out - first_loss_reserve
        self.lender_cash = 0  # pool cash, the reserve's included
        self.total_lent_out = 0
        self.protocol_fees = 0
        self.first_loss_reserve = 0  # junior claim on the pool: absorbs losses before lenders' shares
        self.shares_of: defaultdict[str, int] = defaultdict(int)
        self.total_shares = 0
        self.lender_principal: defaultdict[str, int] = defaultdict(int)

        # loans
        self.loans: dict[int, Loan] = {}
        self._next_loan_id = 1
        self.outstanding: defaultdict[str, int] = defaultdict(int)  # open principal per borrower
        self.active_loan_count: defaultdict[str, int] = defaultdict(int)
        self.completed_loans: defaultdict[str, int] = defaultdict(int)
        self.defaulted_loans: defaultdict[str, int] = defaultdict(int)

        # bookkeeping for the analysis (not contract state)
        self.received: defaultdict[str, int] = defaultdict(int)  # principal disbursed to
        self.principal_paid: defaultdict[str, int] = defaultdict(int)
        self.interest_paid: defaultdict[str, int] = defaultdict(int)
        self.slashed: defaultdict[str, int] = defaultdict(int)  # stake lost as a backer
        # `creditLoss`: credit burned as a backer (contract state in M2-M4, always 0 in M0)
        self.credit_loss: defaultdict[str, int] = defaultdict(int)

    # ── mechanism interface (overridden) ──

    def grant_line(self, account: str, amount: int) -> None:
        """Issue `amount` of unsecured credit (an owner override or an oracle score)."""
        raise NotImplementedError

    def borrow_limit(self, account: str) -> tuple[int, int]:
        """(limit, available) as `getBorrowLimit` returns them."""
        raise NotImplementedError

    def granted_credit(self, account: str) -> int:
        """Credit the account holds itself, before anything it commits to others."""
        raise NotImplementedError

    def backable(self, account: str) -> int:
        """The most the account can back (or vouch for) someone with right now."""
        raise NotImplementedError

    def back(self, backer: str, borrower: str, amount: int) -> None:
        """Set `backer`'s backing of `borrower` to `amount` (0 withdraws it)."""
        raise NotImplementedError

    def stake(self, account: str, amount: int) -> None:
        raise Revert("Unsupported")

    def unstake(self, account: str, amount: int) -> None:
        raise Revert("Unsupported")

    def free_stake(self, account: str) -> int:
        return 0

    def stake_balance(self, account: str) -> int:
        return 0

    @contextlib.contextmanager
    def batch(self) -> Iterator[None]:
        """Group several `back` calls; M0 recomputes PageRank once at the end."""
        yield

    def _on_borrow(self, loan: Loan) -> None:
        pass

    def _on_interest_paid(self, borrower: str, interest: int, fee: int, to_reserve: int) -> None:
        pass

    def _on_repaid(self, loan: Loan) -> None:
        pass

    def _charge_backers(self, borrower: str, loan: Loan, loss: int) -> int:
        """Charge a default's `loss` to the borrower's backers; returns the stake recovered."""
        return 0

    # ── wallets and time ──

    def mint(self, account: str, amount: int) -> None:
        """Bring external USDC into `account`'s wallet (recorded as capital the owner put in)."""
        self.wallet[account] += amount
        self.minted[account] += amount

    def advance(self, seconds: int) -> None:
        self.now += seconds

    def _pull(self, account: str, amount: int) -> None:
        if self.wallet[account] < amount:
            raise Revert("ERC20InsufficientBalance")
        self.wallet[account] -= amount

    # ── lending pool ──

    def total_assets(self) -> int:
        """What lenders' shares own. The contract subtracts max(totalImpaired, firstLossReserve);
        impairment is not modelled (no attacker exits after a due date), so that is the reserve."""
        return self.lender_cash + self.total_lent_out - self.first_loss_reserve

    def free_reserve(self, defaulter: str | None = None) -> int:
        """Reserve that may absorb `defaulter`'s default, or be released when `defaulter` is None."""
        return self.first_loss_reserve

    def release_reserve(self, amount: int) -> None:
        """`releaseReserve` (owner): hand part of the reserve's junior claim to lenders' shares."""
        if amount > self.free_reserve():
            raise Revert("ExceedsReserve")
        self.first_loss_reserve -= amount

    def fund_reserve(self, account: str, amount: int) -> None:
        """`fundReserve`: first-loss capital, lendable pool cash that is never returned to the payer."""
        if amount <= 0:
            raise Revert("ZeroAmount")
        self._pull(account, amount)
        self.lender_cash += amount
        self.first_loss_reserve += amount

    def convert_to_shares(self, assets: int, *, round_up: bool = False) -> int:
        return mul_div(
            assets, self.total_shares + VIRTUAL_SHARES, self.total_assets() + VIRTUAL_ASSETS, round_up=round_up
        )

    def convert_to_assets(self, shares: int) -> int:
        return mul_div(shares, self.total_assets() + VIRTUAL_ASSETS, self.total_shares + VIRTUAL_SHARES)

    def lender_balance(self, lender: str) -> int:
        return self.convert_to_assets(self.shares_of[lender])

    def deposit(self, lender: str, amount: int) -> None:
        if amount <= 0:
            raise Revert("ZeroAmount")
        self._pull(lender, amount)
        shares = self.convert_to_shares(amount)
        if shares == 0:
            raise Revert("ZeroShares")
        self.shares_of[lender] += shares
        self.total_shares += shares
        self.lender_cash += amount
        self.lender_principal[lender] += amount

    def withdraw(self, lender: str, amount: int | None = None) -> int:
        """Withdraw `amount` USDC, or the whole balance when `amount` is None. Returns the USDC paid."""
        if amount is None:
            shares = self.shares_of[lender]
            assets = self.convert_to_assets(shares)
        else:
            shares = self.convert_to_shares(amount, round_up=True)
            assets = amount
        if shares == 0 or shares > self.shares_of[lender]:
            raise Revert("InsufficientBalance")
        if self.lender_cash < assets:
            raise Revert("InsufficientLiquidity")
        self.lender_principal[lender] -= mul_div(self.lender_principal[lender], shares, self.shares_of[lender])
        self.shares_of[lender] -= shares
        self.total_shares -= shares
        self.lender_cash -= assets
        self.wallet[lender] += assets
        return assets

    # ── loans ──

    def borrow(self, borrower: str, amount: int, term: int = DEFAULT_LOAN_TERM) -> int:
        """`_originateLoan` followed by `_disburseLoan`. Returns the loan id."""
        if amount <= 0:
            raise Revert("ZeroAmount")
        if not MIN_LOAN_TERM <= term <= MAX_LOAN_TERM:
            raise Revert("InvalidTerm")
        if self.blocks_defaulters and self.defaulted_loans[borrower]:
            raise Revert("BorrowerInDefault")
        limit, available = self.borrow_limit(borrower)
        if limit == 0:
            raise Revert("NoCredit")
        if amount > available:
            raise Revert("BorrowLimitExceeded")
        assets = self.total_assets()
        if self.total_lent_out + amount > assets * LENDING_UTILIZATION_CAP_BPS // BASIS_POINTS:
            raise Revert("UtilisationCapExceeded")
        if self.lender_cash < amount + assets * LIQUIDITY_BUFFER_BPS // BASIS_POINTS:
            raise Revert("InsufficientLiquidity")

        loan = Loan(self._next_loan_id, borrower, amount, self.p.apr_bps, term, self.now)
        self._next_loan_id += 1
        self.loans[loan.id] = loan
        self.outstanding[borrower] += amount
        self.active_loan_count[borrower] += 1
        self._on_borrow(loan)

        self.lender_cash -= amount
        self.total_lent_out += amount
        self.wallet[borrower] += amount
        self.received[borrower] += amount
        return loan.id

    def interest_accrued(self, loan: Loan) -> int:
        """Simple interest on the original principal since disbursement; none in the first day."""
        elapsed = self.now - loan.disbursed_at
        if elapsed < GRACE_PERIOD:
            return 0
        return loan.principal * loan.rate_bps // BASIS_POINTS * elapsed // SECONDS_PER_YEAR

    def amount_owed(self, loan_id: int) -> int:
        """`getCurrentOutstandingAmount`."""
        loan = self.loans[loan_id]
        if loan.status is not Status.ACTIVE:
            raise Revert("LoanClosed")
        owed = loan.principal + self.interest_accrued(loan)
        return owed - loan.repaid if owed > loan.repaid else 0

    def repay(self, loan_id: int, amount: int | None = None) -> int:
        """`_repay`: settle interest first, then principal; close below one cent. Returns USDC paid."""
        loan = self.loans[loan_id]
        if loan.status is not Status.ACTIVE:
            raise Revert("LoanNotActive")
        owed = self.amount_owed(loan_id)
        paid = owed if amount is None else min(amount, owed)
        if paid > 0:
            self._pull(loan.borrower, paid)
            interest_due = self.interest_accrued(loan) - (loan.repaid - loan.principal_repaid)
            interest = min(paid, interest_due)
            principal = paid - interest
            fee = interest * self.p.protocol_fee_bps // BASIS_POINTS
            to_reserve = interest * self.p.reserve_bps // BASIS_POINTS

            loan.repaid += paid
            loan.principal_repaid += principal
            self.total_lent_out -= principal
            self.outstanding[loan.borrower] -= principal
            self.lender_cash += paid - fee  # the reserve share stays in the pool as its junior claim
            self.protocol_fees += fee
            self.first_loss_reserve += to_reserve
            self.interest_paid[loan.borrower] += interest
            self.principal_paid[loan.borrower] += principal
            self._on_interest_paid(loan.borrower, interest, fee, to_reserve)
        if owed - paid < CENT:
            unpaid = loan.principal - loan.principal_repaid
            self.total_lent_out -= unpaid
            self.outstanding[loan.borrower] -= unpaid
            self.active_loan_count[loan.borrower] -= 1
            self.completed_loans[loan.borrower] += 1
            loan.status = Status.REPAID
            self._on_repaid(loan)
        return paid

    def mark_defaulted(self, loan_id: int) -> int:
        """`markDefaulted`: write off unpaid principal; slashed stake returns to the pool, and the
        reserve absorbs what is left before lenders' shares do (no cash moves for that part).

        Returns what lenders' shares are spared: slashed stake plus the reserve's absorption.
        """
        loan = self.loans[loan_id]
        if loan.status is not Status.ACTIVE:
            raise Revert("LoanNotActive")
        if self.now <= loan.due_at + LATE_PERIOD:
            raise Revert("NotYetDefaultable")
        written_off = loan.principal - loan.principal_repaid
        self.total_lent_out -= written_off
        self.outstanding[loan.borrower] -= written_off
        loan.status = Status.DEFAULTED
        self.active_loan_count[loan.borrower] -= 1
        self.defaulted_loans[loan.borrower] += 1
        slashed = self._charge_backers(loan.borrower, loan, written_off)
        self.lender_cash += slashed
        from_reserve = min(written_off - slashed, self.free_reserve(loan.borrower))
        self.first_loss_reserve -= from_reserve
        return slashed + from_reserve


# ───────────────────────────── M2: conservation (f0538ae) ─────────────────────────────


@dataclass
class Backing:
    backer: str
    secured: int = 0  # from the backer's stake
    unsecured: int = 0  # from the backer's granted credit


class Conservation(Protocol):
    """M2, the conservation design (main at f0538ae): credit is granted or staked, and backing
    moves it. Today's contract is this plus M3r's earned credit.

    Mirrors `grantedCredit`, `getBorrowLimit`, `getFreeCredit`, `_backingReceived`, `_setBacking`,
    `stake`/`unstake` and `_chargeBackers`. Subclasses change only `_own_credit` (the part of
    granted credit before `creditLoss`).
    """

    key = "M2"
    name = "conservation"
    status = "f0538ae, no earned credit"
    supports_stake = True

    def __init__(self, params: Params = Params()):
        super().__init__(params)
        self.line: defaultdict[str, int] = defaultdict(int)
        self.stake_of: defaultdict[str, int] = defaultdict(int)
        self.stake_committed: defaultdict[str, int] = defaultdict(int)
        self.credit_committed: defaultdict[str, int] = defaultdict(int)
        self.backings: defaultdict[str, list[Backing]] = defaultdict(list)  # per borrower
        self._slot: dict[tuple[str, str], int] = {}  # (backer, borrower) -> index in backings

    def grant_line(self, account: str, amount: int) -> None:
        self.line[account] = amount

    def _own_credit(self, account: str) -> int:
        """Credit before charges: the issued line (score x maxLoanAmount)."""
        return self.line[account]

    def granted_credit(self, account: str) -> int:
        if self.defaulted_loans[account]:
            return 0
        granted = self._own_credit(account)
        lost = self.credit_loss[account]
        return granted - lost if granted > lost else 0

    def borrow_limit(self, account: str) -> tuple[int, int]:
        if self.defaulted_loans[account]:
            return 0, 0
        granted = self.granted_credit(account)
        committed = self.credit_committed[account]
        limit = max(0, granted - committed) + self._backing_received(account)
        owed = self.outstanding[account]
        return limit, max(0, limit - owed)

    def free_credit(self, account: str) -> tuple[int, int]:
        """`getFreeCredit`: (granted credit not committed or used by own loans, uncommitted stake)."""
        _, available = self.borrow_limit(account)
        granted = self.granted_credit(account)
        committed = self.credit_committed[account]
        credit = min(max(0, granted - committed), available)
        return credit, self.stake_of[account] - self.stake_committed[account]

    def backable(self, account: str) -> int:
        return sum(self.free_credit(account))

    def free_stake(self, account: str) -> int:
        return self.stake_of[account] - self.stake_committed[account]

    def stake_balance(self, account: str) -> int:
        return self.stake_of[account]

    def _backing_received(self, borrower: str) -> int:
        """Unsecured backing counts only as far as the backer's credit still covers it."""
        total = 0
        for edge in self.backings[borrower]:
            total += edge.secured
            if edge.unsecured == 0:
                continue
            committed = self.credit_committed[edge.backer]
            granted = self.granted_credit(edge.backer)
            owed = self.outstanding[edge.backer]
            cover = granted - owed if granted > owed else 0
            total += edge.unsecured if cover >= committed else mul_div(edge.unsecured, cover, committed)
        return total

    def back(self, backer: str, borrower: str, amount: int) -> None:
        """`_setBacking`: raise by committing free credit, then free stake; lower unsecured first."""
        if borrower == backer:
            raise Revert("SelfBacking")
        edges = self.backings[borrower]
        slot = self._slot.get((backer, borrower))
        if slot is None:
            if len(edges) >= MAX_BACKERS_PER_BORROWER:
                raise Revert("TooManyBackers")
            # The contract pushes the edge before checking credit and reverts the whole call on
            # failure; here the edge is added only once the change is known to succeed.
            edge = Backing(backer)
        else:
            edge = edges[slot]
        current = edge.secured + edge.unsecured

        if amount > current:
            extra = amount - current
            free_credit, free_stake = self.free_credit(backer)
            from_credit = min(extra, free_credit)
            if extra - from_credit > free_stake:
                raise Revert("InsufficientCredit")
            edge.unsecured += from_credit
            edge.secured += extra - from_credit
            self.credit_committed[backer] += from_credit
            self.stake_committed[backer] += extra - from_credit
        elif amount < current:
            cut = current - amount
            from_credit = min(cut, edge.unsecured)
            edge.unsecured -= from_credit
            edge.secured -= cut - from_credit
            self.credit_committed[backer] -= from_credit
            self.stake_committed[backer] -= cut - from_credit
            limit, _ = self.borrow_limit(borrower)
            if self.outstanding[borrower] > limit:
                # undo, as the revert would
                edge.unsecured += from_credit
                edge.secured += cut - from_credit
                self.credit_committed[backer] += from_credit
                self.stake_committed[backer] += cut - from_credit
                raise Revert("BackingInUse")

        if slot is None:
            self._slot[(backer, borrower)] = len(edges)
            edges.append(edge)

    def stake(self, account: str, amount: int) -> None:
        if amount <= 0:
            raise Revert("ZeroAmount")
        self._pull(account, amount)
        self.stake_of[account] += amount

    def unstake(self, account: str, amount: int) -> None:
        staked = self.stake_of[account]
        if not 0 < amount <= staked:
            raise Revert("InsufficientStake")
        if staked - amount < self.stake_committed[account]:
            raise Revert("StakeCommitted")
        self.stake_of[account] = staked - amount
        self.wallet[account] += amount

    def _charge_backers(self, borrower: str, loan: Loan, loss: int) -> int:
        """`_chargeBackers`: secured pro rata (stake slashed), then unsecured pro rata (credit burned)."""
        edges = self.backings[borrower]
        total_secured = sum(e.secured for e in edges)
        total_unsecured = sum(e.unsecured for e in edges)
        from_stake = min(loss, total_secured)
        from_credit = min(loss - from_stake, total_unsecured)
        release = self.active_loan_count[borrower] == 0
        recovered = 0
        for edge in edges:
            slashed = mul_div(from_stake, edge.secured, total_secured) if from_stake else 0
            charged = mul_div(from_credit, edge.unsecured, total_unsecured) if from_credit else 0
            if slashed:
                self.stake_of[edge.backer] -= slashed
                self.slashed[edge.backer] += slashed
                recovered += slashed
            if charged:
                self.credit_loss[edge.backer] += charged
            released_secured = edge.secured if release else slashed
            released_unsecured = edge.unsecured if release else charged
            self.stake_committed[edge.backer] -= released_secured
            self.credit_committed[edge.backer] -= released_unsecured
            edge.secured -= released_secured
            edge.unsecured -= released_unsecured
        return recovered


# ───────────────────────────── M1: reviewer's history rule ─────────────────────────────


class HermesHistory(Conservation):
    """M1: M2 plus "each fully repaid loan raises own capacity by 25% of its principal, up to 100"."""

    key = "M1"
    name = "hermes_history"
    status = "reviewer proposal"
    HISTORY_BPS = 2_500

    def __init__(self, params: Params = Params()):
        super().__init__(params)
        self.history_credit: defaultdict[str, int] = defaultdict(int)

    def _own_credit(self, account: str) -> int:
        return min(self.p.max_loan, self.line[account] + self.history_credit[account])

    def _on_repaid(self, loan: Loan) -> None:
        self.history_credit[loan.borrower] += loan.principal * self.HISTORY_BPS // BASIS_POINTS


# ───────────────────────────── M3: conservation with dues ─────────────────────────────


class ConservationDues(Conservation):
    """M3, superseded: M2 plus earned credit, the interest the account has paid net of the
    protocol fee (`duesPaid[borrower] += interest - fee`, as committed in c52610a). Farmable by
    attack A7: an attacker who is also a lender recaptures its share of that interest."""

    key = "M3"
    name = "conservation_dues"
    status = "superseded: interest net of fee, farmable by A7"

    def __init__(self, params: Params = Params()):
        super().__init__(params)
        self.dues_paid: defaultdict[str, int] = defaultdict(int)

    def _own_credit(self, account: str) -> int:
        return self.line[account] + self.dues_paid[account]

    def _on_interest_paid(self, borrower: str, interest: int, fee: int, to_reserve: int) -> None:
        self.dues_paid[borrower] += interest - fee


class ConservationReserveDues(ConservationDues):
    """M3r, the implemented rule (this branch, after a87d812): dues are only the share of
    interest paid into the first-loss reserve (`duesPaid[borrower] += toReserve`). No lender can
    withdraw that share, and it is the junior claim that absorbs the very default the credit it
    grants could cause. Residual case: see `attacks.reserve_drain`."""

    key = "M3r"
    name = "conservation_reserve_dues"
    status = "implemented: this branch, after a87d812"

    def _on_interest_paid(self, borrower: str, interest: int, fee: int, to_reserve: int) -> None:
        self.dues_paid[borrower] += to_reserve


class EarmarkedReserveDues(ConservationReserveDues):
    """M3e, a proposal (not in the contract): M3r, but the reserve behind dues in use is
    earmarked. A default may draw on the reserve, and the owner may release it, only beyond
    min(duesPaid, open principal) of every other account that has not defaulted, so a
    contributor's dues stay covered by its own contribution (closes the reserve-drain case)."""

    key = "M3e"
    name = "earmarked_reserve_dues"
    status = "proposal: earmark the reserve behind dues in use"

    def free_reserve(self, defaulter: str | None = None) -> int:
        earmarked = sum(
            min(dues, self.outstanding[account])
            for account, dues in self.dues_paid.items()
            if account != defaulter and not self.defaulted_loans[account]
        )
        return max(0, self.first_loss_reserve - earmarked)


# ───────────────────────────── M4: multi-hop credit network ─────────────────────────────

_SOURCE = ("source",)  # super-source; tuples cannot collide with account names
_SINK = ("sink",)


@dataclass
class Route:
    """One path a loan draws credit along: `path[0]` supplies it, `path[-1]` is the borrower."""

    path: tuple[str, ...]
    credit: int  # drawn from path[0]'s granted credit
    stake: int  # drawn from path[0]'s stake

    @property
    def flow(self) -> int:
        return self.credit + self.stake

    @property
    def edges(self) -> list[tuple[str, str]]:
        return list(zip(self.path, self.path[1:]))


class CreditNetwork(Protocol):
    """M4: a credit network in the sense of Karlan et al. (2009) and Dandekar et al. (2011).

    Every account is a credit source of capacity `granted + stake` (its own line, less credit
    burned, plus stake). A backing edge u -> v is a trust line of capacity c(u, v); declaring one
    costs nothing and commits nothing. A borrower's available credit is the max-flow from all
    sources to it, over any number of hops, in the residual network (capacity not used by open
    loans). A loan reserves one flow decomposition of its principal: each path's source and edges.
    Repaying releases the paths; a default destroys the unpaid share of each path: the source is
    charged (stake slashed to lenders first, then granted credit burned) and each edge on the path
    loses that capacity for good.
    """

    key = "M4"
    name = "credit_network_multihop"
    status = "not implemented"
    supports_stake = True

    def __init__(self, params: Params = Params()):
        super().__init__(params)
        self.line: defaultdict[str, int] = defaultdict(int)
        self.stake_of: defaultdict[str, int] = defaultdict(int)
        self.credit_used: defaultdict[str, int] = defaultdict(int)  # by open loans' routes
        self.stake_used: defaultdict[str, int] = defaultdict(int)
        self.capacity: dict[tuple[str, str], int] = {}  # declared trust lines
        self.edge_used: defaultdict[tuple[str, str], int] = defaultdict(int)
        self.routes: dict[int, list[Route]] = {}

    def grant_line(self, account: str, amount: int) -> None:
        self.line[account] = amount

    def granted_credit(self, account: str) -> int:
        if self.defaulted_loans[account]:
            return 0
        granted, lost = self.line[account], self.credit_loss[account]
        return granted - lost if granted > lost else 0

    def _free_source(self, account: str) -> tuple[int, int]:
        credit = max(0, self.granted_credit(account) - self.credit_used[account])
        return credit, self.stake_of[account] - self.stake_used[account]

    def backable(self, account: str) -> int:
        return sum(self._free_source(account))

    def free_stake(self, account: str) -> int:
        return self.stake_of[account] - self.stake_used[account]

    def stake_balance(self, account: str) -> int:
        return self.stake_of[account]

    def _residual_network(self) -> nx.DiGraph:
        graph = nx.DiGraph()
        accounts = set(self.line) | set(self.stake_of) | {a for edge in self.capacity for a in edge}
        for account in accounts:
            if self.defaulted_loans[account]:
                continue
            free = self.backable(account)
            if free > 0:
                graph.add_edge(_SOURCE, account, capacity=free)
        for (u, v), cap in self.capacity.items():
            residual = cap - self.edge_used[(u, v)]
            if residual > 0 and not self.defaulted_loans[u] and not self.defaulted_loans[v]:
                graph.add_edge(u, v, capacity=residual)
        return graph

    def borrow_limit(self, account: str) -> tuple[int, int]:
        if self.defaulted_loans[account]:
            return 0, 0
        graph = self._residual_network()
        available = 0
        if account in graph and _SOURCE in graph:
            available = nx.maximum_flow_value(graph, _SOURCE, account)
        return self.outstanding[account] + available, available

    def back(self, backer: str, borrower: str, amount: int) -> None:
        if borrower == backer:
            raise Revert("SelfBacking")
        if amount < self.edge_used[(backer, borrower)]:
            raise Revert("BackingInUse")
        self.capacity[(backer, borrower)] = amount

    def stake(self, account: str, amount: int) -> None:
        if amount <= 0:
            raise Revert("ZeroAmount")
        self._pull(account, amount)
        self.stake_of[account] += amount

    def unstake(self, account: str, amount: int) -> None:
        if not 0 < amount <= self.stake_of[account]:
            raise Revert("InsufficientStake")
        if amount > self.free_stake(account):
            raise Revert("StakeCommitted")
        self.stake_of[account] -= amount
        self.wallet[account] += amount

    def _on_borrow(self, loan: Loan) -> None:
        graph = self._residual_network()
        graph.add_edge(loan.borrower, _SINK, capacity=loan.principal)
        value, flow = nx.maximum_flow(graph, _SOURCE, _SINK)
        assert value == loan.principal, "borrow() checked the amount against the max-flow"
        routes = []
        for path, amount in _decompose_flow(flow, _SOURCE, _SINK):
            accounts = tuple(path[1:-1])
            free_credit, _ = self._free_source(accounts[0])
            credit = min(amount, free_credit)  # granted credit first, then stake
            route = Route(accounts, credit, amount - credit)
            self.credit_used[accounts[0]] += route.credit
            self.stake_used[accounts[0]] += route.stake
            for edge in route.edges:
                self.edge_used[edge] += route.flow
            routes.append(route)
        self.routes[loan.id] = routes

    def _release(self, route: Route) -> None:
        self.credit_used[route.path[0]] -= route.credit
        self.stake_used[route.path[0]] -= route.stake
        for edge in route.edges:
            self.edge_used[edge] -= route.flow

    def _on_repaid(self, loan: Loan) -> None:
        for route in self.routes.pop(loan.id):
            self._release(route)

    def _charge_backers(self, borrower: str, loan: Loan, loss: int) -> int:
        recovered = 0
        for route in self.routes.pop(loan.id):
            self._release(route)
            destroyed = mul_div(route.flow, loss, loan.principal)
            slashed = min(destroyed, route.stake)  # stake first, as in M2
            charged = destroyed - slashed
            source = route.path[0]
            if slashed:
                self.stake_of[source] -= slashed
                self.slashed[source] += slashed
                recovered += slashed
            if charged and source != borrower:
                self.credit_loss[source] += charged
            for edge in route.edges:
                self.capacity[edge] -= destroyed
        return recovered


def _decompose_flow(flow: dict, source, sink) -> list[tuple[list, int]]:
    """Split a feasible s-t flow into paths with their amounts, cancelling any cycles."""
    residual = {u: {v: f for v, f in out.items() if f > 0} for u, out in flow.items()}
    paths: list[tuple[list, int]] = []
    while residual.get(source):
        path, position = [source], {source: 0}
        while path[-1] != sink:
            nxt = next(iter(residual[path[-1]]))
            if nxt in position:  # a cycle: remove it and carry on from where it started
                cycle = path[position[nxt] :] + [nxt]
                _subtract(residual, cycle, min(residual[u][v] for u, v in zip(cycle, cycle[1:])))
                del path[position[nxt] + 1 :]
                position = {node: i for i, node in enumerate(path)}
                continue
            position[nxt] = len(path)
            path.append(nxt)
        amount = min(residual[u][v] for u, v in zip(path, path[1:]))
        _subtract(residual, path, amount)
        paths.append((path, amount))
    return paths


def _subtract(residual: dict, path: list, amount: int) -> None:
    for u, v in zip(path, path[1:]):
        residual[u][v] -= amount
        if residual[u][v] == 0:
            del residual[u][v]


# ───────────────────────────── M0: vouching + PageRank (21b838d) ─────────────────────────────

PR_SCALE = 100_000
PR_ALPHA = 85_000
PR_TOL = 100
PR_MAX_ITER = 100
PERSONALIZATION_CAP = 100 * USDC
KYC_BONUS = 100 * USDC
BASE_PERSONALIZATION = 0


class PageRankVouch(Protocol):
    """M0: free vouches, personalised PageRank, a relative score; limit = maxLoan x score.

    Integer port of `PageRank.sol` and the scoring in `DecentralizedMicrocredit.sol` at 21b838d:

    - an attestation adds an edge of weight 0..SCALE and recomputes PageRank on the whole graph,
      starting from the uniform vector each time (so the result depends only on the current graph
      and personalisation, and a batch of attestations equals its last recomputation);
    - personalisation weight = the score override if set (in SCALE units), else
      min(lender deposits, 100 USDC) + 100 USDC if KYC'd, all in micro-USDC; uniform when the
      graph's total weight is 0;
    - score = override, else SCALE * x / (x + 100) with x = 1000 * PR / max PR;
    - limit = maxLoan * score / SCALE across open loans.

    The old contract had no stake, no default state and no backer charges: an unpaid loan simply
    stays open. `mark_defaulted` is kept for accounting only (the loss falls on lenders) and does
    not bar the borrower. Pool accounting is today's share pool; the old pool paid deposits back
    at par, which only makes deposit-based attacks easier.
    """

    key = "M0"
    name = "pagerank_vouch"
    status = "21b838d"
    blocks_defaulters = False

    def __init__(self, params: Params = Params()):
        super().__init__(params)
        self.score_override: defaultdict[str, int] = defaultdict(int)
        self.kyc_verified: set[str] = set()
        self.nodes: list[str] = []  # insertion order, as `pagerankNodes`
        self._is_node: set[str] = set()
        self.out_edges: defaultdict[str, dict[str, int]] = defaultdict(dict)
        self.out_degree: defaultdict[str, int] = defaultdict(int)
        self.pagerank: defaultdict[str, int] = defaultdict(int)
        self.iterations = 0  # of the last computation
        self._deferred = False

    def grant_line(self, account: str, amount: int) -> None:
        self.score_override[account] = mul_div(amount, SCALE, self.p.max_loan)

    def backable(self, account: str) -> int:
        return self.p.max_loan  # a vouch costs nothing and commits nothing

    def back(self, backer: str, borrower: str, amount: int) -> None:
        """Vouch with full confidence (weight SCALE) for any positive amount; 0 withdraws."""
        self.attest(backer, borrower, SCALE if amount > 0 else 0)

    def attest(self, attester: str, borrower: str, weight: int) -> None:
        """`_recordAttestation`."""
        if weight > SCALE:
            raise Revert("WeightTooHigh")
        if borrower == attester:
            raise Revert("SelfAttestation")
        for node in (attester, borrower):
            if node not in self._is_node:
                self._is_node.add(node)
                self.nodes.append(node)
        old = self.out_edges[attester].get(borrower, 0)
        self.out_degree[attester] += weight - old
        self.out_edges[attester][borrower] = weight
        if not self._deferred:
            self.compute_pagerank()

    @contextlib.contextmanager
    def batch(self) -> Iterator[None]:
        self._deferred = True
        try:
            yield
        finally:
            self._deferred = False
            self.compute_pagerank()

    def personalization_weight(self, node: str) -> int:
        if self.score_override[node]:
            return self.score_override[node]
        weight = BASE_PERSONALIZATION + min(self.lender_principal[node], PERSONALIZATION_CAP)
        return weight + (KYC_BONUS if node in self.kyc_verified else 0)

    def compute_pagerank(self) -> int:
        """`_computePageRank`: power iteration in PR_SCALE fixed point. Returns iterations run."""
        n = len(self.nodes)
        if n == 0:
            return 0
        index = {node: i for i, node in enumerate(self.nodes)}
        scores = [PR_SCALE // n] * n

        # stochastic in-edges: incoming[i] = [(j, normalised weight of j -> i)]
        incoming: list[list[tuple[int, int]]] = [[] for _ in range(n)]
        for source, targets in self.out_edges.items():
            degree = self.out_degree[source]
            for target, weight in targets.items():
                if degree > 0 and weight > 0:
                    incoming[index[target]].append((index[source], weight * PR_SCALE // degree))
        dangling = [self.out_degree[node] == 0 for node in self.nodes]

        weights = [self.personalization_weight(node) for node in self.nodes]
        total = sum(weights)
        personal = [PR_SCALE // n if total == 0 else w * PR_SCALE // total for w in weights]

        iterations, converged = 0, False
        while iterations < PR_MAX_ITER and not converged:
            old = scores[:]
            dangling_sum = sum(s for s, d in zip(old, dangling) if d)
            delta = 0
            for i in range(n):
                received = sum(PR_ALPHA * old[j] * w // (PR_SCALE * PR_SCALE) for j, w in incoming[i])
                from_dangling = PR_ALPHA * dangling_sum * personal[i] // (PR_SCALE * PR_SCALE)
                teleport = (PR_SCALE - PR_ALPHA) * personal[i] // PR_SCALE
                scores[i] = received + from_dangling + teleport
                delta += abs(old[i] - scores[i])
            converged = delta < PR_TOL * n
            iterations += 1

        self.pagerank = defaultdict(int, zip(self.nodes, scores))
        self.iterations = iterations
        return iterations

    def mark_defaulted(self, loan_id: int) -> int:
        loan = self.loans[loan_id]
        recovered = super().mark_defaulted(loan_id)
        # The old contract has no default: the loan stays open and keeps using the borrower's limit.
        self.outstanding[loan.borrower] += loan.principal - loan.principal_repaid
        return recovered

    def credit_score(self, account: str) -> int:
        """`getCreditScore` at 21b838d."""
        if self.score_override[account]:
            return self.score_override[account]
        max_pr = max(self.pagerank.values(), default=0)
        if max_pr == 0:
            return 0
        x = self.pagerank[account] * 1000 // max_pr
        return SCALE * x // (x + 100)

    def borrow_limit(self, account: str) -> tuple[int, int]:
        limit = mul_div(self.p.max_loan, self.credit_score(account), SCALE)
        return limit, max(0, limit - self.outstanding[account])

    def granted_credit(self, account: str) -> int:
        return self.borrow_limit(account)[0]


MECHANISMS: tuple[type[Protocol], ...] = (
    PageRankVouch,
    HermesHistory,
    Conservation,
    ConservationDues,
    ConservationReserveDues,
    CreditNetwork,
)


def label(mechanism: type[Protocol], *, status: bool = False) -> str:
    text = f"{mechanism.key} {mechanism.name}"
    return f"{text} ({mechanism.status})" if status and mechanism.status else text
