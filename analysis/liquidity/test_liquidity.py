"""Tests for the liquidity model: routers against independent references, the Sybil bound, and the
repeated-transaction simulation.

    python3 -m unittest discover analysis/liquidity
"""

from __future__ import annotations

import itertools
import sys
import unittest
from pathlib import Path

import networkx as nx
import numpy as np
from scipy.optimize import linprog

sys.path.insert(0, str(Path(__file__).resolve().parent))

import model as m  # noqa: E402


def line_network(edges, credit, c):
    """Undirected edges, both arcs of capacity c."""
    graph = nx.Graph()
    graph.add_nodes_from(range(len(credit)))
    graph.add_edges_from(edges)
    return m.Network.from_graph(graph, np.asarray(credit, dtype=float), c)


def random_network(seed: int, n: int = 14, p: float = 0.3, q: float = 0.35, line: float = 30,
                   c_low: int = 5, c_high: int = 25) -> m.Network:
    """A small random network with random integral arc capacities (each direction drawn apart)."""
    rng = np.random.default_rng(seed)
    graph = nx.gnp_random_graph(n, p, seed=int(rng.integers(2**31)))
    credit = m.assign_credit(n, q, line, rng)
    net = m.Network.from_graph(graph, credit, 1)
    net.cap = rng.integers(c_low, c_high + 1, size=net.arcs).astype(float)
    return net


def path_lp(net: m.Network, sinks, k: int | None) -> float:
    """Reference: the path formulation, with every simple path of at most k arcs enumerated."""
    sinks = set(np.atleast_1d(sinks).tolist())
    graph = nx.DiGraph()
    graph.add_nodes_from(range(net.n))
    arc_index = {}
    for a, (u, v) in enumerate(zip(net.tail.tolist(), net.head.tolist())):
        if u in sinks:
            continue
        graph.add_edge(u, v)
        arc_index[(u, v)] = a
    holders = [v for v in range(net.n) if net.credit[v] > 0 and v not in sinks]
    paths = []
    for s in holders:
        for t in sinks:
            for p in nx.all_simple_paths(graph, s, t, cutoff=k):
                if any(x in sinks for x in p[1:-1]):
                    continue
                paths.append(p)
    if not paths:
        return 0.0
    arcs_used = sorted({arc_index[e] for p in paths for e in zip(p, p[1:])})
    row_of_arc = {a: i for i, a in enumerate(arcs_used)}
    a_ub = np.zeros((len(arcs_used) + len(holders), len(paths)))
    for j, p in enumerate(paths):
        for e in zip(p, p[1:]):
            a_ub[row_of_arc[arc_index[e]], j] = 1
        a_ub[len(arcs_used) + holders.index(p[0]), j] = 1
    b_ub = np.concatenate([net.cap[arcs_used], net.credit[holders]])
    sol = linprog(-np.ones(len(paths)), A_ub=a_ub, b_ub=b_ub, bounds=(0, None), method="highs")
    assert sol.status == 0
    return float(-sol.fun)


def networkx_maxflow(net: m.Network, sinks) -> float:
    """Reference: networkx max-flow from a super-source with supply arcs of capacity free credit."""
    sinks = set(np.atleast_1d(sinks).tolist())
    graph = nx.DiGraph()
    for u, v, cap in zip(net.tail.tolist(), net.head.tolist(), net.cap.tolist()):
        if u not in sinks:
            graph.add_edge(u, v, capacity=cap)
    for v in range(net.n):
        if net.credit[v] > 0 and v not in sinks:
            graph.add_edge("S", v, capacity=net.credit[v])
    for t in sinks:
        graph.add_edge(t, "T", capacity=float("inf"))
    if "S" not in graph:
        return 0.0
    return float(nx.maximum_flow_value(graph, "S", "T"))


def assert_feasible(test: unittest.TestCase, net: m.Network, state: m.State, flow: m.Flow, sinks):
    """Capacities respected and flow conserved at every node outside the sink set."""
    sink_mask = m._mask(net.n, sinks)
    supply = np.bincount(flow.src, weights=flow.src_amount, minlength=net.n)
    arc = np.zeros(net.arcs)
    np.add.at(arc, flow.arcs, flow.arc_amount)
    test.assertTrue(np.all(supply <= state.free + 1e-6))
    test.assertTrue(np.all(arc <= state.res + 1e-6))
    test.assertFalse(np.any(arc[sink_mask[net.tail]] > 1e-9), "no flow leaves a sink")
    inflow = np.bincount(net.head, weights=arc, minlength=net.n)
    outflow = np.bincount(net.tail, weights=arc, minlength=net.n)
    balance = supply + inflow - outflow
    np.testing.assert_allclose(balance[~sink_mask], 0, atol=1e-6)
    test.assertAlmostEqual(balance[sink_mask].sum(), flow.value, places=5)


class SmallNetworks(unittest.TestCase):
    def test_path_needs_two_hops(self):
        # holder 0 - relay 1 - borrower 2
        net = line_network([(0, 1), (1, 2)], [100, 0, 0], 25)
        st = m.State.fresh(net)
        self.assertEqual(m.onehop(net, st, 2).value, 0)
        self.assertEqual(m.twohop(net, st, 2).value, 25)
        self.assertAlmostEqual(m.khop(net, st, 2, 2).value, 25)
        self.assertEqual(m.unbounded(net, st, 2).value, 25)
        self.assertEqual(m.path_liable(net, st, 2), 0)

    def test_three_hops(self):
        # holder 0 - 1 - 2 - borrower 3
        net = line_network([(0, 1), (1, 2), (2, 3)], [100, 0, 0, 0], 25)
        st = m.State.fresh(net)
        self.assertEqual(m.twohop(net, st, 3).value, 0)
        self.assertAlmostEqual(m.khop(net, st, 3, 3).value, 25)
        self.assertEqual(m.unbounded(net, st, 3).value, 25)

    def test_direct_backers_capped_by_c_and_credit(self):
        # borrower 0 with holders 1 (credit 100), 2 (credit 10), and 3 (no credit)
        net = line_network([(0, 1), (0, 2), (0, 3)], [0, 100, 10, 0], 25)
        st = m.State.fresh(net)
        self.assertEqual(m.onehop(net, st, 0).value, 35)
        self.assertEqual(m.static_values(net, 0)["unbounded"], 35)

    def test_supply_cap_shared_between_routes(self):
        # holder 0 (credit 30) reaches borrower 3 through relays 1 and 2, c = 25 each
        net = line_network([(0, 1), (0, 2), (1, 3), (2, 3)], [30, 0, 0, 0], 25)
        st = m.State.fresh(net)
        self.assertEqual(m.twohop(net, st, 3).value, 30)
        self.assertAlmostEqual(m.khop(net, st, 3, 2).value, 30)

    def test_demand_is_met_exactly_or_refused(self):
        net = line_network([(0, 1), (1, 2), (0, 2)], [100, 0, 0], 25)
        st = m.State.fresh(net)
        for regime in m.REGIMES:
            flow = m.route(net, st, 2, regime, demand=40)
            if regime == "one-hop":
                self.assertEqual(len(flow.src), 0)
                self.assertEqual(flow.value, 25)  # what was available
            else:
                self.assertAlmostEqual(flow.value, 40)
                self.assertAlmostEqual(flow.src_amount.sum(), 40)
                if regime != "centralised":  # no trust arcs to check there
                    assert_feasible(self, net, st, flow, [2])

    def test_khop_prefers_short_paths(self):
        # direct arc 0 -> 2 and the detour 0 -> 1 -> 2 both available; demand fits the direct arc
        net = line_network([(0, 1), (1, 2), (0, 2)], [100, 0, 0], 25)
        flow = m.khop(net, m.State.fresh(net), 2, 2, demand=20)
        self.assertAlmostEqual(flow.mean_hops, 1.0)

    def test_static_commitment_splits_credit(self):
        # holder 0 (credit 100) with four neighbours without credit: 25 each, capped at c = 20
        net = line_network([(0, 1), (0, 2), (0, 3), (0, 4)], [100, 0, 0, 0, 0], 20)
        self.assertEqual(m.onehop_static(net, 1), 20)
        net = line_network([(0, i) for i in range(1, 9)], [100] + [0] * 8, 20)
        self.assertEqual(m.onehop_static(net, 1), 12.5)


class AgainstReferences(unittest.TestCase):
    SEEDS = range(12)

    def test_khop_lp_equals_path_enumeration(self):
        for seed in self.SEEDS:
            net = random_network(seed)
            st = m.State.fresh(net)
            sink = int(np.flatnonzero(net.credit == 0)[0])
            for k in (2, 3):
                with self.subTest(seed=seed, k=k):
                    self.assertAlmostEqual(m.khop(net, st, sink, k).value, path_lp(net, sink, k), places=5)

    def test_khop_lp_with_sink_sets(self):
        for seed in self.SEEDS:
            net = random_network(seed, n=12)
            st = m.State.fresh(net)
            sinks = np.flatnonzero(net.credit == 0)[:3]
            for k in (2, 3):
                with self.subTest(seed=seed, k=k):
                    self.assertAlmostEqual(m.khop(net, st, sinks, k).value, path_lp(net, sinks, k), places=5)

    def test_layered_twohop_equals_lp(self):
        for seed in self.SEEDS:
            net = random_network(seed, n=40, p=0.12)
            st = m.State.fresh(net)
            for sink in np.flatnonzero(net.credit == 0)[:5]:
                with self.subTest(seed=seed, sink=int(sink)):
                    layered, cut = m.twohop(net, st, int(sink), with_cut=True)
                    self.assertAlmostEqual(layered.value, m.khop(net, st, int(sink), 2).value, places=5)
                    self.assertAlmostEqual(cut, layered.value)
                    assert_feasible(self, net, st, layered, [int(sink)])

    def test_unbounded_equals_networkx_and_long_khop(self):
        for seed in self.SEEDS:
            net = random_network(seed, n=10)
            st = m.State.fresh(net)
            sink = int(np.flatnonzero(net.credit == 0)[0])
            ref = networkx_maxflow(net, sink)
            with self.subTest(seed=seed):
                self.assertAlmostEqual(m.unbounded(net, st, sink).value, ref)
                self.assertAlmostEqual(m.khop(net, st, sink, net.n - 1).value, ref, places=5)
                self.assertAlmostEqual(path_lp(net, sink, None), ref, places=5)

    def test_regimes_are_ordered(self):
        for seed in self.SEEDS:
            net = random_network(seed, n=40, p=0.1)
            for b in np.flatnonzero(net.credit == 0)[:6]:
                v = m.static_values(net, int(b))
                v3 = m.khop(net, m.State.fresh(net), int(b), 3).value
                with self.subTest(seed=seed, b=int(b)):
                    self.assertAlmostEqual(v3, v["3-hop"], places=5)
                    chain = [v["one-hop-static"], v["one-hop"], v["2-hop"], v["3-hop"], v["unbounded"], v["centralised"]]
                    self.assertTrue(all(a <= b_ + 1e-6 for a, b_ in zip(chain, chain[1:])), chain)

    def test_path_liable_equals_onehop(self):
        for seed in self.SEEDS:
            net = random_network(seed, n=30, p=0.15)
            st = m.State.fresh(net)
            needy = np.flatnonzero(net.credit == 0)
            for sinks in [needy[:1], needy[1:2], needy[:4]]:
                with self.subTest(seed=seed, sinks=sinks.tolist()):
                    self.assertAlmostEqual(m.path_liable(net, st, sinks), m.onehop(net, st, sinks).value)
                    self.assertAlmostEqual(m.onehop_cut(net, st, sinks), m.onehop(net, st, sinks).value)

    def test_cuts_equal_flows(self):
        for seed in self.SEEDS:
            net = random_network(seed, n=30, p=0.15)
            st = m.State.fresh(net)
            sinks = np.flatnonzero(net.credit == 0)[:3]
            value, cut, side = m.min_cut(net, st, sinks)
            value3, dual3 = m.khop_dual(net, st, sinks, 3)
            with self.subTest(seed=seed):
                self.assertAlmostEqual(value, cut)
                self.assertFalse(side[sinks].any())
                self.assertAlmostEqual(value3, dual3, places=5)
                self.assertAlmostEqual(value3, m.khop(net, st, sinks, 3).value, places=5)

    def test_flows_are_feasible(self):
        for seed in self.SEEDS:
            net = random_network(seed, n=30, p=0.15)
            st = m.State.fresh(net)
            sink = int(np.flatnonzero(net.credit == 0)[0])
            for regime in m.REGIMES[:-1]:  # centralised has no trust arcs
                with self.subTest(seed=seed, regime=regime):
                    assert_feasible(self, net, st, m.route(net, st, sink, regime), [sink])
                    loan = m.route(net, st, sink, regime, demand=7)
                    if len(loan.src):
                        self.assertAlmostEqual(loan.value, 7)
                        assert_feasible(self, net, st, loan, [sink])

    def test_liability_shares(self):
        # holder 0 -> relay 1 -> borrower 2; holder 3 backs 2 directly
        net = line_network([(0, 1), (1, 2), (3, 2)], [100, 0, 0, 100], 25)
        flow = m.unbounded(net, m.State.fresh(net), 2)
        self.assertEqual(flow.value, 50)
        self.assertEqual(m.liability(net, flow, 2), {"relayed": 0.5, "remote": 0.5})
        direct = m.onehop(net, m.State.fresh(net), 2)
        self.assertEqual(m.liability(net, direct, 2), {"relayed": 0.0, "remote": 0.0})


class Sybils(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.c = 25
        cls.net = m.build_population("ws", 300, 6, 0.2, 100, cls.c, seed=11)

    def extraction(self, endpoints, sizes=(1, 10, 100, 1000)):
        out = []
        for size in sizes:
            net, sybils = m.attach_sybils(self.net, size, endpoints, self.c, np.random.default_rng(size))
            out.append(m.sybil_extraction(net, sybils))
        return out

    def test_extraction_independent_of_m_and_bounded_by_attack_edges(self):
        rng = np.random.default_rng(2)
        for g in (1, 5, 20):
            endpoints = rng.choice(self.net.n, g, replace=False)
            runs = self.extraction(endpoints)
            holders = int((self.net.credit[endpoints] > 0).sum())
            for regime in m.REGIMES + ("path-liable",):
                values = [r[regime] for r in runs]
                with self.subTest(g=g, regime=regime):
                    self.assertTrue(np.allclose(values, values[0]), values)
                    if regime != "centralised":
                        self.assertLessEqual(values[0], g * self.c + 1e-6)
            for r in runs:
                for regime in m.REGIMES:
                    self.assertAlmostEqual(r[regime], r[f"{regime} cut"], places=5)
                self.assertEqual(r["one-hop"], holders * self.c)
                self.assertEqual(r["path-liable"], r["one-hop"])
                self.assertEqual(r["centralised"], self.net.credit.sum())
                self.assertEqual(r["one-hop endpoint share"], 1.0)

    def test_endpoints_without_credit_are_worthless_only_in_one_hop(self):
        needy = np.flatnonzero(self.net.credit == 0)
        r = self.extraction(needy[:10], sizes=(5,))[0]
        self.assertEqual(r["one-hop"], 0)
        self.assertGreater(r["2-hop"], 0)
        self.assertEqual(r["unbounded endpoint share"], 0.0)  # charged entirely to holders that trusted no Sybil

    def test_endpoints_with_credit(self):
        holders = np.flatnonzero(self.net.credit > 0)
        r = self.extraction(holders[:10], sizes=(5,))[0]
        self.assertEqual(r["one-hop"], 10 * self.c)
        self.assertEqual(r["unbounded"], 10 * self.c)


class Simulation(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.net = m.build_population("ws", 300, 6, 0.2, 100, 25, seed=5)
        cls.needy = np.flatnonzero(cls.net.credit == 0)

    def test_instant_repayment_reproduces_the_static_values(self):
        rng = np.random.default_rng(1)
        who = rng.choice(self.needy, 150)
        ones = np.ones(len(who), dtype=np.int64)
        for regime in ("one-hop", "2-hop", "3-hop", "unbounded"):
            res = m.simulate(self.net, regime, who, ones, 50)
            expect = [m.route(self.net, m.State.fresh(self.net), int(b), regime).value >= 50 - 1e-6 for b in who]
            with self.subTest(regime=regime):
                np.testing.assert_array_equal(res.success, expect)

    def test_capacity_is_consumed_and_restored(self):
        rng = np.random.default_rng(3)
        who, durations = m.request_sequence(600, self.needy, 40, rng)
        total = self.net.credit.sum()
        for regime in m.REGIMES:
            res = m.simulate(self.net, regime, who, durations, 50)
            with self.subTest(regime=regime):
                self.assertTrue(np.all(res.open_principal >= -1e-6))
                self.assertTrue(np.all(res.open_principal <= total + 1e-6))
                self.assertGreater(res.success.sum(), 0)
                # open principal = granted loans not yet repaid
                for t in (100, 350, 599):
                    open_loans = sum(50 for s in range(t + 1) if res.success[s] and s + durations[s] > t)
                    self.assertAlmostEqual(res.open_principal[t], open_loans, places=5)

    def test_multi_hop_never_worse_on_first_request_and_one_hop_never_relays(self):
        rng = np.random.default_rng(4)
        who, durations = m.request_sequence(400, self.needy, 30, rng)
        one = m.simulate(self.net, "one-hop", who, durations, 50)
        self.assertFalse(one.routed.any())
        self.assertEqual(one.relayed.sum(), 0)
        self.assertEqual(one.remote.sum(), 0)
        np.testing.assert_allclose(one.mean_hops[one.success], 1.0)
        for regime in ("2-hop", "3-hop", "unbounded"):
            res = m.simulate(self.net, regime, who, durations, 50)
            self.assertGreaterEqual(res.success[0], one.success[0])
            self.assertTrue(np.all(res.relayed <= 50 + 1e-6))

    def test_deterministic(self):
        rng = np.random.default_rng(9)
        who, durations = m.request_sequence(300, self.needy, 30, rng)
        a = m.simulate(self.net, "3-hop", who, durations, 50)
        b = m.simulate(self.net, "3-hop", who, durations, 50)
        np.testing.assert_array_equal(a.success, b.success)
        np.testing.assert_array_equal(a.open_principal, b.open_principal)


class Graphs(unittest.TestCase):
    def test_mean_degree(self):
        for family, degree in itertools.product(m.FAMILIES, (4, 8, 12)):
            net = m.build_population(family, 1000, degree, 0.2, 100, 25, seed=degree)
            with self.subTest(family=family, degree=degree):
                self.assertAlmostEqual(net.arcs / net.n, degree, delta=0.08 * degree)

    def test_credit_assignment(self):
        net = m.build_population("ws", 1000, 8, 0.2, 100, 25, seed=1)
        self.assertEqual(int((net.credit > 0).sum()), 200)
        graph = m.make_graph("sbm", 1000, 8, 3)
        self.assertEqual(len(np.unique(m.community_of(graph))), 10)

    def test_concentrated_credit_stays_in_half_the_blocks(self):
        seed = 21
        net = m.build_population("sbm-concentrated", 1000, 8, 0.2, 100, 25, seed=seed)
        graph = m.make_graph("sbm-concentrated", 1000, 8, int(np.random.default_rng(seed).integers(2**31)))
        labels = m.community_of(graph)
        self.assertEqual(int((net.credit > 0).sum()), 200)
        self.assertTrue(np.all(labels[net.credit > 0] < 5))


if __name__ == "__main__":
    unittest.main()
