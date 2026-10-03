"""Cross-checks of the state machines against the Forge tests, and properties of the attacks.

    python3 -m unittest discover analysis/sybil_sim

M2 tests replay scenarios from packages/foundry/test/SybilResistance.t.sol and
LoanLifecycle.t.sol with the same numbers; M0 tests replay PageRankVerification.t.sol at 21b838d.
"""

import unittest

import networkx as nx

import attacks as atk
from mechanisms import (
    DAY,
    LATE_PERIOD,
    MAX_BACKERS_PER_BORROWER,
    MECHANISMS,
    SCALE,
    USDC,
    Conservation,
    ConservationDues,
    ConservationReserveDues,
    CreditNetwork,
    EarmarkedReserveDues,
    HermesHistory,
    PageRankVouch,
    Params,
    Revert,
)

U = USDC


def pool(mechanism=Conservation, size=10_000 * U, params=Params()):
    m = mechanism(params)
    m.mint("poolLender", size)
    m.deposit("poolLender", size)
    return m


def stake(m, who, amount):
    m.mint(who, amount)
    m.stake(who, amount)


def default(m, loan_id):
    m.now = m.loans[loan_id].due_at + LATE_PERIOD + 1
    return m.mark_defaulted(loan_id)


class SybilResistanceCrossCheck(unittest.TestCase):
    """SybilResistance.t.sol: Avery holds 92, Brighton 25, in a 10,000 USDC pool."""

    def setUp(self):
        self.m = pool()
        self.m.grant_line("avery", 92 * U)
        self.m.grant_line("brighton", 25 * U)
        self.ring = [f"sybil{i}" for i in range(4)]

    def limit(self, account):
        return self.m.borrow_limit(account)[0]

    def test_ring_of_fresh_accounts_cannot_back_or_borrow(self):
        for i, member in enumerate(self.ring):
            for target in (self.ring[(i + 1) % 4], "sam"):
                with self.assertRaisesRegex(Revert, "InsufficientCredit"):
                    self.m.back(member, target, 10 * U)
        self.assertEqual(self.limit("sam"), 0)
        with self.assertRaisesRegex(Revert, "NoCredit"):
            self.m.borrow("sam", 1 * U)

    def test_staked_ring_borrows_no_more_than_its_stake_and_lenders_lose_nothing(self):
        for i, member in enumerate(self.ring):
            stake(self.m, member, 10 * U)
            self.m.back(member, self.ring[(i + 1) % 4], 5 * U)
            self.m.back(member, "sam", 5 * U)
        self.assertEqual(sum(self.limit(a) for a in self.ring + ["sam"]), 40 * U)
        assets = self.m.total_assets()
        default(self.m, self.m.borrow("sam", self.limit("sam")))
        self.assertEqual(self.m.total_assets(), assets)

    def test_ring_cannot_multiply_one_members_credit(self):
        self.m.grant_line(self.ring[0], 50 * U)
        self.m.back(self.ring[0], self.ring[1], 50 * U)
        with self.assertRaisesRegex(Revert, "InsufficientCredit"):
            self.m.back(self.ring[1], "sam", 1 * U)
        self.assertEqual(self.limit(self.ring[0]) + self.limit(self.ring[1]) + self.limit("sam"), 50 * U)
        default(self.m, self.m.borrow(self.ring[1], 50 * U))
        self.assertEqual(self.m.granted_credit(self.ring[0]), 0)
        with self.assertRaisesRegex(Revert, "InsufficientCredit"):
            self.m.back(self.ring[0], self.ring[2], 1 * U)

    def test_backing_moves_credit_it_does_not_copy_it(self):
        self.assertEqual(self.limit("brighton"), 25 * U)
        self.m.back("avery", "brighton", 50 * U)
        self.assertEqual(self.limit("brighton"), 75 * U)
        self.assertEqual(self.limit("avery"), 42 * U)
        with self.assertRaisesRegex(Revert, "InsufficientCredit"):
            self.m.back("avery", "carlos", 42 * U + 1)
        self.m.back("avery", "carlos", 42 * U)
        self.assertEqual(self.limit("avery"), 0)

    def test_own_loans_reduce_what_you_can_back(self):
        self.m.borrow("avery", 60 * U)
        free, _ = self.m.free_credit("avery")
        self.assertEqual(free, 32 * U)
        with self.assertRaisesRegex(Revert, "InsufficientCredit"):
            self.m.back("avery", "brighton", free + 1)

    def test_received_backing_cannot_be_passed_on(self):
        self.m.back("avery", "carlos", 40 * U)
        with self.assertRaisesRegex(Revert, "InsufficientCredit"):
            self.m.back("carlos", "sam", 1 * U)

    def test_backing_cannot_be_cut_below_what_the_borrower_owes(self):
        self.m.back("avery", "brighton", 50 * U)
        self.m.borrow("brighton", 70 * U)
        with self.assertRaisesRegex(Revert, "BackingInUse"):
            self.m.back("avery", "brighton", 44 * U)
        self.m.back("avery", "brighton", 45 * U)
        self.assertEqual(self.limit("brighton"), 70 * U)

    def test_committed_stake_cannot_be_withdrawn(self):
        stake(self.m, "carlos", 30 * U)
        self.m.back("carlos", "sam", 30 * U)
        edge = self.m.backings["sam"][0]
        self.assertEqual((edge.secured, edge.unsecured), (30 * U, 0))
        with self.assertRaisesRegex(Revert, "StakeCommitted"):
            self.m.unstake("carlos", 1)
        self.m.back("carlos", "sam", 0)
        self.m.unstake("carlos", 30 * U)
        self.assertEqual(self.m.wallet["carlos"], 30 * U)

    def test_lost_credit_stops_backing_others(self):
        self.m.back("avery", "brighton", 46 * U)
        self.m.back("avery", "carlos", 46 * U)
        self.assertEqual(self.limit("carlos"), 46 * U)
        self.m.grant_line("avery", 46 * U)  # Avery's granted credit falls to 46
        self.assertEqual(self.limit("carlos"), 23 * U)
        self.assertEqual(self.limit("brighton"), 25 * U + 23 * U)

    def test_defaulter_loses_the_credit_it_gave_others(self):
        self.m.back("avery", "carlos", 40 * U)
        default(self.m, self.m.borrow("avery", 92 * U - 40 * U))
        self.assertEqual(self.m.granted_credit("avery"), 0)
        self.assertEqual(self.limit("carlos"), 0)


class LoanLifecycleCrossCheck(unittest.TestCase):
    """LoanLifecycle.t.sol: a 1,000 USDC pool; Avery backs Brighton with 50 staked USDC."""

    POOL = 1_000 * U

    def setUp(self):
        self.m = pool(size=self.POOL)
        stake(self.m, "avery", 50 * U)
        self.m.back("avery", "brighton", 50 * U)

    def back_with_credit(self, backer, borrower, amount):
        self.m.grant_line(backer, amount)
        self.m.back(backer, borrower, amount)

    def test_interest_accrues_from_disbursement(self):
        loan_id = self.m.borrow("brighton", 40 * U)
        self.m.advance(365 * DAY)
        self.assertEqual(self.m.amount_owed(loan_id), 40 * U + 40 * U * 933 // 10_000)

    def test_no_interest_inside_the_grace_period(self):
        loan_id = self.m.borrow("brighton", 40 * U)
        self.m.advance(DAY - 1)
        self.assertEqual(self.m.amount_owed(loan_id), 40 * U)
        self.m.advance(1)  # from the first day on, interest counts from disbursement
        self.assertEqual(self.m.amount_owed(loan_id), 40 * U + 40 * U * 933 // 10_000 * DAY // (365 * DAY))

    def test_loan_cannot_default_before_late_period_ends(self):
        loan_id = self.m.borrow("brighton", 40 * U)
        self.m.now = self.m.loans[loan_id].due_at + LATE_PERIOD
        with self.assertRaisesRegex(Revert, "NotYetDefaultable"):
            self.m.mark_defaulted(loan_id)
        self.m.advance(1)
        self.m.mark_defaulted(loan_id)

    def test_default_slashes_secured_backing_into_the_pool(self):
        loan_id = self.m.borrow("brighton", 40 * U)
        self.m.advance(3 * 365 * DAY)
        self.m.mark_defaulted(loan_id)
        self.assertEqual(self.m.total_lent_out, 0)
        self.assertEqual(self.m.stake_of["avery"], 10 * U)
        self.assertEqual(self.m.total_assets(), self.POOL)
        self.assertAlmostEqual(self.m.lender_balance("poolLender"), self.POOL, delta=2)
        self.assertEqual(self.m.borrow_limit("brighton"), (0, 0))
        with self.assertRaisesRegex(Revert, "BorrowerInDefault"):
            self.m.borrow("brighton", 1 * U)
        self.assertEqual(self.m.stake_committed["avery"], 0)
        self.m.unstake("avery", 10 * U)

    def test_unsecured_backing_burns_the_backers_credit(self):
        self.back_with_credit("carol", "dana", 30 * U)
        default(self.m, self.m.borrow("dana", 30 * U))
        self.assertEqual(self.m.credit_loss["carol"], 30 * U)
        self.assertEqual(self.m.granted_credit("carol"), 0)
        self.assertEqual(self.m.credit_committed["carol"], 0)
        self.assertEqual(self.m.total_assets(), self.POOL - 30 * U)

    def test_stake_is_charged_before_credit(self):
        self.back_with_credit("carol", "brighton", 30 * U)
        default(self.m, self.m.borrow("brighton", 60 * U))
        self.assertEqual(self.m.stake_of["avery"], 0)
        self.assertEqual(self.m.credit_loss["carol"], 10 * U)
        self.assertEqual(self.m.total_assets(), self.POOL - 10 * U)

    def test_charges_are_paid_pro_rata(self):
        self.m.back("avery", "brighton", 30 * U)
        stake(self.m, "blake", 10 * U)
        self.m.back("blake", "brighton", 10 * U)
        default(self.m, self.m.borrow("brighton", 40 * U))
        self.assertEqual(self.m.stake_of["avery"], 50 * U - 30 * U)
        self.assertEqual(self.m.stake_of["blake"], 0)

    def test_partial_repayment_reduces_the_charge(self):
        loan_id = self.m.borrow("brighton", 40 * U)
        self.m.advance(2 * DAY)
        interest = self.m.amount_owed(loan_id) - 40 * U
        self.m.mint("brighton", interest)
        self.m.repay(loan_id, interest + 15 * U)
        default(self.m, loan_id)
        self.assertEqual(self.m.stake_of["avery"], 50 * U - 25 * U)

    def test_default_keeps_backing_for_the_borrowers_other_open_loans(self):
        first = self.m.borrow("brighton", 20 * U)
        self.m.advance(40 * DAY)
        second = self.m.borrow("brighton", 20 * U)
        default(self.m, first)
        self.assertEqual(self.m.stake_of["avery"], 30 * U)
        self.assertEqual(self.m.stake_committed["avery"], 30 * U)
        with self.assertRaisesRegex(Revert, "StakeCommitted"):
            self.m.unstake("avery", 1)
        default(self.m, second)
        self.assertEqual(self.m.stake_of["avery"], 10 * U)
        self.assertEqual(self.m.stake_committed["avery"], 0)

    def test_backers_per_borrower_are_bounded(self):
        for i in range(1, MAX_BACKERS_PER_BORROWER):
            stake(self.m, f"backer{i}", 1 * U)
            self.m.back(f"backer{i}", "brighton", 1 * U)
        stake(self.m, "one too many", 1 * U)
        with self.assertRaisesRegex(Revert, "TooManyBackers"):
            self.m.back("one too many", "brighton", 1 * U)


class SharePool(unittest.TestCase):
    """The pool with the first-loss reserve as a junior claim (this branch, after a87d812)."""

    INTEREST = 100 * U * 933 // 10_000  # 100 USDC for a year

    def repaid_year_loan(self, params=Params()):
        m = pool(size=1_000 * U, params=params)
        m.grant_line("b", 100 * U)
        loan_id = m.borrow("b", 100 * U, term=365 * DAY)
        m.advance(365 * DAY)
        m.mint("b", 10 * U)
        m.repay(loan_id)
        return m

    def test_repaid_interest_net_of_fee_and_reserve_raises_the_share_price(self):
        m = self.repaid_year_loan()  # fee 10%, reserve 30%
        fee, to_reserve = self.INTEREST // 10, self.INTEREST * 3 // 10
        self.assertEqual((m.protocol_fees, m.first_loss_reserve), (fee, to_reserve))
        self.assertEqual(m.lender_cash, 1_000 * U + self.INTEREST - fee)  # the reserve share stays in the pool
        self.assertAlmostEqual(m.lender_balance("poolLender"), 1_000 * U + self.INTEREST - fee - to_reserve, delta=2)

    def test_reserve_absorbs_uncovered_losses_before_lenders_without_moving_cash(self):
        m = self.repaid_year_loan(Params(reserve_bps=5_000))
        reserve, cash, assets = m.first_loss_reserve, m.lender_cash, m.total_assets()
        self.assertEqual(reserve, self.INTEREST // 2)
        default(m, m.borrow("b", 10 * U))
        self.assertEqual(m.first_loss_reserve, 0)
        self.assertEqual(m.lender_cash, cash - 10 * U)  # only the disbursement moved cash
        self.assertEqual(m.total_assets(), assets - 10 * U + reserve)

    def test_fund_reserve_adds_lendable_cash_but_not_lender_value(self):
        m = pool(size=1_000 * U)
        assets = m.total_assets()
        m.mint("issuer", 50 * U)
        m.fund_reserve("issuer", 50 * U)
        self.assertEqual((m.lender_cash, m.first_loss_reserve), (1_050 * U, 50 * U))
        self.assertEqual(m.total_assets(), assets)

    def test_release_hands_the_reserve_to_lenders(self):
        m = self.repaid_year_loan()
        reserve, assets = m.first_loss_reserve, m.total_assets()
        m.release_reserve(reserve)
        self.assertEqual(m.total_assets(), assets + reserve)
        with self.assertRaisesRegex(Revert, "ExceedsReserve"):
            m.release_reserve(1)


class HistoryAndDues(unittest.TestCase):
    def test_m1_repayment_adds_a_quarter_of_principal_up_to_the_ceiling(self):
        m = pool(HermesHistory)
        m.grant_line("b", 50 * U)
        for expected in (62.5, 78.125, 97.65625, 100, 100):  # each loan draws the whole limit
            _, available = m.borrow_limit("b")
            loan_id = m.borrow("b", available)
            m.advance(23 * 3_600)
            m.repay(loan_id)
            self.assertEqual(m.granted_credit("b"), round(expected * U))

    def test_m1_four_free_cycles_give_a_fresh_account_the_ceiling(self):
        """CREDIT_MODEL.md, Theorem 3: stake 100, four grace-period cycles, 100 of own credit."""
        outcome = atk.wash_farm(HermesHistory, 1, seed="stake", timing="grace", cycles=4)
        self.assertEqual(outcome.net_profit, 100.0)
        self.assertEqual(outcome.interest_paid, 0.0)

    def test_m3_dues_are_interest_net_of_fee(self):
        m = pool(ConservationDues)
        m.grant_line("b", 50 * U)
        loan_id = m.borrow("b", 50 * U)
        m.advance(30 * DAY)
        m.mint("b", 1 * U)
        m.repay(loan_id)
        interest = 50 * U * 933 // 10_000 * 30 * DAY // (365 * DAY)
        self.assertEqual(m.dues_paid["b"], interest - interest // 10)
        self.assertEqual(m.granted_credit("b"), 50 * U + interest - interest // 10)

    def test_m3_grace_repayments_earn_nothing(self):
        m = pool(ConservationDues)
        m.grant_line("b", 50 * U)
        loan_id = m.borrow("b", 50 * U)
        m.advance(23 * 3_600)
        m.repay(loan_id)
        self.assertEqual(m.granted_credit("b"), 50 * U)

    def test_m3_extra_credit_never_exceeds_interest_paid(self):
        for outcome in (
            atk.wash_farm(ConservationDues, 16, seed="stake", timing="30d", cycles=4),
            atk.exit_scam(ConservationDues, 16),
        ):
            baseline = 75.0 if outcome.attack.startswith("A6") else 0.0
            self.assertLessEqual(outcome.extracted - baseline, outcome.interest_paid)

    def test_m3r_dues_are_the_reserve_share_of_interest(self):
        """`duesPaid[borrower] += toReserve` (this branch, after a87d812)."""
        m = pool(ConservationReserveDues)
        m.grant_line("b", 50 * U)
        loan_id = m.borrow("b", 50 * U)
        m.advance(30 * DAY)
        m.mint("b", 1 * U)
        m.repay(loan_id)
        interest = 50 * U * 933 // 10_000 * 30 * DAY // (365 * DAY)
        self.assertEqual(m.dues_paid["b"], interest * 3_000 // 10_000)
        self.assertEqual(m.dues_paid["b"], m.first_loss_reserve)

    def test_h2_own_credit_after_a_year(self):
        final = {
            (m.key, start): atk.honest_history(m, start)[-1]["own_credit"]
            for m in (HermesHistory, ConservationDues, ConservationReserveDues)
            for start in ("line", "backed")
        }
        monthly = 383_424  # interest on 50 for 30 days
        dues = 12 * (monthly - monthly // 10) / U  # M3: less the 10% fee
        reserve_dues = 12 * (monthly * 3 // 10) / U  # M3r: the 30% reserve share
        self.assertEqual(final[("M1", "line")], 100.0)
        self.assertEqual(final[("M1", "backed")], 100.0)
        self.assertAlmostEqual(final[("M3", "line")], 50 + dues, places=6)
        self.assertAlmostEqual(final[("M3", "backed")], dues, places=6)
        self.assertAlmostEqual(final[("M3r", "line")], 50 + reserve_dues, places=6)
        self.assertAlmostEqual(final[("M3r", "backed")], reserve_dues, places=6)


class CreditNetworkModel(unittest.TestCase):
    def setUp(self):
        self.m = pool(CreditNetwork)
        self.m.grant_line("avery", 92 * U)
        self.m.grant_line("brighton", 25 * U)

    def test_one_hop_matches_m2_before_anyone_draws(self):
        self.m.back("avery", "brighton", 50 * U)
        self.assertEqual(self.m.borrow_limit("brighton")[1], 75 * U)
        self.assertEqual(self.m.borrow_limit("avery")[1], 92 * U)  # a trust line commits nothing
        self.m.borrow("brighton", 75 * U)
        self.assertEqual(self.m.borrow_limit("avery")[1], 42 * U)

    def test_credit_flows_over_several_hops_and_a_default_burns_the_source(self):
        self.m.back("avery", "brighton", 50 * U)
        self.m.back("brighton", "carlos", 60 * U)
        self.assertEqual(self.m.borrow_limit("carlos")[1], 60 * U)  # 25 of Brighton's + 35 of Avery's
        default(self.m, self.m.borrow("carlos", 60 * U))
        self.assertEqual(self.m.credit_loss["brighton"] + self.m.credit_loss["avery"], 60 * U)
        self.assertEqual(self.m.capacity[("brighton", "carlos")], 0)

    def test_fresh_accounts_have_no_flow_however_they_are_connected(self):
        for u, v in [("a", "b"), ("b", "c"), ("c", "a"), ("a", "sam"), ("b", "sam"), ("c", "sam")]:
            self.m.back(u, v, 1_000 * U)
        self.assertEqual(self.m.borrow_limit("sam"), (0, 0))


class PageRankPort(unittest.TestCase):
    """PageRankVerification.t.sol at 21b838d: NetworkX baselines, tolerance 100 / 100,000."""

    def test_simple_graph_matches_networkx(self):
        m = PageRankVouch()
        m.attest("n1", "n2", 800_000)
        m.attest("n1", "n3", 400_000)
        for node, expected in (("n1", 25974), ("n2", 40692), ("n3", 33333)):
            self.assertAlmostEqual(m.pagerank[node], expected, delta=100)
        self.assertEqual(m.credit_score("n2"), SCALE * 1000 // 1100)

    def test_cycle_is_uniform(self):
        m = PageRankVouch()
        nodes = ["1", "2", "3", "4", "5"]
        for (u, v), w in zip(zip(nodes, nodes[1:] + nodes[:1]), (500_000, 300_000, 700_000, 400_000, 600_000)):
            m.attest(u, v, w)
        for node in nodes:
            self.assertAlmostEqual(m.pagerank[node], 20_000, delta=100)

    def test_reattesting_equals_building_fresh(self):
        a, b = PageRankVouch(), PageRankVouch()
        a.attest("1", "2", 800_000)
        a.attest("1", "3", 300_000)
        a.attest("1", "2", 300_000)
        b.attest("1", "2", 300_000)
        b.attest("1", "3", 300_000)
        self.assertEqual(dict(a.pagerank), dict(b.pagerank))

    def test_uniform_fallback_lets_two_unrooted_vouchers_lift_a_stranger_to_the_top(self):
        m = PageRankVouch()
        m.attest("v1", "stranger", SCALE)
        m.attest("v2", "stranger", SCALE)
        self.assertEqual(m.borrow_limit("stranger")[0], 90_909_000)

    def test_deposit_outweighs_an_admin_override_hundredfold(self):
        """Overrides enter the personalisation in SCALE units, deposits in micro-USDC."""
        m = PageRankVouch()
        m.grant_line("admin", 100 * U)
        m.mint("depositor", 100 * U)
        m.deposit("depositor", 100 * U)
        self.assertEqual(m.personalization_weight("depositor"), 100 * m.personalization_weight("admin"))

    def test_early_stopping_pays_an_unrooted_ring_that_exact_pagerank_does_not(self):
        world = atk.build_world(PageRankVouch, "demo")
        m, ring = world.protocol, atk.sybils("ring", 16)
        with m.batch():
            for i, member in enumerate(ring):
                m.back(member, ring[(i + 1) % 16], 1)
        graph = nx.DiGraph()
        graph.add_nodes_from(m.nodes)
        graph.add_weighted_edges_from((u, v, w) for u, out in m.out_edges.items() for v, w in out.items() if w)
        exact = nx.pagerank(
            graph, personalization={n: m.personalization_weight(n) for n in m.nodes}, tol=1e-12, max_iter=10_000
        )
        self.assertLess(max(exact[r] for r in ring), 1e-9)  # no inflow, no teleport: zero in the limit
        self.assertGreater(m.borrow_limit(ring[0])[0], 4 * U)  # the integer port stops while mass remains


class AttackProperties(unittest.TestCase):
    ALL = [
        atk.ring,
        atk.stranger_lift,
        atk.deposit_roots,
        atk.wash_farm,
        atk.collusive_backer,
        atk.exit_scam,
        atk.self_lending,
        atk.reserve_drain,
    ]

    def test_every_run_balances(self):
        """Attacker gain = honest lenders' loss + honest backers' loss - fees - reserve."""
        for attack in self.ALL:
            for mechanism in MECHANISMS:
                outcome = attack(mechanism, 4)
                if outcome is None:
                    continue
                with self.subTest(attack=attack.__name__, mechanism=mechanism.key):
                    self.assertLessEqual(abs(outcome.accounting_residual), 1e-5)
                    breakdown = outcome.extracted - outcome.interest_paid - outcome.stake_lost + outcome.lender_pnl
                    self.assertAlmostEqual(outcome.net_profit, breakdown, places=5)

    def test_conservation_profit_does_not_grow_with_accounts(self):
        """M2 and M4: no attack's profit rises with n (A1 to A6, both A4 seeds)."""
        for mechanism in (Conservation, CreditNetwork):
            for attack, kwargs in [
                (atk.ring, {}),
                (atk.stranger_lift, {}),
                (atk.deposit_roots, {}),
                (atk.wash_farm, {"seed": "stake"}),
                (atk.wash_farm, {"seed": "line", "cycles": 4}),
                (atk.collusive_backer, {}),
                (atk.exit_scam, {"timing": "grace"}),
            ]:
                with self.subTest(mechanism=mechanism.key, attack=attack.__name__, **kwargs):
                    small, large = attack(mechanism, 1, **kwargs), attack(mechanism, 64, **kwargs)
                    self.assertLessEqual(large.net_profit, small.net_profit + 1e-6)
                    self.assertLessEqual(large.net_profit, 100.0)

    def test_m1_wash_farm_is_linear_and_free(self):
        for n in atk.ATTACK_SIZES:
            outcome = atk.wash_farm(HermesHistory, n, seed="stake", timing="grace")
            self.assertEqual(outcome.net_profit, 25.0 * n)
            self.assertEqual(outcome.honest_lender_loss, 25.0 * n)

    def test_m3_self_lending_matches_the_closed_form(self):
        """M3 (superseded): profit per account = interest x (share x (1 - fee - reserve) - fee)."""
        for fee_bps, reserve_bps, share_bps in [(1_000, 0, 5_000), (0, 0, 2_500), (1_000, 5_000, 9_000)]:
            params = Params(protocol_fee_bps=fee_bps, reserve_bps=reserve_bps)
            outcome = atk.self_lending(ConservationDues, 8, lender_share_bps=share_bps, params=params)
            interest = 100 * 933 / 10_000
            s, f, r = share_bps / 10_000, fee_bps / 10_000, reserve_bps / 10_000
            self.assertAlmostEqual(outcome.net_profit / 8, interest * (s * (1 - f - r) - f), delta=1e-4)
            expected = atk.self_lending_theory(ConservationDues, params, share_bps)
            self.assertAlmostEqual(outcome.net_profit / 8, expected, delta=1e-4)

    def test_reserve_dues_never_profit_whatever_the_lender_share(self):
        """M3r (implemented): dues only from the reserve share of interest; A7 as specified."""
        for fee_bps, reserve_bps in [(0, 2_000), (1_000, 5_000), (0, 5_000)]:
            params = Params(protocol_fee_bps=fee_bps, reserve_bps=reserve_bps)
            for share_bps in (0, 5_000, 9_000, 9_900):
                with self.subTest(fee=fee_bps, reserve=reserve_bps, share=share_bps):
                    outcome = atk.self_lending(ConservationReserveDues, 4, lender_share_bps=share_bps, params=params)
                    self.assertLessEqual(outcome.net_profit, 0)
                    self.assertLessEqual(outcome.honest_lender_loss, 1e-5)

    def test_m3_without_a_lender_share_never_profits_from_dues(self):
        outcome = atk.self_lending(ConservationDues, 8, lender_share_bps=0)
        self.assertLess(outcome.net_profit, 0)

    def test_h1_backing(self):
        rows = {row["mechanism"].split()[0]: row for row in map(atk.honest_backing, MECHANISMS)}
        self.assertEqual((rows["M2"]["brighton_limit"], rows["M2"]["avery_limit"]), (75.0, 42.0))
        self.assertEqual(rows["M4"]["avery_limit_after_brighton_borrows_50"], 42.0)
        self.assertEqual(rows["M0"]["avery_limit"], 92.0)

    def test_m0_attacks_are_world_dependent(self):
        self.assertEqual(atk.ring(PageRankVouch, 8).net_profit, 0.0)
        self.assertGreater(atk.ring(PageRankVouch, 8, world="unrooted").net_profit, 600)
        pure = [atk.deposit_roots(PageRankVouch, n, beneficiary=False).net_profit for n in (2, 64)]
        self.assertAlmostEqual(pure[1] / pure[0], 32, places=6)  # exactly linear: 90.909 per account


class ReserveDrain(unittest.TestCase):
    """M3r residual case: the farm's reserve contribution reaches lenders before its dues default."""

    def gain(self, share_bps, drain, via="defaults", params=Params(), initial_reserve=0, mechanism=None):
        """The attack, its counterfactual (same lender, no farm), and the farm's gain."""

        def run(farm):
            return atk.reserve_drain(
                mechanism or ConservationReserveDues,
                4,
                share_bps,
                drain,
                via,
                initial_reserve,
                farm=farm,
                params=params,
            )

        attack, baseline = run(True), run(False)
        return attack, baseline, attack.net_profit - baseline.net_profit

    def test_both_routes_match_the_closed_form(self):
        for via in ("defaults", "release"):
            for params in (Params(), Params(protocol_fee_bps=0), Params(protocol_fee_bps=0, reserve_bps=8_000)):
                for share_bps, drain, r0 in [(5_000, 0.5, 0), (7_500, 1.0, 0), (9_000, 2.0, 30 * U), (9_500, 1.0, 0)]:
                    with self.subTest(via=via, params=params, share=share_bps, drain=drain, r0=r0):
                        attack, baseline, gain = self.gain(share_bps, drain, via, params, r0)
                        profit, honest_loss = atk.reserve_drain_theory(4, share_bps, drain, r0, params)
                        self.assertAlmostEqual(gain, profit, delta=1e-5)
                        self.assertAlmostEqual(
                            attack.honest_lender_loss - baseline.honest_lender_loss, honest_loss, delta=1e-5
                        )

    def test_gain_needs_both_a_drained_reserve_and_a_share_above_breakeven(self):
        deployed = Params(protocol_fee_bps=0)  # s* = (1 - 0.3) / (1 - 0) = 70%
        self.assertLess(self.gain(9_500, 0.0, params=deployed)[2], 0)
        self.assertAlmostEqual(self.gain(7_000, 1.0, params=deployed)[2], 0, delta=1e-5)
        self.assertLess(self.gain(6_500, 1.0, params=deployed)[2], 0)
        self.assertGreater(self.gain(7_500, 1.0, params=deployed)[2], 0)

    def test_via_defaults_the_attacker_still_loses_in_absolute_terms(self):
        """The farm only shifts a loss the attacker would take as a lender onto honest lenders."""
        for share_bps in (7_500, 9_000, 9_500):
            attack, _, gain = self.gain(share_bps, 1.0, params=Params(protocol_fee_bps=0))
            self.assertGreater(gain, 0)
            self.assertLess(attack.net_profit, 0)

    def test_via_release_the_gain_is_absolute(self):
        attack, baseline, gain = self.gain(9_000, 1.0, via="release", params=Params(protocol_fee_bps=0))
        self.assertEqual(baseline.net_profit, 0)
        self.assertAlmostEqual(attack.net_profit, 4 * 9.33 * (0.3 - 1 + 0.9), delta=1e-5)

    def test_earmarking_the_reserve_behind_dues_closes_the_case(self):
        """M3e: neither other defaults nor a release can reach the farm's contribution."""
        for via in ("defaults", "release"):
            for params in (Params(protocol_fee_bps=0), Params(protocol_fee_bps=0, reserve_bps=8_000)):
                for share_bps in (7_500, 9_500):
                    with self.subTest(via=via, reserve=params.reserve_bps, share=share_bps):
                        attack, baseline, gain = self.gain(share_bps, 2.0, via, params, mechanism=EarmarkedReserveDues)
                        self.assertLess(gain, 0)
                        self.assertLess(attack.honest_lender_loss - baseline.honest_lender_loss, 0)


if __name__ == "__main__":
    unittest.main()
