"""Tests of the reference issuer policy, one class per property.

    cd analysis/issuer_policy && python3 -m unittest -v test_policy
"""

from __future__ import annotations

import inspect
import math
import re
import unittest
from dataclasses import fields, replace

import numpy as np

import allocate as alloc
import model
import policy as pol
import simulate as sim
from model import DAY, SCALE, USDC, Loan, LoanStatus, Pool, Revert, ScoreProvider, usdc

NOW = 1_800_000_000
P = pol.PolicyParams()


def addr(i: int, kind: int = 0x11) -> str:
    return f"0x{kind:02x}{i:038x}"


def closed_loan(
    principal: float = 20.0,
    held_days: float = 30.0,
    term_days: float = 30.0,
    age_days: float = 0.0,
    secured: float = 0.0,
    now: int = NOW,
) -> Loan:
    """A repaid loan of the account itself, closed `age_days` before `now`."""
    closed = now - int(age_days * DAY)
    disbursed = closed - int(held_days * DAY)
    p = usdc(principal)
    interest = 0 if held_days < 1 else max(1, p * 1233 // 10_000 * int(held_days * DAY) // (365 * DAY))
    return Loan(
        loan_id=0,
        borrower=addr(0),
        principal=p,
        term=int(term_days * DAY),
        disbursed_at=disbursed,
        interest_rate_bps=1233,
        status=LoanStatus.REPAID,
        repaid=p + interest,
        principal_repaid=p,
        closed_at=closed,
        secured=usdc(secured),
    )


def view(loans=(), tier="standard", kyc=True, ok=True, defaulted=False, address=None) -> pol.AccountView:
    return pol.AccountView(address or addr(0), kyc, tier, ok, defaulted, tuple(loans))


def world(budget_lines: float = 100, increase_lines: float = 100):
    provider = ScoreProvider(int(budget_lines * SCALE), int(increase_lines * SCALE))
    return provider, Pool(provider), pol.IdentityRegistry()


def verify(pool: Pool, reg: pol.IdentityRegistry, a: str, tier: str = "standard", ident: str | None = None) -> None:
    pool.mark_kyc_verified(a)
    reg.bind(ident or a, tier, a)


def publish(provider: ScoreProvider, plan: pol.Plan) -> None:
    for report in plan.reports:
        provider.apply_report(*report)


def plan_for(pool, reg, provider, addrs, now=NOW, params=P) -> pol.Plan:
    return pol.plan_report([pol.read_account(pool, reg, a) for a in addrs], provider.copy(), params, now)


# ───────────────────────────── the contract port ─────────────────────────────


class ProviderPort(unittest.TestCase):
    """The port reproduces OracleScoreProvider.t.sol's budget scenarios."""

    def setUp(self):
        self.alice, self.bob, self.carol = addr(1), addr(2), addr(3)

    def test_reports_cannot_issue_beyond_the_budget(self):
        provider = ScoreProvider(2_000_000)
        users = [self.alice, self.bob, self.carol]
        with self.assertRaises(Revert) as ctx:
            provider.apply_report(1, users, [1_000_000, 1_000_000, 1])
        self.assertEqual(ctx.exception.error, "IssuanceBudgetExceeded")
        provider.apply_report(1, users, [1_000_000, 1_000_000, 0])
        self.assertEqual(provider.total_held, 2_000_000)

    def test_budget_stays_held_while_a_line_may_be_in_use(self):
        provider = ScoreProvider(1_000_000, 1_000_000)
        usage = {self.alice: (1, 0)}
        use = lambda u: usage.get(u, (0, 0))  # noqa: E731
        provider.apply_report(1, [self.alice], [1_000_000])
        provider.apply_report(2, [self.alice], [0])
        self.assertEqual(provider.score(self.alice), 0)
        self.assertEqual(provider.total_held, 1_000_000)
        with self.assertRaises(Revert):
            provider.apply_report(3, [self.alice, self.bob], [0, 1_000_000])
        provider.release_budget([self.alice], use)
        self.assertEqual(provider.total_held, 1_000_000)
        usage[self.alice] = (0, 5)  # repaid, but backing someone
        provider.release_budget([self.alice], use)
        self.assertEqual(provider.total_held, 1_000_000)
        usage[self.alice] = (0, 0)
        provider.release_budget([self.alice], use)
        self.assertEqual(provider.total_held, 0)
        provider.apply_report(3, [self.alice, self.bob], [0, 1_000_000])
        self.assertEqual(provider.total_held, 1_000_000)

    def test_one_report_can_raise_scores_only_so_far(self):
        provider = ScoreProvider(2_000_000, 500_000)
        with self.assertRaises(Revert):
            provider.apply_report(1, [self.alice], [500_001])
        provider.apply_report(1, [self.alice], [500_000])
        provider.apply_report(2, [self.bob], [500_000])
        with self.assertRaises(Revert):
            provider.apply_report(3, [self.alice, self.bob, self.carol], [0, 1_000_000, 100_000])
        provider.apply_report(3, [self.alice, self.bob, self.carol], [0, 1_000_000, 0])
        self.assertEqual(provider.total_score, 1_000_000)

    def test_lowering_the_budget_still_accepts_reductions(self):
        provider = ScoreProvider(2_000_000)
        provider.apply_report(1, [self.alice], [1_000_000])
        provider.set_issuance_limits(500_000, 500_000)
        provider.apply_report(2, [self.alice], [400_000])
        with self.assertRaises(Revert):
            provider.apply_report(3, [self.bob], [1])
        provider.release_budget([self.alice], lambda u: (0, 0))
        self.assertEqual(provider.total_held, 400_000)
        provider.apply_report(3, [self.bob], [100_000])
        self.assertEqual(provider.total_held, 500_000)

    def test_epochs_and_report_validation(self):
        provider = ScoreProvider(10 * SCALE)
        for epoch, users, scores, error in [
            (0, [self.alice], [1], "StaleEpoch"),
            (1, [self.alice, self.bob], [1], "LengthMismatch"),
            (1, [self.alice] * 501, [0] * 501, "BatchTooLarge"),
            (1, [self.alice], [SCALE + 1], "ScoreTooHigh"),
        ]:
            with self.assertRaises(Revert) as ctx:
                provider.apply_report(epoch, users, scores)
            self.assertEqual(ctx.exception.error, error)
        provider.apply_report(5, [self.alice], [1])
        for epoch in (5, 4):
            with self.assertRaises(Revert):
                provider.apply_report(epoch, [self.alice], [2])


# ───────────────────────────── property 1: Theorem 3 ─────────────────────────────


class TheoremThreeCompliance(unittest.TestCase):
    """Without a costly identity the line is 0, whatever the history."""

    perfect = [closed_loan(100, 30, age_days=30 * i) for i in range(48)]

    def test_unverified_account_gets_zero_whatever_its_history(self):
        t = pol.target(view(self.perfect, kyc=False), NOW, P)
        self.assertEqual((t.score, t.reason), (0, "unverified"))
        self.assertGreater(pol.target(view(self.perfect), NOW, P).score, 0)

    def test_verified_flag_without_a_tier_gets_zero(self):
        self.assertEqual(pol.target(view(self.perfect, tier=None), NOW, P).reason, "no_tier")
        self.assertEqual(pol.target(view(self.perfect, tier="platinum"), NOW, P).reason, "no_tier")
        # and a registry tier without the pool's isKYCVerified flag
        provider, pool, reg = world()
        reg.bind("x", "enhanced", addr(9))
        self.assertEqual(pol.target(pol.read_account(pool, reg, addr(9)), NOW, P).score, 0)

    def _seed_farm(self, pool, n, grace: bool, start=NOW - 60 * DAY):
        """Theorem 3's construction: one stake, recycled through fresh accounts."""
        seed = addr(0, 0x5E)
        pool.stake(seed, usdc(100))
        farm = [addr(i, 0xF0) for i in range(n)]
        t = start
        for a in farm:
            pool.back(seed, a, usdc(100))
            for _ in range(4):
                loan = pool.borrow(a, usdc(100), t)
                pool.repay(loan, t + (23 * 3_600 if grace else 30 * DAY))
                t += DAY if grace else 31 * DAY
            pool.back(seed, a, 0)
        pool.unstake(seed, usdc(100))  # the seed is never at risk
        return farm

    def test_recycled_seed_farm_earns_zero_lines(self):
        for grace in (True, False):
            provider, pool, reg = world()
            farm = self._seed_farm(pool, 16, grace)
            self.assertTrue(all(pool.account(a).completed_loans == 4 for a in farm))
            plan = plan_for(pool, reg, provider, farm, now=NOW + 200 * DAY)
            self.assertEqual(plan.reports, [])
            self.assertTrue(all(s == 0 for s in plan.new_scores.values()))
            if not grace:  # history earned dues on-chain, which the contract adds, and nothing more
                self.assertTrue(all(pool.granted(a) == pool.account(a).dues_paid > 0 for a in farm))

    def test_grace_period_farm_earns_zero_even_on_a_bought_identity(self):
        provider, pool, reg = world()
        farm = self._seed_farm(pool, 4, grace=True)
        for a in farm:
            verify(pool, reg, a, "basic")
        fresh = addr(7)
        verify(pool, reg, fresh, "basic")
        plan = plan_for(pool, reg, provider, farm + [fresh], now=NOW + 200 * DAY)
        for a in farm:
            self.assertEqual(pol.evidence(pol.read_account(pool, reg, a), NOW, P), (0.0, 0.0))
            self.assertEqual(plan.targets[a].score, plan.targets[fresh].score)

    def test_one_address_per_identity_and_a_default_ends_the_identity(self):
        provider, pool, reg = world()
        first, second = addr(1), addr(2)
        verify(pool, reg, first, "standard", "person")
        verify(pool, reg, second, "standard", "person")
        plan = plan_for(pool, reg, provider, [first, second])
        self.assertGreater(plan.targets[first].score, 0)
        self.assertEqual(plan.targets[second].reason, "identity_ended")
        pool.account(second).defaulted_loans = 1
        self.assertEqual(plan_for(pool, reg, provider, [first]).targets[first].reason, "identity_ended")


# ───────────────────────────── property 2: identity-cost bound ─────────────────────────────


class IdentityCostBound(unittest.TestCase):
    def test_default_tiers_are_incentive_compatible(self):
        for tier in P.tiers.values():
            self.assertTrue(pol.incentive_compatible(tier, P), tier.name)
        loose = pol.PolicyParams(tiers=pol.default_tiers(cap_multiple=4.0))
        self.assertFalse(pol.incentive_compatible(loose.tiers["basic"], loose))
        # enhanced: 4 x 120 is clipped to one full line (100), still below k = 120
        self.assertTrue(pol.incentive_compatible(loose.tiers["enhanced"], loose))

    def test_line_never_exceeds_the_tier_cap(self):
        rng = np.random.default_rng(7)
        loose = pol.PolicyParams(tiers=pol.default_tiers(cap_multiple=4.0))
        for params in (P, loose):
            for _ in range(300):
                tier = str(rng.choice(list(params.tiers)))
                loans = [
                    closed_loan(rng.uniform(1, 100), rng.uniform(0.5, 60), 30, rng.uniform(0, 700), rng.uniform(0, 30))
                    for _ in range(rng.integers(0, 60))
                ]
                t = pol.target(view(loans, tier), NOW, params)
                self.assertLessEqual(t.score, params.cap_score(params.tiers[tier]))
                self.assertLessEqual(t.score, SCALE)

    def test_best_attack_on_one_identity_does_not_pay_under_ic(self):
        for name, tier in P.tiers.items():
            _, rows = sim.best_bust_month(name, P)
            best = max(r["gross_usdc"] for r in rows)
            self.assertLessEqual(best, tier.identity_cost, name)  # profit <= 0 at k_t
            self.assertLessEqual(max(r["line_at_bust_usdc"] for r in rows), P.cap_usdc(tier) + 1e-9)
            self.assertGreater(best, tier.identity_cost / 4, name)  # profit > 0 if k_t was overestimated 4x

    def test_identity_lifetime_loss_is_at_most_its_cap_plus_dues(self):
        """An identity at its cap backs a fresh account that defaults, then borrows what is left and
        defaults itself. Lenders lose at most the cap plus the dues it paid (Theorem 2, per account)."""
        provider, pool, reg = world()
        a, sybil = addr(1), addr(2, 0xF0)
        verify(pool, reg, a, "enhanced")
        publish(provider, plan_for(pool, reg, provider, [a]))
        lines = [provider.score(a)]
        self.assertGreater(pool.granted(a), 0)
        loan = pool.borrow(a, usdc(10), NOW)  # some history, some dues
        pool.repay(loan, NOW + 30 * DAY)
        pool.back(a, sybil, pool.free_credit(a)[0])
        s_loan = pool.borrow(sybil, pool.limit(sybil)[1], NOW + 31 * DAY)
        pool.mark_defaulted(s_loan, NOW + 92 * DAY)
        t = NOW + 93 * DAY
        provider.release_all(pool.usage)
        publish(provider, plan_for(pool, reg, provider, [a], now=t))  # the policy keeps it under its cap
        lines.append(provider.score(a))
        rest = pool.limit(a)[1]
        if rest:
            pool.mark_defaulted(pool.borrow(a, rest, t), t + 61 * DAY)
        max_line = max(lines) * P.max_loan // SCALE
        self.assertLessEqual(max(lines), P.cap_score(P.tiers["enhanced"]))
        self.assertLessEqual(pool.lender_loss, max_line + pool.account(a).dues_paid)
        self.assertGreater(pool.lender_loss, max_line // 2)

    def test_byzantine_loss_bound(self):
        self.assertEqual(pol.byzantine_loss_bound({"basic": 10, "standard": 2}, P), 10 * 15 + 2 * 40)
        cfg = sim.SimConfig(months=14, n_honest=60, n_farm=2, attacks=(sim.AttackSpec("enhanced", 5, 12),))
        res = sim.simulate(cfg)
        loss = sum(r.get("loss_attacker_usdc", 0) for r in res.monthly)
        dues = sum(a.dues_at_bust for a in res.attackers) / USDC
        self.assertGreater(loss, 0)
        self.assertLessEqual(loss, pol.byzantine_loss_bound({"enhanced": 5}, P) + dues + 1e-9)


# ───────────────────────────── property 3: evidence and PD ─────────────────────────────


class Evidence(unittest.TestCase):
    def test_full_trials_give_the_beta_binomial_posterior(self):
        params = replace(P, half_life_days=1e12)
        good = [closed_loan(20, 30) for _ in range(10)]
        late = [closed_loan(20, 45) for _ in range(2)]
        a, b = pol.posterior(view(good + late), NOW, params)
        tier = P.tiers["standard"]
        self.assertAlmostEqual(a, tier.prior_alpha + 2, places=9)
        self.assertAlmostEqual(b, tier.prior_beta + 10, places=9)
        self.assertAlmostEqual(pol.pd_cycle(view(), NOW, P), tier.prior_alpha / (tier.prior_alpha + tier.prior_beta) / 3)

    def test_prior_matches_the_tier_population(self):
        for name, weights in pol.TIER_PD_WEIGHTS.items():
            theta = np.array([3 * pol.cycle_pd(p) for p in pol.PD_GRID])
            w = np.array(weights)
            t = P.tiers[name]
            self.assertAlmostEqual(t.prior_alpha / (t.prior_alpha + t.prior_beta), w @ theta, places=12)

    def test_grace_window_loans_weigh_nothing(self):
        self.assertEqual(pol.loan_evidence(closed_loan(100, 23 / 24), NOW, P), (0.0, 0.0))
        self.assertGreater(pol.loan_evidence(closed_loan(100, 25 / 24), NOW, P)[0], 0)

    def test_stake_secured_principal_weighs_nothing(self):
        self.assertEqual(pol.loan_evidence(closed_loan(100, 30, secured=100), NOW, P), (0.0, 0.0))
        self.assertAlmostEqual(pol.loan_evidence(closed_loan(100, 30, secured=95), NOW, P)[0], 0.5)
        self.assertAlmostEqual(pol.loan_evidence(closed_loan(100, 30, secured=50), NOW, P)[0], 1.0)

    def test_weight_follows_risk_borne(self):
        self.assertAlmostEqual(pol.loan_evidence(closed_loan(2, 30), NOW, P)[0], 0.2)  # size
        self.assertAlmostEqual(pol.loan_evidence(closed_loan(50, 6), NOW, P)[0], 0.2)  # time outstanding
        self.assertAlmostEqual(pol.loan_evidence(closed_loan(50, 300, term_days=365), NOW, P)[0], 1.0)  # one trial

    def test_recency_halves_the_weight_each_half_life(self):
        w0 = pol.loan_evidence(closed_loan(20, 30), NOW, P)[0]
        w1 = pol.loan_evidence(closed_loan(20, 30, age_days=365), NOW, P)[0]
        w2 = pol.loan_evidence(closed_loan(20, 30, age_days=730), NOW, P)[0]
        self.assertAlmostEqual(w1, w0 / 2)
        self.assertAlmostEqual(w2, w0 / 4)

    def test_late_repayment_raises_pd_and_stake_does_not_hide_it(self):
        clean = [closed_loan(20, 30, age_days=30 * i) for i in range(1, 12)]
        late = [closed_loan(20, 50, secured=20)]
        self.assertEqual(pol.loan_evidence(late[0], NOW, P), (0.0, 1.0))
        self.assertGreater(pol.pd_cycle(view(clean + late), NOW, P), pol.pd_cycle(view(clean), NOW, P))
        self.assertLess(pol.target(view(clean + late), NOW, P).score, pol.target(view(clean), NOW, P).score)

    def test_clean_evidence_lowers_pd_and_raises_the_line_monotonically(self):
        pds, lines = [], []
        for n in range(0, 40, 4):
            v = view([closed_loan(20, 30, age_days=30 * i) for i in range(n)], "enhanced")
            pds.append(pol.pd_cycle(v, NOW, P))
            lines.append(pol.target(v, NOW, P).score)
        self.assertTrue(all(np.diff(pds) < 0))
        self.assertTrue(all(np.diff(lines) >= 0))
        self.assertGreater(lines[-1], lines[0])

    def test_loans_of_accounts_it_backed_are_not_its_evidence(self):
        """A guarantor record is farmable (back your own fresh account with 1 USDC of stake and let
        it repay), so the policy reads only the account's own loans."""
        provider, pool, reg = world()
        a, b = addr(1), addr(2, 0xF0)
        verify(pool, reg, a, "standard")
        pool.stake(a, usdc(5))
        before = pol.target(pol.read_account(pool, reg, a), NOW, P)
        pool.back(a, b, usdc(5))
        for i in range(12):
            t = NOW - (13 - i) * 31 * DAY
            pool.repay(pool.borrow(b, usdc(5), t), t + 30 * DAY)
        v = pol.read_account(pool, reg, a)
        self.assertEqual(v.loans, ())
        self.assertEqual(pol.target(v, NOW, P), before)

    def test_overdue_account_gets_zero(self):
        loan = closed_loan(20, 30)
        loan.status, loan.closed_at = LoanStatus.ACTIVE, None
        loan.disbursed_at = NOW - 31 * DAY
        t = pol.target(view([closed_loan(20, 30, age_days=40), loan]), NOW, P)
        self.assertEqual((t.score, t.reason), (0, "overdue"))


# ───────────────────────────── property 4: line sizing and constraints ─────────────────────────────


def provider_state(current, held, extra_held, max_total, max_inc, users):
    prov = ScoreProvider(int(max_total), int(max_inc))
    prov.scores = {u: int(s) for u, s in zip(users, current)}
    prov.budget_held = {u: int(h) for u, h in zip(users, held)}
    prov.total_score = int(sum(current))
    prov.total_held = int(sum(held)) + int(extra_held)
    prov.epoch = 7
    return prov


def random_instance(rng, n=40):
    current = rng.integers(0, SCALE // 2, n) * (rng.random(n) < 0.6)
    held = current + rng.integers(0, SCALE // 4, n) * (rng.random(n) < 0.4)
    target = np.minimum(SCALE, rng.integers(0, SCALE, n) * (rng.random(n) < 0.8))
    pds = rng.uniform(0.0005, 0.006, n)
    extra = int(rng.integers(0, 5 * SCALE))
    max_total = int(held.sum() + extra + rng.integers(-2 * SCALE, 10 * SCALE))
    max_inc = int(rng.integers(0, 8 * SCALE))
    return current, held, target, pds, extra, max_total, max_inc


class LineSizing(unittest.TestCase):
    def test_target_maximises_expected_profit(self):
        grid = np.linspace(0, 400, 40_001)
        for p in (0.0005, 0.002, 0.004, 0.006, 0.0065):
            best = grid[int(np.argmax([pol.expected_profit(x, p, P) for x in grid]))]
            self.assertAlmostEqual(pol.best_line_usdc(p, P), best, delta=0.01)
        self.assertEqual(pol.best_line_usdc(P.premium_per_cycle, P), 0.0)
        self.assertEqual(pol.best_line_usdc(0.02, P), 0.0)

    def test_lower_pd_never_gets_a_smaller_line(self):
        lines = [pol.best_line_usdc(p, P) for p in np.linspace(0.0002, 0.008, 80)]
        self.assertTrue(all(np.diff(lines) <= 0))

    def test_plans_respect_every_contract_rule(self):
        rng = np.random.default_rng(11)
        for _ in range(200):
            cur, held, tgt, pds, extra, max_total, max_inc = random_instance(rng)
            users = [addr(i) for i in range(len(cur))]
            belief = provider_state(cur, held, extra, max_total, max_inc, users)
            cap_inc, cap_bud = alloc.capacities(max_total, belief.total_held, max_inc)
            new = alloc.allocate(cur, held, tgt, pds, cap_inc, cap_bud, P)
            down = tgt <= cur
            self.assertTrue(np.array_equal(new[down], tgt[down]))  # lowering is free and immediate
            self.assertTrue(np.all((cur[~down] <= new[~down]) & (new[~down] <= tgt[~down])))
            self.assertTrue(np.all(new >= 0) and np.all(new <= SCALE))
            self.assertLessEqual(int(np.maximum(new - cur, 0).sum()), cap_inc)
            self.assertLessEqual(int(np.maximum(new - held, 0).sum()), cap_bud)
            changes = [(u, int(n)) for u, n, c in zip(users, new, cur) if n != c]
            report = (8, [u for u, _ in changes], [n for _, n in changes])
            pol._dry_run([report], belief)  # raises if either bracketing state would revert
            # a front-run release of every account to its score cannot make it revert either
            state = belief.copy()
            state.release_all(lambda u: (0, 0))
            state.apply_report(*report)
            self.assertLessEqual(state.total_held, max(max_total, belief.total_held))

    def test_front_run_release_cannot_revert_a_plan(self):
        """X's line was cut to 0 while in use, so its budget is still held. A planner that counted
        X's raise back to its held level as free would spend the raise cap elsewhere; a release
        landing first makes the contract count X's raise too, and that report reverts."""
        x, y = addr(1), addr(2)
        belief = provider_state([0, 0], [SCALE // 2, 0], 0, 10 * SCALE, SCALE // 2, [x, y])
        naive = (8, [x, y], [SCALE // 2, SCALE // 2])
        ok = belief.copy()
        ok.apply_report(*naive)  # passes against the state as read
        front_run = belief.copy()
        front_run.release_all(lambda u: (0, 0))
        with self.assertRaises(Revert):
            front_run.apply_report(*naive)
        v = view(tier="enhanced")
        plan = pol.plan_report([replace(v, address=x), replace(v, address=y)], belief, P, NOW)
        front_run.apply_report(*plan.reports[0])
        self.assertLessEqual(plan.increase, SCALE // 2)

    def test_held_budget_is_used_before_new_budget(self):
        x = addr(1)
        belief = provider_state([0], [SCALE // 2], 0, SCALE // 2, SCALE, [x])  # no new budget at all
        plan = pol.plan_report([view(tier="enhanced", address=x)], belief, P, NOW)
        self.assertGreater(plan.new_scores[x], 0)
        self.assertLessEqual(plan.new_scores[x], SCALE // 2)
        self.assertEqual(plan.budget_used, 0)

    def test_greedy_matches_the_linear_programme(self):
        rng = np.random.default_rng(5)
        for k in range(90):
            cur, held, tgt, pds, extra, max_total, max_inc = random_instance(rng, n=25)
            cap_bud = max(0, max_total - int(held.sum()) - extra)
            if k % 3 == 0:
                max_inc = 10**12  # only the budget binds
            elif k % 3 == 1:
                cap_bud = 10**12  # only the raise cap binds
            new = alloc.allocate(cur, held, tgt, pds, max_inc, cap_bud, P)
            _, lp = alloc.allocate_lp(cur, held, tgt, pds, max_inc, cap_bud, P)
            greedy = alloc.raise_profit(cur, held, new, tgt, pds, P)
            self.assertAlmostEqual(greedy, lp, delta=1e-6 + 1e-5 * abs(lp))

    def test_large_plans_split_into_batches_with_increasing_epochs(self):
        users = [addr(i) for i in range(1_234)]
        belief = ScoreProvider(2_000 * SCALE, 2_000 * SCALE)
        belief.epoch = 41
        plan = pol.plan_report([view(tier="standard", address=u) for u in users], belief, P, NOW)
        self.assertEqual([r[0] for r in plan.reports], [42, 43, 44])
        self.assertTrue(all(len(r[1]) <= model.MAX_BATCH for r in plan.reports))
        state = belief.copy()
        publish(state, plan)
        self.assertEqual(sum(state.scores.values()), sum(plan.new_scores.values()))

    def test_lowered_lines_keep_their_budget_until_released(self):
        provider, pool, reg = world(budget_lines=0.6, increase_lines=0.6)
        a, b = addr(1), addr(2)
        verify(pool, reg, a, "enhanced")
        publish(provider, plan_for(pool, reg, provider, [a]))
        held_a = provider.held(a)
        loan = pool.borrow(a, pool.limit(a)[1], NOW + 1)
        verify(pool, reg, b, "enhanced")
        t = NOW + 31 * DAY  # a is overdue: its line goes to 0 at once, its budget stays held
        plan = plan_for(pool, reg, provider, [a, b], now=t)
        self.assertEqual(plan.new_scores[a], 0)
        self.assertEqual(plan.new_scores[b], provider.max_total_score - held_a)  # only what is left
        publish(provider, plan)
        self.assertEqual(provider.held(a), held_a)
        provider.release_all(pool.usage)  # still in use: nothing released
        self.assertEqual(provider.held(a), held_a)
        pool.mark_defaulted(loan, NOW + 62 * DAY)
        provider.release_all(pool.usage)
        self.assertEqual(provider.held(a), 0)
        plan = plan_for(pool, reg, provider, [a, b], now=NOW + 62 * DAY)
        publish(provider, plan)
        self.assertEqual(plan.new_scores[b], plan.targets[b].score)


# ───────────────────────────── property 5: no backing graph ─────────────────────────────


class NoBackingGraph(unittest.TestCase):
    def _world_with_history(self):
        provider, pool, reg = world()
        accounts = [addr(i) for i in range(6)]
        for i, a in enumerate(accounts):
            verify(pool, reg, a, ("basic", "standard", "enhanced")[i % 3])
        publish(provider, plan_for(pool, reg, provider, accounts, now=NOW - 400 * DAY))
        for k in range(10):
            t = NOW - 300 * DAY + k * 31 * DAY
            for i, a in enumerate(accounts):
                if (i + k) % 4:
                    loan = pool.borrow(a, min(pool.limit(a)[1], usdc(10)), t)
                    pool.repay(loan, t + (45 if (i * k) % 7 == 6 else 29) * DAY)
        return provider, pool, reg, accounts

    def test_reports_ignore_the_backing_graph(self):
        provider, pool, reg, accounts = self._world_with_history()
        before = plan_for(pool, reg, provider, accounts)
        # a staked Sybil ring around everyone, honest accounts backing each other, a ring among themselves
        sybils = [addr(i, 0xF0) for i in range(8)]
        for s in sybils:
            pool.stake(s, usdc(50))
        for i, s in enumerate(sybils):
            pool.back(s, sybils[(i + 1) % len(sybils)], usdc(10))
            pool.back(s, accounts[i % len(accounts)], usdc(10))
        for i, a in enumerate(accounts):
            credit, _ = pool.free_credit(a)
            if credit >= USDC:
                pool.back(a, accounts[(i + 1) % len(accounts)], credit)
        after = plan_for(pool, reg, provider, accounts)
        self.assertEqual(before.reports, after.reports)
        self.assertEqual(before.targets, after.targets)

    def test_secured_backing_can_only_lower_a_line(self):
        base = [closed_loan(20, 30, age_days=31 * i) for i in range(20)]
        lines = []
        for secured in (0, 5, 10, 15, 20, 30):
            loans = [replace(x, secured=usdc(secured)) for x in base]
            lines.append(pol.target(view(loans, "enhanced"), NOW, P).score)
        self.assertTrue(all(np.diff(lines) <= 0))
        self.assertEqual(lines[-1], pol.target(view((), "enhanced"), NOW, P).score)

    def test_policy_inputs_carry_no_backing_edge(self):
        self.assertEqual(
            {f.name for f in fields(pol.AccountView)},
            {"address", "kyc_verified", "tier", "identity_ok", "defaulted", "loans"},
        )
        self.assertNotIn("backer", {f.name for f in fields(Loan)})
        code = re.sub(r'"""[\s\S]*?"""|#.*', "", inspect.getsource(pol) + inspect.getsource(alloc))
        for name in ("backings", "secured_in", "_backing_received", "free_credit", "credit_committed", "limit("):
            self.assertNotIn(name, code)


# ───────────────────────────── property 6: report format ─────────────────────────────


class ReportFormat(unittest.TestCase):
    def test_reports_are_what_the_provider_decodes(self):
        provider, pool, reg = world()
        users = [addr(i) for i in range(5)]
        for u in users:
            verify(pool, reg, u, "enhanced")
        plan = plan_for(pool, reg, provider, users)
        self.assertEqual(len(plan.reports), 1)
        epoch, us, scores = plan.reports[0]
        self.assertIsInstance(epoch, int)
        self.assertTrue(0 < epoch < 2**64)
        self.assertEqual(len(us), len(scores))
        self.assertEqual(len(set(us)), len(us))
        self.assertTrue(all(re.fullmatch(r"0x[0-9a-f]{40}", u) for u in us))
        self.assertTrue(all(isinstance(s, int) and 0 <= s <= SCALE for s in scores))
        self.assertEqual(pol.report_json(plan.reports[0]), {"epoch": epoch, "users": us, "scores": scores})
        publish(provider, plan)
        self.assertEqual(pol.heartbeat(provider), (epoch + 1, [], []))
        provider.apply_report(*pol.heartbeat(provider))

    @unittest.skipUnless(pol.encode_report((1, [], [])) is not None, "eth_abi not installed")
    def test_abi_encoding_round_trips(self):  # pragma: no cover - needs eth_abi
        from eth_abi import decode

        report = (3, [addr(1), addr(2)], [5, SCALE])
        raw = bytes.fromhex(pol.encode_report(report)[2:])
        epoch, users, scores = decode(["uint64", "address[]", "uint256[]"], raw)
        self.assertEqual((epoch, [u.lower() for u in users], list(scores)), report)


# ───────────────────────────── property 7: simulation ─────────────────────────────


class ShortSimulation(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cfg = sim.SimConfig(
            months=12, n_honest=250, budget_lines=40, increase_lines=12, n_farm=4,
            attacks=(sim.AttackSpec("basic", 3, 8),),
        )
        cls.res = sim.simulate(cfg)

    def test_no_report_is_rejected_and_budget_holds(self):
        self.assertEqual(self.res.rejections, 0)
        for row in self.res.monthly[:-1]:
            self.assertLessEqual(row["total_held"], row["max_total"] + 1e-9)
            self.assertLessEqual(row["increase"], row["max_increase"] + 1e-9)
            self.assertLessEqual(row["exposure_usdc"], row["exposure_bound_usdc"] + 1e-9)

    def test_farms_earn_nothing(self):
        rows = {r["account"]: r for r in self.res.farm}
        for r in self.res.farm:
            if r["account"] == "unverified farm":
                self.assertEqual(r["published_line_usdc"], 0)
                self.assertEqual(r["naive_25pct_line_usdc"], 100.0)
        self.assertEqual(rows["verified farm"]["policy_target_usdc"], rows["control"]["policy_target_usdc"])

    def test_lines_fall_with_true_pd(self):
        last = self.res.lines[-1]
        low = [last[i] for i, h in enumerate(self.res.honest) if h.pd_annual <= 0.02]
        high = [last[i] for i, h in enumerate(self.res.honest) if h.pd_annual >= 0.10]
        self.assertGreater(np.mean(low), np.mean(high))

    def test_attackers_lose_money_under_ic(self):
        self.assertLess(sim.attacker_profit(self.res), 0)
        for a in self.res.attackers:
            self.assertLessEqual(a.line_at_bust, P.cap_usdc(P.tiers[a.tier]) + 1e-9)


if __name__ == "__main__":
    unittest.main()
