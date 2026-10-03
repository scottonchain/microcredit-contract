"""Unit tests for vasicek.py and montecarlo.py.

    cd analysis/credit_risk && python3 -m unittest -v test_vasicek
"""

from __future__ import annotations

import math
import unittest

import numpy as np
from scipy import integrate
from scipy.special import owens_t
from scipy.stats import multivariate_normal, norm

import montecarlo as mc
import vasicek as vs

PD, RHO = 0.05, 0.0526  # close to the Basel other-retail rho at PD 5%


class BaselCorrelation(unittest.TestCase):
    def test_published_endpoints(self):
        # BCBS (2006) para. 330: 0.16 for PD -> 0, 0.03 for PD = 1.
        self.assertAlmostEqual(vs.basel_other_retail_correlation(0.0), 0.16, places=15)
        self.assertAlmostEqual(vs.basel_other_retail_correlation(1.0), 0.03, places=15)
        self.assertAlmostEqual(vs.basel_other_retail_correlation(1e-9), 0.16, places=7)

    def test_formula_and_monotonicity(self):
        for pd in (0.0003, 0.01, 0.05, 0.2, 0.6):
            w = (1 - math.exp(-35 * pd)) / (1 - math.exp(-35))
            self.assertAlmostEqual(vs.basel_other_retail_correlation(pd), 0.03 * w + 0.16 * (1 - w), places=14)
        # Strictly decreasing where exp(-35 PD) is resolvable; flat at 0.03 (to double precision) beyond.
        self.assertTrue(np.all(np.diff(vs.basel_other_retail_correlation(np.linspace(0, 0.5, 501))) < 0))
        self.assertTrue(np.all(np.diff(vs.basel_other_retail_correlation(np.linspace(0, 1, 501))) <= 0))


class VasicekDistribution(unittest.TestCase):
    def test_el_equals_pd_times_lgd(self):
        self.assertAlmostEqual(vs.expected_loss(0.03, 0.6), 0.018, places=15)
        # E[D] = PD: integrate the density and the survival function independently.
        mean_pdf, _ = integrate.quad(lambda x: x * vs.vasicek_pdf(x, PD, RHO), 0, 1, limit=200, points=[PD])
        mean_sf, _ = integrate.quad(lambda x: 1 - vs.vasicek_cdf(x, PD, RHO), 0, 1, limit=200, points=[PD])
        self.assertAlmostEqual(mean_pdf, PD, places=8)
        self.assertAlmostEqual(mean_sf, PD, places=8)
        self.assertAlmostEqual(vs.stop_loss(PD, RHO, 0.0), PD, places=12)

    def test_density_integrates_to_one(self):
        total, _ = integrate.quad(lambda x: vs.vasicek_pdf(x, PD, RHO), 0, 1, limit=200, points=[PD])
        self.assertAlmostEqual(total, 1.0, places=8)

    def test_quantile_inverts_cdf(self):
        for q in (0.5, 0.95, 0.99, 0.999):
            x = vs.vasicek_quantile(PD, RHO, q)
            self.assertAlmostEqual(vs.vasicek_cdf(x, PD, RHO), q, places=12)

    def test_quantile_known_value(self):
        # Hand computation: Phi((Phi^-1(0.05) + sqrt(0.05) Phi^-1(0.999)) / sqrt(0.95)).
        expected = norm.cdf((norm.ppf(0.05) + math.sqrt(0.05) * norm.ppf(0.999)) / math.sqrt(0.95))
        self.assertAlmostEqual(vs.vasicek_quantile(0.05, 0.05, 0.999), expected, places=15)
        self.assertAlmostEqual(expected, 0.1639, places=3)

    def test_small_rho_collapses_to_pd(self):
        self.assertAlmostEqual(vs.vasicek_quantile(PD, 1e-10, 0.999), PD, places=4)

    def test_basel_capital_is_ul_at_999(self):
        k = vs.basel_irb_capital(PD, lgd=0.45)
        self.assertAlmostEqual(k, 0.45 * (vs.vasicek_quantile(PD, vs.basel_other_retail_correlation(PD), 0.999) - PD), places=15)

    def test_lgd_scales_quantiles_linearly(self):
        self.assertAlmostEqual(vs.loss_quantile(PD, RHO, 0.99, 0.3), 0.3 * vs.loss_quantile(PD, RHO, 0.99), places=15)

    def test_bivariate_normal(self):
        for h, k, r in ((-1.6, -1.6, 0.05), (-2.3, 3.09, -0.23), (0.4, -0.7, 0.3)):
            ref = multivariate_normal(mean=[0, 0], cov=[[1, r], [r, 1]]).cdf([h, k])
            self.assertAlmostEqual(vs.bivariate_normal_cdf(h, k, r), ref, places=5)
        # Owen's T identity for h = k: Phi2(h, h; r) = Phi(h) - 2 T(h, sqrt((1 - r)/(1 + r))).
        for h, r in ((-1.645, 0.0526), (-2.33, 0.16), (-0.84, 0.03)):
            ident = norm.cdf(h) - 2 * owens_t(h, math.sqrt((1 - r) / (1 + r)))
            self.assertAlmostEqual(vs.bivariate_normal_cdf(h, h, r), ident, places=12)

    def test_variance_closed_form(self):
        z, w = np.polynomial.hermite_e.hermegauss(200)
        second = np.dot(w, vs.conditional_pd(PD, RHO, z) ** 2) / math.sqrt(2 * math.pi)
        self.assertAlmostEqual(vs.vasicek_variance(PD, RHO), second - PD**2, places=10)

    def test_expected_shortfall_closed_form(self):
        q = 0.999
        num, _ = integrate.quad(lambda u: vs.vasicek_quantile(PD, RHO, u), q, 1, limit=200)
        self.assertAlmostEqual(vs.expected_shortfall(PD, RHO, q), num / (1 - q), places=7)
        self.assertGreater(vs.expected_shortfall(PD, RHO, q), vs.vasicek_quantile(PD, RHO, q))

    def test_stop_loss_closed_form(self):
        for k in (0.02, 0.05, 0.12):
            num, _ = integrate.quad(lambda x: 1 - vs.vasicek_cdf(x, PD, RHO), k, 1, limit=200)
            self.assertAlmostEqual(vs.stop_loss(PD, RHO, k), num, places=9)


class PdHorizon(unittest.TestCase):
    def test_roundtrip(self):
        for pd in (0.01, 0.05, 0.2):
            for t in (1, 7, 30, 365):
                self.assertAlmostEqual(vs.annual_pd_from_loan_pd(vs.loan_pd_from_annual_pd(pd, t), t), pd, places=14)
        self.assertAlmostEqual(vs.loan_pd_from_annual_pd(0.07, 365), 0.07, places=15)

    def test_thirty_day_values(self):
        # 3% per 30-day loan compounds to 1 - 0.97^(365/30) = 31.0% a year.
        self.assertAlmostEqual(vs.annual_pd_from_loan_pd(0.03, 30), 1 - 0.97 ** (365 / 30), places=14)
        self.assertAlmostEqual(vs.annual_pd_from_loan_pd(0.03, 30), 0.310, places=3)

    def test_replenished_rate_bounds(self):
        # PD <= n p <= hazard, with n p -> hazard as the term shrinks.
        for pd in (0.01, 0.1, 0.3):
            rep = vs.replenished_default_rate(pd, 30)
            self.assertGreaterEqual(rep, pd)
            self.assertLessEqual(rep, vs.hazard_rate(pd))
            self.assertAlmostEqual(vs.replenished_default_rate(pd, 1e-4), vs.hazard_rate(pd), places=6)


class Granularity(unittest.TestCase):
    def test_ga_matches_numerical_derivative(self):
        # Independent check of the algebra: GA = -1/(2 phi(y)) d/dy [phi(y) s2(y) / mu'(y)].
        n, q = 500, 0.999
        c, sr, s1 = norm.ppf(PD), math.sqrt(RHO), math.sqrt(1 - RHO)

        def mu(y):
            return norm.cdf((c + sr * y) / s1)

        def f(y, e=1e-5):
            dmu = (mu(y + e) - mu(y - e)) / (2 * e)
            return norm.pdf(y) * mu(y) * (1 - mu(y)) / n / dmu

        y, e = norm.ppf(q), 1e-4
        ga_num = -(f(y + e) - f(y - e)) / (2 * e) / (2 * norm.pdf(y))
        self.assertAlmostEqual(vs.granularity_adjustment(PD, RHO, q, n), ga_num, places=6)
        self.assertGreater(ga_num, 0)

    def test_mc_quantile_matches_vasicek_for_large_n(self):
        n, m = 200_000, 400_000
        losses = mc.simulate_loss_rates(PD, RHO, n, m, seed=(1, 1))
        for q, tol in ((0.99, 0.01), (0.999, 0.02)):
            ref = vs.vasicek_quantile(PD, RHO, q)
            got = mc.empirical_quantile(losses, q)
            self.assertLess(abs(got / ref - 1), tol, f"q={q}: MC {got:.5f} vs ASRF {ref:.5f}")
            lo, hi = mc.quantile_ci(losses, q)
            self.assertTrue(lo <= ref + vs.granularity_adjustment(PD, RHO, q, n) <= hi + 1e-12)
        self.assertLess(abs(losses.mean() - PD), 4 * losses.std() / math.sqrt(m))

    def test_ga_improves_on_asrf_for_small_pool(self):
        n = 500
        losses = mc.simulate_loss_rates(PD, RHO, n, 400_000, seed=(1, 2))
        got = mc.empirical_quantile(losses, 0.999)
        asrf = vs.vasicek_quantile(PD, RHO, 0.999)
        ga = asrf + vs.granularity_adjustment(PD, RHO, 0.999, n)
        self.assertGreater(got, asrf)
        self.assertLess(abs(got - ga), abs(got - asrf))
        self.assertLess(abs(got - ga), 2.0 / n)  # within two lattice steps

    def test_finite_n_variance(self):
        n, m = 100, 400_000
        losses = mc.simulate_loss_rates(PD, RHO, n, m, seed=(1, 3))
        c = norm.ppf(PD)
        c2 = vs.bivariate_normal_cdf(c, c, RHO)
        exact = c2 - PD**2 + (PD - c2) / n
        self.assertLess(abs(losses.var() / exact - 1), 0.02)


class MonteCarlo(unittest.TestCase):
    def test_bruteforce_matches_binomial(self):
        n, m = 200, 40_000
        bf = mc.simulate_loss_rates_bruteforce(PD, RHO, n, m, seed=(2, 1))
        bi = mc.simulate_loss_rates(PD, RHO, n, m, seed=(2, 2))
        se = math.sqrt(bf.var() / m + bi.var() / m)
        self.assertLess(abs(bf.mean() - bi.mean()), 4 * se)
        self.assertLess(abs(bf.std() / bi.std() - 1), 0.04)
        self.assertLess(abs(mc.empirical_quantile(bf, 0.99) - mc.empirical_quantile(bi, 0.99)), 0.01)

    def test_deterministic_seeds(self):
        a = mc.simulate_loss_rates(PD, RHO, 50, 1000, seed=(9, 9))
        b = mc.simulate_loss_rates(PD, RHO, 50, 1000, seed=(9, 9))
        np.testing.assert_array_equal(a, b)

    def test_quantile_ci_contains_estimate(self):
        x = mc.simulate_loss_rates(PD, RHO, 1000, 50_000, seed=(3, 1))
        lo, hi = mc.quantile_ci(x, 0.99)
        self.assertLessEqual(lo, mc.empirical_quantile(x, 0.99))
        self.assertGreaterEqual(hi, mc.empirical_quantile(x, 0.99))

    def test_revolving_year(self):
        n, m = 1000, 100_000
        static, _ = mc.simulate_revolving_year(PD, RHO, n, m, replace=False, seed=(4, 1))
        rep, active = mc.simulate_revolving_year(PD, RHO, n, m, replace=True, seed=(4, 1))
        # Static: each obligor defaults within 12 cycles with the Vasicek conditional PD.
        self.assertLess(abs(static.mean() - PD), 4 * static.std() / math.sqrt(m))
        # Replenished: more defaults than static, at most the zero-lag ASRF value (lag idles slots).
        el_rep = vs.replenished_expected_loss(PD, RHO, term_days=365 / 12)
        self.assertGreater(rep.mean(), static.mean())
        self.assertLess(rep.mean(), el_rep + 4 * rep.std() / math.sqrt(m))
        self.assertTrue(np.all(active <= 1.0))


class PricingAndReserve(unittest.TestCase):
    def test_breakeven_formula(self):
        h = 0.15
        s = vs.breakeven_premium(PD, RHO, h)
        self.assertAlmostEqual(s, PD + h * (vs.vasicek_quantile(PD, RHO, 0.999) - PD), places=15)
        self.assertGreater(vs.breakeven_premium(0.06, RHO, h), s)
        self.assertGreater(vs.breakeven_premium(PD, 0.10, h), s)
        # Pool-level formula reduces to the loan-level one at full utilisation and no fee.
        self.assertAlmostEqual(vs.pool_breakeven_premium(PD, RHO, h, utilisation=1.0, fee=0.0), s, places=15)

    def test_max_pd_for_premium_is_a_root(self):
        for rho in (None, 0.15):
            p = vs.max_pd_for_premium(0.05, 0.15, rho)
            r = vs.resolve_rho(p, rho)
            self.assertAlmostEqual(vs.breakeven_premium(p, r, 0.15), 0.05, places=10)
        self.assertAlmostEqual(vs.max_pd_for_premium(0.05, 0.0, 0.1), 0.05, places=10)
        # Pool level at h = 0: u (APR - PD) = EFFR.
        self.assertAlmostEqual(vs.max_pd_for_premium(0.05, 0.0, 0.1, utilisation=0.85), vs.APR - vs.EFFR / 0.85, places=10)

    def test_lender_apy_formula(self):
        u, apr, f, r = 0.85, vs.APR, 0.1, 0.2
        self.assertAlmostEqual(vs.lender_apy(0.0, u, apr, f, r), u * apr * (1 - f - r), places=15)
        # Reserve released at year end: identical to no reserve.
        for L in (0.0, 0.03, 0.2):
            self.assertAlmostEqual(vs.lender_apy(L, u, apr, f, r, release=True), vs.lender_apy(L, u, apr, f, 0.0), places=15)
        # No reserve: u APR (1 - f) - u L.
        self.assertAlmostEqual(vs.lender_apy(0.07, u, apr, f), u * apr * (1 - f) - u * 0.07, places=15)

    def test_expected_apy_matches_monte_carlo(self):
        u, r = 0.85, 0.3
        st = vs.lender_apy_stats(PD, RHO, utilisation=u, reserve_share=r)
        d = vs.conditional_pd(PD, RHO, mc.rng_for((5, 1)).standard_normal(400_000))
        apy = vs.lender_apy(d, u, reserve_share=r)
        self.assertLess(abs(apy.mean() - st["expected_apy"]), 4 * apy.std() / math.sqrt(apy.size))
        self.assertAlmostEqual(st["apy_low"], vs.lender_apy(vs.vasicek_quantile(PD, RHO, 0.99), u, reserve_share=r), places=15)
        self.assertLess(abs((apy < 0).mean() - st["p_apy_below_0"]), 0.003)

    def test_reserve_at_quantile_bounds_lender_loss_probability(self):
        for q in (0.95, 0.99):
            lq = vs.loss_quantile(PD, RHO, q)
            self.assertAlmostEqual(vs.prob_lender_loss(PD, RHO, 1.0, lq), 1 - q, places=12)
            # Utilisation cancels in the reserve share.
            self.assertAlmostEqual(vs.reserve_share_for_target(lq, 0.1), lq / 0.1, places=15)
        self.assertEqual(vs.prob_lender_loss(PD, RHO, 0.0, 0.0), 0.0)

    def test_reserve_paths(self):
        cap = 0.06
        ll, bal = mc.simulate_reserve_paths(PD, RHO, 5, 20_000, 0.6, cap, seed=(6, 1))
        self.assertTrue(np.all(bal <= cap + 1e-15) and np.all(bal >= 0) and np.all(ll >= 0))
        self.assertLess((ll[4] > 0).mean(), (ll[0] > 0).mean())

    def test_stale_nav_transfer(self):
        t = vs.stale_nav_transfer(0.2, 500.0, 10_000.0)
        self.assertAlmostEqual(t["transfer"], 100.0)
        self.assertAlmostEqual(t["exit_paid"] - t["exit_fair"], t["transfer"])
        self.assertAlmostEqual(t["stayer_loss_rate"], 500 / 8000)


if __name__ == "__main__":
    unittest.main()
