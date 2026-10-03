"""Liquidity of one-hop backing against multi-hop credit networks: the price of the one-hop rule.

The honest population is a social graph. A fraction q of nodes hold issued credit L; the rest hold
none. Each undirected edge {u, v} gives two arcs, u -> v and v -> u, of trust capacity c: u will
back v up to c, and the total a node backs can never exceed its credit. A borrower with no credit
can then borrow under one of these regimes:

    one-hop      only direct neighbours with credit back it, each up to min(c, their free credit).
                 This is the deployed rule (received backing cannot be passed on), with credit
                 committed when a loan draws on it rather than when backing is declared.
    2-hop, 3-hop a credit network (Karlan et al. 2009; Dandekar et al. 2011): the max-flow from
                 every credit holder to the borrower along paths of at most k arcs, with arc
                 capacity c and each holder's supply capped by its free credit.
    unbounded    the same with paths of any length.
    centralised  no trust constraint: any holder lends to anyone, so only total free credit counts.

Two more are used as checks:

    one-hop-static  the deployed commitment rule at a fresh state: each holder splits its credit
                    equally over its neighbours without credit before anyone borrows.
    path-liable     node splitting on every node, with throughput capped by the node's own free
                    credit: an intermediary may pass on only what it could pay for itself if the
                    borrower defaulted. This always equals one-hop (see `path_liable`).

Supply caps are node capacities on the supply side: a super-source S has an arc S -> v of
capacity free(v). That is node splitting of every holder into a supply node (capacity = its
credit) and a relay node (no capacity of its own).

One-hop, 2-hop (layered max-flow), unbounded and centralised keep flows integral when capacities
are integral. The 3-hop flow comes from a linear programme and may be fractional.
"""

from __future__ import annotations

import heapq
from dataclasses import dataclass, field

import networkx as nx
import numpy as np
from scipy.optimize import linprog
from scipy.sparse import coo_matrix, csr_matrix
from scipy.sparse.csgraph import breadth_first_order, maximum_flow

TOL = 1e-7
EPS_HOP = 1e-6  # cost per unit of arc flow in the k-hop LP: prefer short paths, never at the cost of value
REGIMES = ("one-hop", "2-hop", "3-hop", "unbounded", "centralised")
HOPS = {"one-hop": 1, "2-hop": 2, "3-hop": 3}
FAMILIES = ("ws", "ba", "sbm", "sbm-concentrated")
FAMILY_NAMES = {
    "ws": "Watts-Strogatz",
    "ba": "Barabasi-Albert",
    "sbm": "SBM, credit everywhere",
    "sbm-concentrated": "SBM, credit in half the blocks",
}


# ───────────────────────────── network and state ─────────────────────────────


@dataclass
class Network:
    """A directed trust network: arcs tail -> head of capacity cap, and issued credit per node."""

    n: int
    tail: np.ndarray
    head: np.ndarray
    cap: np.ndarray
    credit: np.ndarray
    in_ptr: np.ndarray = field(init=False, repr=False)
    in_arcs: np.ndarray = field(init=False, repr=False)

    def __post_init__(self):
        self.tail = np.asarray(self.tail, dtype=np.int64)
        self.head = np.asarray(self.head, dtype=np.int64)
        self.cap = np.asarray(self.cap, dtype=float)
        self.credit = np.asarray(self.credit, dtype=float)
        assert self.tail.shape == self.head.shape == self.cap.shape
        assert self.credit.shape == (self.n,)
        assert not np.any(self.tail == self.head), "no self-backing"
        order = np.argsort(self.head, kind="stable")
        self.in_arcs = order
        self.in_ptr = np.searchsorted(self.head[order], np.arange(self.n + 1))

    @property
    def arcs(self) -> int:
        return len(self.tail)

    def arcs_into(self, v: int) -> np.ndarray:
        return self.in_arcs[self.in_ptr[v] : self.in_ptr[v + 1]]

    @classmethod
    def from_graph(cls, graph: nx.Graph, credit: np.ndarray, c: float) -> Network:
        """Both arcs of every undirected edge get trust capacity c."""
        edges = np.array(list(graph.edges()), dtype=np.int64).reshape(-1, 2)
        tail = np.concatenate([edges[:, 0], edges[:, 1]])
        head = np.concatenate([edges[:, 1], edges[:, 0]])
        return cls(graph.number_of_nodes(), tail, head, np.full(len(tail), float(c)), credit)


@dataclass
class State:
    """Free credit per node and residual capacity per arc."""

    free: np.ndarray
    res: np.ndarray

    @classmethod
    def fresh(cls, net: Network) -> State:
        return cls(net.credit.copy(), net.cap.copy())

    def apply(self, flow: Flow, sign: int) -> None:
        """sign = -1 draws a loan's flow; +1 releases it on repayment."""
        np.add.at(self.free, flow.src, sign * flow.src_amount)
        np.add.at(self.res, flow.arcs, sign * flow.arc_amount)
        if sign < 0:
            assert self.free.min() > -1e-6 and self.res.min() > -1e-6, "capacity overdrawn"


@dataclass
class Flow:
    """A routed amount: what each source supplies and what each arc carries."""

    value: float
    src: np.ndarray
    src_amount: np.ndarray
    arcs: np.ndarray
    arc_amount: np.ndarray

    @classmethod
    def empty(cls, value: float = 0.0) -> Flow:
        """No allocation. `value` records what was available when a demand could not be met."""
        e = np.zeros(0, dtype=np.int64)
        return cls(value, e, np.zeros(0), e, np.zeros(0))

    @property
    def mean_hops(self) -> float:
        """Each unit of value crosses this many arcs on average (total arc flow / value)."""
        return float(self.arc_amount.sum() / self.value) if self.value > TOL else 0.0

    @property
    def updates(self) -> int:
        """Storage slots an on-chain router writes: one per source used and one per arc used."""
        return int(np.count_nonzero(self.src_amount > TOL) + np.count_nonzero(self.arc_amount > TOL))


def _mask(n: int, nodes) -> np.ndarray:
    m = np.zeros(n, dtype=bool)
    m[np.atleast_1d(nodes)] = True
    return m


def liability(net: Network, flow: Flow, sinks) -> dict[str, float]:
    """Who stands behind a flow into the sink set, as shares of its value.

    relayed   enters the sink set over an arc whose tail holds no issued credit: the account
              that chose to trust the borrower has nothing the protocol could charge.
    remote    is supplied by a holder with no arc into the sink set: the account whose credit is
              charged on default never chose the borrower.
    """
    if flow.value <= TOL:
        return {"relayed": 0.0, "remote": 0.0}
    sink_mask = _mask(net.n, sinks)
    into = sink_mask[net.head[flow.arcs]]
    relayed = flow.arc_amount[into & (net.credit[net.tail[flow.arcs]] <= 0)].sum()
    adjacent = np.zeros(net.n, dtype=bool)
    for s in np.atleast_1d(sinks):
        adjacent[net.tail[net.arcs_into(int(s))]] = True
    remote = flow.src_amount[~adjacent[flow.src]].sum()
    return {"relayed": float(relayed / flow.value), "remote": float(remote / flow.value)}


# ───────────────────────────── graphs and credit ─────────────────────────────


def make_graph(family: str, n: int, degree: int, seed: int, *, rewiring: float = 0.1,
               communities: int = 10, mixing: float = 0.1) -> nx.Graph:
    """Watts-Strogatz ("ws"), Barabasi-Albert ("ba") or a stochastic block model ("sbm*").

    Mean degree is `degree` in expectation for all three: WS uses k = degree (even), BA attaches
    m = degree / 2 edges per node (mean 2m less a vanishing correction), and the SBM has
    `communities` equal blocks with a share `mixing` of each node's expected degree going to other
    blocks. The SBM keeps its partition in graph.graph["partition"].
    """
    if family == "ws":
        if degree % 2:
            raise ValueError("Watts-Strogatz needs an even degree")
        return nx.watts_strogatz_graph(n, degree, rewiring, seed=seed)
    if family == "ba":
        return nx.barabasi_albert_graph(n, max(1, degree // 2), seed=seed)
    if family in ("sbm", "sbm-concentrated"):
        size = n // communities
        sizes = [size] * communities
        sizes[-1] += n - size * communities
        p_in = degree * (1 - mixing) / (size - 1)
        p_out = degree * mixing / (n - size)
        probs = [[p_in if i == j else p_out for j in range(communities)] for i in range(communities)]
        return nx.stochastic_block_model(sizes, probs, seed=seed)
    raise ValueError(family)


def community_of(graph: nx.Graph) -> np.ndarray | None:
    if "partition" not in graph.graph:
        return None
    labels = np.zeros(graph.number_of_nodes(), dtype=np.int64)
    for i, block in enumerate(graph.graph["partition"]):
        labels[list(block)] = i
    return labels


def assign_credit(n: int, q: float, line: float, rng: np.random.Generator, *,
                  eligible: np.ndarray | None = None) -> np.ndarray:
    """round(q n) holders with credit `line`, drawn uniformly from `eligible` (default: everyone).

    Holders are a prefix of one random permutation, so with the same generator state a larger q
    keeps every holder of a smaller one. If fewer nodes are eligible than round(q n), all of them
    hold credit.
    """
    pool = np.arange(n) if eligible is None else np.flatnonzero(eligible)
    holders = rng.permutation(pool)[: min(len(pool), int(round(q * n)))]
    credit = np.zeros(n)
    credit[holders] = line
    return credit


def build_population(family: str, n: int, degree: int, q: float, line: float, c: float, seed: int,
                     *, rewiring: float = 0.1, credit_seed: int | None = None) -> Network:
    """A graph from `seed` and a credit assignment from `credit_seed` (default: the same stream).
    With a fixed credit_seed the holder sets are nested in q. "sbm-concentrated" gives credit only
    to nodes of the first half of the blocks, so half the communities hold none."""
    rng = np.random.default_rng(seed)
    graph = make_graph(family, n, degree, int(rng.integers(2**31)), rewiring=rewiring)
    if credit_seed is not None:
        rng = np.random.default_rng(credit_seed)
    eligible = None
    if family == "sbm-concentrated":
        labels = community_of(graph)
        eligible = labels < labels.max() / 2
    credit = assign_credit(n, q, line, rng, eligible=eligible)
    return Network.from_graph(graph, credit, c)


# ───────────────────────────── max-flow helpers ─────────────────────────────


def _int_capacity(values: np.ndarray) -> np.ndarray:
    rounded = np.round(values)
    assert np.allclose(values, rounded, atol=1e-6), "integer max-flow needs integral capacities"
    return rounded.astype(np.int64)


def _maxflow(rows, cols, caps, nodes: int, s: int, t: int):
    """Integer max-flow (scipy, Dinic). Returns (value, input graph, flow matrix)."""
    caps = _int_capacity(np.asarray(caps, dtype=float))
    assert caps.max(initial=0) < 2**31, "capacities must fit int32"
    graph = csr_matrix((caps.astype(np.int32), (rows, cols)), shape=(nodes, nodes))
    graph.sum_duplicates()
    result = maximum_flow(graph, s, t)
    return float(result.flow_value), graph, result.flow


def _flow_at(flow: csr_matrix, rows: np.ndarray, cols: np.ndarray) -> np.ndarray:
    """Flow on the given (row, col) pairs, as floats (net flow, so it can be negative)."""
    if len(rows) == 0:
        return np.zeros(0)
    return np.asarray(flow[rows, cols]).ravel().astype(float)


def _source_side(graph: csr_matrix, flow: csr_matrix, s: int) -> np.ndarray:
    """Nodes reachable from s in the residual graph: the source side of a minimum cut."""
    residual = (graph - flow).tocsr()
    residual.data = (residual.data > 0).astype(np.int8)
    residual.eliminate_zeros()
    reach = breadth_first_order(residual, s, directed=True, return_predecessors=False)
    side = np.zeros(graph.shape[0], dtype=bool)
    side[reach] = True
    return side


def _cut_capacity(graph: csr_matrix, side: np.ndarray) -> float:
    """Capacity of the arcs from the source side to the sink side, computed from the graph alone."""
    coo = graph.tocoo()
    crossing = side[coo.row] & ~side[coo.col]
    return float(coo.data[crossing].sum())


# ───────────────────────────── routers ─────────────────────────────


def _prorata(avail: np.ndarray, amount: float) -> np.ndarray:
    """Split `amount` over `avail` pro rata, in whole units when everything is integral."""
    total = avail.sum()
    raw = avail * (amount / total)
    if not (float(amount).is_integer() and np.all(avail == np.round(avail))):
        return np.minimum(raw, avail)
    take = np.floor(raw + 1e-9)
    left = int(round(amount - take.sum()))
    for i in np.argsort(-(raw - take), kind="stable"):
        if left == 0:
            break
        if take[i] < avail[i]:
            take[i] += 1
            left -= 1
    assert left == 0
    return take


def onehop(net: Network, state: State, sinks, demand: float | None = None) -> Flow:
    """Direct backing only: each holder u gives at most min(free(u), sum of its arcs into sinks).

    With a single sink this is the sum over neighbours of min(c, free credit). A demand is drawn
    pro rata over the backers, as `_chargeBackers` charges them.
    """
    sinks = np.atleast_1d(sinks)
    arcs = np.concatenate([net.arcs_into(int(s)) for s in sinks])
    sink_mask = _mask(net.n, sinks)
    arcs = arcs[~sink_mask[net.tail[arcs]] & (state.res[arcs] > TOL) & (state.free[net.tail[arcs]] > TOL)]
    if len(arcs) == 0:
        return Flow.empty()
    tails = net.tail[arcs]
    if len(sinks) == 1:  # one arc per backer
        avail = np.minimum(state.res[arcs], state.free[tails])
    else:  # a backer with several arcs into the sink set is still capped by its free credit
        per_backer = np.bincount(tails, weights=state.res[arcs], minlength=net.n)
        scale = np.minimum(1.0, state.free / np.maximum(per_backer, TOL))
        avail = state.res[arcs] * scale[tails]
    value = float(avail.sum())
    if demand is not None:
        if value < demand - TOL:
            return Flow.empty(value)
        avail = _prorata(avail, demand)
        value = float(demand)
    used = avail > 0
    src_amount = np.bincount(tails[used], weights=avail[used], minlength=net.n)
    src = np.flatnonzero(src_amount > 0)
    return Flow(value, src, src_amount[src], arcs[used], avail[used])


def onehop_cut(net: Network, state: State, sinks) -> float:
    """Minimum cut of the one-hop network (holders -> sinks): each holder adjacent to the sink set
    contributes min(free credit, its residual arc capacity into the set)."""
    sinks = np.atleast_1d(sinks)
    sink_mask = _mask(net.n, sinks)
    arcs = np.concatenate([net.arcs_into(int(s)) for s in sinks])
    arcs = arcs[~sink_mask[net.tail[arcs]]]
    into = np.bincount(net.tail[arcs], weights=state.res[arcs], minlength=net.n)
    return float(np.minimum(into, np.maximum(state.free, 0)).sum())


def onehop_static(net: Network, borrower: int) -> float:
    """The deployed commitment rule at a fresh state: every holder commits its credit before anyone
    borrows, split equally over its neighbours without credit, each share capped at c."""
    arcs = net.arcs_into(borrower)
    tails = net.tail[arcs]
    holder = net.credit[tails] > 0
    if not holder.any():
        return 0.0
    needy = np.bincount(net.tail, weights=(net.credit[net.head] <= 0).astype(float), minlength=net.n)
    share = net.credit[tails[holder]] / np.maximum(needy[tails[holder]], 1)
    return float(np.minimum(net.cap[arcs[holder]], share).sum())


def _bfs_layers(n: int, tail: np.ndarray, head: np.ndarray, start: np.ndarray, depth: int,
                *, reverse: bool) -> np.ndarray:
    """Hop distance from the `start` set (or to it, when reverse), up to `depth`; inf beyond."""
    dist = np.full(n, np.inf)
    dist[start] = 0
    if depth == 0 or len(tail) == 0:
        return dist
    src, dst = (head, tail) if reverse else (tail, head)
    adj = csr_matrix((np.ones(len(src)), (dst, src)), shape=(n, n))  # adj @ x: sum over arcs src -> dst
    frontier = start.astype(float)
    for d in range(1, depth + 1):
        frontier = (adj @ frontier > 0).astype(float)
        new = (frontier > 0) & np.isinf(dist)
        dist[new] = d
        if not new.any():
            break
    return dist


def twohop(net: Network, state: State, sinks, demand: float | None = None, *,
           with_cut: bool = False):
    """Exact 2-hop max-flow as a plain max-flow on a layered network (integral).

    Nodes: a supply node w_s per holder (S -> w_s of capacity free(w)) and a relay node r_u per
    node u with an arc into the sink set. Arcs: w_s -> r_u for every arc w -> u (capacity res),
    u_s -> r_u uncapped when u is itself a holder, r_u -> sink for every arc u -> sink. Every arc
    of the trust network appears at most once, and the s-t paths are exactly the supply-capped
    paths of one or two arcs, so the max-flow equals the length-bounded flow (tested against the
    LP). With `with_cut`, also returns the capacity of a minimum cut of this network.
    """
    n = net.n
    sinks = np.atleast_1d(sinks)
    sink_mask = _mask(n, sinks)
    usable = (state.res > TOL) & ~sink_mask[net.tail]
    last = np.flatnonzero(usable & sink_mask[net.head])  # arcs u -> sink
    relay = np.zeros(n, dtype=bool)
    relay[net.tail[last]] = True
    holder = (state.free > TOL) & ~sink_mask
    first = np.flatnonzero(usable & relay[net.head] & holder[net.tail])  # arcs w -> u, u a relay
    sup = np.flatnonzero(holder & (relay | np.isin(np.arange(n), net.tail[first])))
    s_node, t_node = 3 * n, 3 * n + 1
    big = int(round(state.free[sup].sum())) + 1
    sink_cap = np.full(len(sinks), big)
    if demand is not None:
        if len(sinks) != 1:
            raise ValueError("a demand needs a single sink")
        sink_cap[:] = int(round(demand))
    direct = sup[relay[sup]]
    rows = np.concatenate([np.full(len(sup), s_node), net.tail[first], direct, n + net.tail[last],
                           2 * n + sinks])
    cols = np.concatenate([sup, n + net.head[first], n + direct, 2 * n + net.head[last],
                           np.full(len(sinks), t_node)])
    caps = np.concatenate([state.free[sup], state.res[first], np.full(len(direct), big),
                           state.res[last], sink_cap])
    if len(rows) == 0 or len(sup) == 0:
        return (Flow.empty(), 0.0) if with_cut else Flow.empty()
    value, graph, fl = _maxflow(rows, cols, caps, 3 * n + 2, s_node, t_node)
    if with_cut:
        cut = _cut_capacity(graph, _source_side(graph, fl, s_node))
    if demand is not None and value < demand - TOL:
        return (Flow.empty(value), cut) if with_cut else Flow.empty(value)
    a1 = np.maximum(_flow_at(fl, net.tail[first], n + net.head[first]), 0)
    a2 = np.maximum(_flow_at(fl, n + net.tail[last], 2 * n + net.head[last]), 0)
    s_amt = _flow_at(fl, np.full(len(sup), s_node), sup)
    arcs = np.concatenate([first, last])
    amounts = np.concatenate([a1, a2])
    arc_amount = np.bincount(arcs, weights=amounts, minlength=net.arcs)
    used = np.flatnonzero(arc_amount > 0)
    flow = Flow(value, sup[s_amt > 0], s_amt[s_amt > 0], used, arc_amount[used])
    return (flow, cut) if with_cut else flow


def _in_arcs_of(net: Network, nodes: np.ndarray) -> np.ndarray:
    """All arcs into any of `nodes` (vectorised gather over the in-arc index)."""
    nodes = np.asarray(nodes, dtype=np.int64)
    starts = net.in_ptr[nodes]
    counts = net.in_ptr[nodes + 1] - starts
    if counts.sum() == 0:
        return np.zeros(0, dtype=np.int64)
    shift = np.repeat(starts - np.concatenate([[0], np.cumsum(counts)[:-1]]), counts)
    return net.in_arcs[np.arange(counts.sum()) + shift]


def _khop_lp(net: Network, state: State, sinks, k: int, demand: float | None, eps: float):
    """The length-bounded flow LP. Returns None when no path of at most k arcs exists."""
    n = net.n
    sinks = np.unique(np.atleast_1d(sinks))
    sink_mask = _mask(n, sinks)
    usable = (state.res > TOL) & ~sink_mask[net.tail]  # flow stops at the first sink it reaches
    # hops to the sink set (reverse BFS over usable arcs, k - 1 layers, local to the sinks)
    dt = np.full(n, np.inf)
    dt[sinks] = 0
    frontier = sinks
    for d in range(1, k):
        a = _in_arcs_of(net, frontier)
        tails = np.unique(net.tail[a[usable[a]]])
        frontier = tails[np.isinf(dt[tails])]
        dt[frontier] = d
        if len(frontier) == 0:
            break
    arc_ids = np.sort(_in_arcs_of(net, np.flatnonzero(dt <= k - 1)))
    arc_ids = arc_ids[usable[arc_ids]]
    t, h = net.tail[arc_ids], net.head[arc_ids]
    source = (state.free > TOL) & ~sink_mask
    ds = _bfs_layers(n, t, h, source, k - 1, reverse=False)  # hops from a source

    var_arc, var_pos = [], []
    for i in range(1, k + 1):
        ok = (ds[t] <= i - 1) & (dt[h] <= k - i)
        var_arc.append(np.flatnonzero(ok))
        var_pos.append(np.full(ok.sum(), i))
    va = np.concatenate(var_arc)  # index into arc_ids
    vp = np.concatenate(var_pos)
    nf = len(va)
    if nf == 0:
        return None
    vt, vh = t[va], h[va]
    into_sink = sink_mask[vh]

    src_nodes = np.unique(vt[vp == 1])
    src_nodes = src_nodes[source[src_nodes]]
    ns = len(src_nodes)

    # conservation rows: state (v, j) = "at v after j arcs", for non-sinks and j < k
    out_key = vt * k + (vp - 1)
    in_ok = ~into_sink & (vp < k)
    in_key = vh[in_ok] * k + vp[in_ok]
    src_key = src_nodes * k
    keys, inv = np.unique(np.concatenate([out_key, in_key, src_key]), return_inverse=True)
    rows_out = inv[:nf]
    rows_in = inv[nf : nf + len(in_key)]
    rows_src = inv[nf + len(in_key) :]
    eq = coo_matrix(
        (
            np.concatenate([-np.ones(nf), np.ones(len(rows_in)), np.ones(ns)]),
            (np.concatenate([rows_out, rows_in, rows_src]),
             np.concatenate([np.arange(nf), np.flatnonzero(in_ok), nf + np.arange(ns)])),
        ),
        shape=(len(keys), nf + ns),
    ).tocsr()

    # bundle rows for arcs used at more than one position; single-position arcs get a bound
    counts = np.bincount(va, minlength=len(arc_ids))
    multi = counts[va] > 1
    bundle_arcs, bundle_row = np.unique(va[multi], return_inverse=True)
    ub_rows = [bundle_row]
    ub_cols = [np.flatnonzero(multi)]
    ub_vals = [np.ones(multi.sum())]
    b_ub = [state.res[arc_ids[bundle_arcs]]]
    nrows = len(bundle_arcs)
    if demand is not None:
        ub_rows.append(np.full(into_sink.sum(), nrows))
        ub_cols.append(np.flatnonzero(into_sink))
        ub_vals.append(np.ones(into_sink.sum()))
        b_ub.append([demand])
        nrows += 1
    a_ub = None
    if nrows:
        a_ub = coo_matrix(
            (np.concatenate(ub_vals), (np.concatenate(ub_rows), np.concatenate(ub_cols))),
            shape=(nrows, nf + ns),
        ).tocsr()
        b_ub = np.concatenate([np.atleast_1d(np.asarray(b, dtype=float)) for b in b_ub])
    else:
        b_ub = None

    cost = np.concatenate([np.full(nf, eps) - into_sink.astype(float), np.zeros(ns)])
    upper = np.concatenate([state.res[arc_ids[va]], state.free[src_nodes]])
    bounds = np.column_stack([np.zeros(nf + ns), upper])
    sol = linprog(cost, A_ub=a_ub, b_ub=b_ub, A_eq=eq, b_eq=np.zeros(eq.shape[0]), bounds=bounds,
                  method="highs")
    if sol.status != 0:
        raise RuntimeError(f"k-hop LP failed: {sol.message}")
    return sol, arc_ids, va, nf, into_sink, src_nodes, b_ub, upper


def khop(net: Network, state: State, sinks, k: int, demand: float | None = None) -> Flow:
    """Max-flow from holders to the sink set along paths of at most k arcs (exact, fractional).

    Length-bounded flow is not a plain max-flow: an arc can sit at different positions of
    different paths and its capacity is shared between them. The LP below has one variable per
    (arc, position from the source) and a bundle constraint per arc: the time-expanded network
    of length-bounded flows. A walk it carries can always be shortened to a simple path of fewer
    arcs, so its value is the path-formulation optimum (tested against explicit path
    enumeration). A cost EPS_HOP per unit of arc flow makes it prefer short paths and rules out
    idle cycles; it never trades away value.
    """
    if k == 1:
        return onehop(net, state, sinks, demand)
    out = _khop_lp(net, state, sinks, k, demand, EPS_HOP)
    if out is None:
        return Flow.empty()
    sol, arc_ids, va, nf, into_sink, src_nodes, _, _ = out
    x = np.clip(sol.x, 0, None)
    x[x < 1e-9] = 0
    f, s = x[:nf], x[nf:]
    value = float(f[into_sink].sum())
    if demand is not None and value < demand - 1e-6:
        return Flow.empty(value)
    arc_amount = np.bincount(va, weights=f, minlength=len(arc_ids))
    used = arc_amount > 0
    src_used = s > 0
    return Flow(value, src_nodes[src_used], s[src_used], arc_ids[used], arc_amount[used])


def khop_dual(net: Network, state: State, sinks, k: int) -> tuple[float, float]:
    """(k-hop max-flow value, value of the LP dual): a fractional length-bounded cut.

    Solved without the hop cost, so the optimum is minus the flow value. By LP duality the dual
    objective, rebuilt here from the marginals and the capacities, equals it.
    """
    out = _khop_lp(net, state, sinks, k, None, 0.0)
    if out is None:
        return 0.0, 0.0
    sol, _, _, nf, into_sink, _, b_ub, upper = out
    value = float(np.clip(sol.x[:nf], 0, None)[into_sink].sum())
    dual = float(upper @ sol.upper.marginals)
    if b_ub is not None:
        dual += float(b_ub @ sol.ineqlin.marginals)
    return value, -dual


def unbounded(net: Network, state: State, sinks, demand: float | None = None) -> Flow:
    """Max-flow from holders to the sink set over paths of any length (scipy, Dinic).

    Dinic augments along shortest paths first, so short routes are used before long ones.
    """
    n = net.n
    sinks = np.atleast_1d(sinks)
    sink_mask = _mask(n, sinks)
    s_node, t_node = n, n + 1
    arcs = np.flatnonzero((state.res > TOL) & ~sink_mask[net.tail])
    src = np.flatnonzero((state.free > TOL) & ~sink_mask)
    if len(src) == 0:
        return Flow.empty()
    big = int(round(state.free[src].sum())) + 1
    sink_cap = np.full(len(sinks), big)
    if demand is not None:
        if len(sinks) != 1:
            raise ValueError("a demand needs a single sink")
        sink_cap[:] = int(round(demand))
    rows = np.concatenate([net.tail[arcs], np.full(len(src), s_node), sinks])
    cols = np.concatenate([net.head[arcs], src, np.full(len(sinks), t_node)])
    caps = np.concatenate([state.res[arcs], state.free[src], sink_cap])
    value, _, fl = _maxflow(rows, cols, caps, n + 2, s_node, t_node)
    if demand is not None and value < demand - TOL:
        return Flow.empty(value)
    arc_amount = np.maximum(_flow_at(fl, net.tail[arcs], net.head[arcs]), 0)
    src_amount = _flow_at(fl, np.full(len(src), s_node), src)
    used, sused = arc_amount > 0, src_amount > 0
    return Flow(value, src[sused], src_amount[sused], arcs[used], arc_amount[used])


def min_cut(net: Network, state: State, sinks) -> tuple[float, float, np.ndarray]:
    """Unbounded max-flow into the sink set, the capacity of a minimum cut, and its source side.

    The cut is read off the residual graph and its capacity summed from the network's own
    capacities (supply arcs S -> v of sink-side holders, trust arcs from the source side to the
    sink side), independently of the flow value.
    """
    n = net.n
    sinks = np.atleast_1d(sinks)
    sink_mask = _mask(n, sinks)
    s_node, t_node = n, n + 1
    arcs = np.flatnonzero((state.res > TOL) & ~sink_mask[net.tail])
    src = np.flatnonzero((state.free > TOL) & ~sink_mask)
    big = int(round(state.free[src].sum())) + 1
    rows = np.concatenate([net.tail[arcs], np.full(len(src), s_node), sinks])
    cols = np.concatenate([net.head[arcs], src, np.full(len(sinks), t_node)])
    caps = np.concatenate([state.res[arcs], state.free[src], np.full(len(sinks), big)])
    value, graph, fl = _maxflow(rows, cols, caps, n + 2, s_node, t_node)
    side = _source_side(graph, fl, s_node)
    assert not side[t_node]
    cut = state.free[src][~side[src]].sum()
    crossing = side[net.tail[arcs]] & ~side[net.head[arcs]]
    cut += state.res[arcs][crossing].sum()
    return value, float(cut), side[:n]


def path_liable(net: Network, state: State, sinks) -> float:
    """Unbounded max-flow when every node's throughput is capped by its own free credit.

    Node splitting: v_in -> v_out with capacity free(v); the supply S -> v_in; arcs u_out -> v_in;
    sinks absorb at v_in. This is what a default paid along the path needs on-chain (Karlan et al.
    2009: each intermediary compensates the one before it, so the borrower's direct neighbour
    finally pays): every node must be able to pay, out of its own credit, all it passes on.

    It always equals `onehop` at a single sink: the flow into the borrower over arc u -> b is at
    most c and at most u's throughput, free(u), and u can send min(c, free(u)) directly. So the
    last hop of any flow is a valid one-hop allocation (tested on random networks).
    """
    n = net.n
    sinks = np.atleast_1d(sinks)
    sink_mask = _mask(n, sinks)
    s_node, t_node = 2 * n, 2 * n + 1
    arcs = np.flatnonzero((state.res > TOL) & ~sink_mask[net.tail])
    holders = np.flatnonzero((state.free > TOL) & ~sink_mask)
    if len(holders) == 0:
        return 0.0
    big = int(round(state.free[holders].sum())) + 1
    rows = np.concatenate([holders, net.tail[arcs] + n, np.full(len(holders), s_node), sinks])
    cols = np.concatenate([holders + n, net.head[arcs], holders, np.full(len(sinks), t_node)])
    caps = np.concatenate([state.free[holders], state.res[arcs], state.free[holders],
                           np.full(len(sinks), big)])
    value, _, _ = _maxflow(rows, cols, caps, 2 * n + 2, s_node, t_node)
    return value


def centralised(net: Network, state: State, sinks, demand: float | None = None) -> Flow:
    """No trust constraint: the borrower draws on all free credit, pro rata."""
    sink_mask = _mask(net.n, sinks)
    src = np.flatnonzero((state.free > TOL) & ~sink_mask)
    avail = state.free[src]
    value = float(avail.sum())
    if demand is None:
        return Flow(value, src, avail.copy(), np.zeros(0, np.int64), np.zeros(0))
    if value < demand - TOL:
        return Flow.empty(value)
    take = _prorata(avail, demand)
    used = take > 0
    return Flow(float(demand), src[used], take[used], np.zeros(0, np.int64), np.zeros(0))


def route(net: Network, state: State, sinks, regime: str, demand: float | None = None) -> Flow:
    if regime == "one-hop":
        return onehop(net, state, sinks, demand)
    if regime == "2-hop":
        if demand is None:
            return twohop(net, state, sinks)
        return khop(net, state, sinks, 2, demand)  # the LP prefers direct arcs when routing a loan
    if regime == "3-hop":
        return khop(net, state, sinks, 3, demand)
    if regime == "unbounded":
        return unbounded(net, state, sinks, demand)
    if regime == "centralised":
        return centralised(net, state, sinks, demand)
    raise ValueError(regime)


def max_borrowable(net: Network, state: State, sinks, regime: str) -> float:
    return route(net, state, sinks, regime).value


def static_values(net: Network, borrower: int) -> dict[str, float]:
    """Maximum borrowable amount of one borrower at a fresh state, under every regime.

    3-hop is solved only when 2-hop falls short of unbounded (otherwise all three are equal).
    """
    state = State.fresh(net)
    out = {"one-hop": onehop(net, state, borrower).value, "one-hop-static": onehop_static(net, borrower)}
    out["2-hop"] = twohop(net, state, borrower).value
    out["unbounded"] = unbounded(net, state, borrower).value
    if out["2-hop"] >= out["unbounded"] - 1e-6:
        out["3-hop"] = out["unbounded"]
    else:
        out["3-hop"] = khop(net, state, borrower, 3).value
    out["centralised"] = centralised(net, state, borrower).value
    return out


# ───────────────────────────── repeated transactions ─────────────────────────────


@dataclass
class SimResult:
    success: np.ndarray  # per request
    routed: np.ndarray  # per request: granted over a path longer than one arc was needed
    mean_hops: np.ndarray  # per request (nan when it failed)
    updates: np.ndarray  # per request (0 when it failed)
    relayed: np.ndarray  # per request: amount entering the borrower from an account with no credit
    remote: np.ndarray  # per request: amount supplied by holders not adjacent to the borrower
    open_principal: np.ndarray  # credit drawn by open loans, after each request


def simulate(net: Network, regime: str, borrowers: np.ndarray, durations: np.ndarray,
             amount: float) -> SimResult:
    """One request per step: borrower b_t asks for `amount`; a granted loan is repaid after
    durations[t] steps, which releases what it drew. A multi-hop regime first tries direct
    backers (pro rata, as one-hop does) and routes over longer paths only when they fall short.
    The request sequence and durations are common to all regimes (common random numbers).
    """
    state = State.fresh(net)
    expiries: list[tuple[int, int, Flow]] = []
    steps = len(borrowers)
    success = np.zeros(steps, dtype=bool)
    routed = np.zeros(steps, dtype=bool)
    hops = np.full(steps, np.nan)
    updates = np.zeros(steps, dtype=np.int64)
    relayed = np.zeros(steps)
    remote = np.zeros(steps)
    drawn = np.zeros(steps)
    outstanding = 0.0
    multi = regime in ("2-hop", "3-hop", "unbounded")
    for step in range(steps):
        while expiries and expiries[0][0] <= step:
            _, _, loan = heapq.heappop(expiries)
            state.apply(loan, +1)
            outstanding -= loan.value
        b = int(borrowers[step])
        flow = None
        if multi:
            direct = onehop(net, state, b, amount)
            if direct.value >= amount - TOL and len(direct.src):
                flow = direct
            elif state.res[net.arcs_into(b)].sum() >= amount - TOL:  # the in-cut can carry it
                flow = route(net, state, b, regime, amount)
                routed[step] = flow.value >= amount - 1e-6 and len(flow.src) > 0
        else:
            flow = route(net, state, b, regime, amount)
        if flow is not None and flow.value >= amount - 1e-6 and len(flow.src):
            state.apply(flow, -1)
            heapq.heappush(expiries, (step + int(durations[step]), step, flow))
            outstanding += flow.value
            success[step] = True
            if regime != "centralised":
                hops[step] = flow.mean_hops
                updates[step] = flow.updates
                share = liability(net, flow, b)
                relayed[step] = share["relayed"] * flow.value
                remote[step] = share["remote"] * flow.value
        drawn[step] = outstanding
    return SimResult(success, routed, hops, updates, relayed, remote, drawn)


def request_sequence(n_requests: int, borrowers: np.ndarray, mean_duration: float,
                     rng: np.random.Generator) -> tuple[np.ndarray, np.ndarray]:
    """Uniform borrowers without credit; geometric durations (each open loan is repaid in each
    step with probability 1/mean_duration)."""
    who = rng.choice(borrowers, size=n_requests)
    durations = rng.geometric(1.0 / mean_duration, size=n_requests)
    return who, durations


# ───────────────────────────── Sybil region ─────────────────────────────


def attach_sybils(net: Network, m: int, endpoints: np.ndarray, c: float, rng: np.random.Generator,
                  *, sybil_degree: int = 8, sybil_trust: float = 1e6) -> tuple[Network, np.ndarray]:
    """Add m Sybils with no credit. Attack edge i: honest endpoints[i] backs Sybil i mod m up to c
    (and the Sybil backs it back, which carries nothing since Sybils hold no credit). Sybils trust
    each other without limit along a random regular graph of degree about `sybil_degree`.
    """
    endpoints = np.asarray(endpoints, dtype=np.int64)
    assert len(np.unique(endpoints)) == len(endpoints), "one attack edge per honest endpoint"
    sybils = net.n + np.arange(m)
    target = sybils[np.arange(len(endpoints)) % m]
    tails = [net.tail, endpoints, target]
    heads = [net.head, target, endpoints]
    caps = [net.cap, np.full(len(endpoints), float(c)), np.full(len(endpoints), float(c))]
    if m > 1:
        d = min(sybil_degree, m - 1)
        if (d * m) % 2:
            d -= 1
        inner = nx.random_regular_graph(d, m, seed=int(rng.integers(2**31)))
        e = np.array(list(inner.edges()), dtype=np.int64).reshape(-1, 2) + net.n
        tails += [e[:, 0], e[:, 1]]
        heads += [e[:, 1], e[:, 0]]
        caps += [np.full(len(e), sybil_trust)] * 2
    credit = np.concatenate([net.credit, np.zeros(m)])
    return Network(net.n + m, np.concatenate(tails), np.concatenate(heads), np.concatenate(caps), credit), sybils


def sybil_extraction(net: Network, sybils: np.ndarray) -> dict[str, float]:
    """The most the attacker can draw into its Sybils from a fresh state, under each regime, the
    minimum cut of the network each regime routes over, and who would be charged.

    `<regime>` is the extraction, `<regime> cut` the cut: one-hop's bipartite cut, the 2-hop
    layered network's min-cut, the 3-hop LP dual (a fractional length-bounded cut), the
    unbounded min-cut and, for centralised, total free credit (the supply arcs).
    `<regime> endpoint share` is the share charged to holders that trusted a Sybil directly.
    """
    state = State.fresh(net)
    out: dict[str, float] = {}
    flows = {
        "one-hop": onehop(net, state, sybils),
        "unbounded": unbounded(net, state, sybils),
        "centralised": centralised(net, state, sybils),
    }
    flows["2-hop"], out["2-hop cut"] = twohop(net, state, sybils, with_cut=True)
    flows["3-hop"] = khop(net, state, sybils, 3)
    out["one-hop cut"] = onehop_cut(net, state, sybils)
    value3, out["3-hop cut"] = khop_dual(net, state, sybils, 3)
    assert abs(value3 - flows["3-hop"].value) < 1e-6
    value, out["unbounded cut"], _ = min_cut(net, state, sybils)
    assert abs(value - flows["unbounded"].value) < 1e-6
    out["centralised cut"] = float(state.free[state.free > TOL].sum())
    for regime, flow in flows.items():
        out[regime] = flow.value
        out[f"{regime} endpoint share"] = 1.0 - liability(net, flow, sybils)["remote"] if flow.value > 0 else 1.0
    out["path-liable"] = path_liable(net, state, sybils)
    return out
