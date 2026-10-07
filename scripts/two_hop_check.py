#!/usr/bin/env python3
"""Two-hop conservation check for the microcredit pool (read-only).

Credit is conserved: when A backs B, B's limit rises by what A's free capacity falls by, and B
cannot pass that backing on to C. This script reads the pool over JSON-RPC and checks exactly
that around one `back` transaction that you send yourself. It holds no key and sends no
transaction; the negative controls are `eth_call` simulations. Standard library only.

Flow (the amount is in USDC, six decimals on chain):

    # 1. before anything is sent
    two_hop_check.py snapshot --rpc URL --pool POOL --a A --b B --c C --out before.json
    two_hop_check.py controls --rpc URL --pool POOL --a A --b B --c C --stage before

    # 2. you send:  A calls back(B, amount)   (grant route: A holds an issued line;
    #               stake route: A first stake()s, and holds no free granted credit)

    # 3. after
    two_hop_check.py snapshot --rpc URL --pool POOL --a A --b B --c C --out after.json
    two_hop_check.py controls --rpc URL --pool POOL --a A --b B --c C --stage after
    two_hop_check.py verify --before before.json --after after.json --amount 2 --route grant

Exit status is 0 only when every check passed. A check that cannot apply (for example B already
holds credit of its own, so the pass-on control proves nothing) is reported as NOT APPLICABLE and
does not fail the run, but it is printed so the receipt says so.

What `verify` checks (A backs B with x):
  1. A's free capacity (free granted credit plus free stake) fell by exactly x.
  2. B's borrow limit rose by x. It may rise by less when A's cover is short, never by more.
  3. Conservation: limit(A) + limit(B) + free stake(A, B) after is at most the same before, and
     equal when neither side owes anything.
  4. A's granted credit and stake are unchanged: backing moves capacity, it creates none.
  5. The edge A to B holds x, as secured (stake route) or unsecured (grant route).
  6. B holds no free credit or free stake it did not hold before.
What `controls` simulates (eth_call, nothing is sent):
  - B, holding only received backing, cannot back C (`InsufficientCredit`).
  - A cannot raise its backing of B above what it holds free (`InsufficientCredit`).
"""

import argparse
import json
import sys
import urllib.request
from decimal import Decimal

USDC = 10**6
MIN_BACKING = USDC  # the pool's MIN_BACKING

SEL = {
    "grantedCredit": "0x0d258839",
    "creditCommitted": "0x9faf967e",
    "stakeCommitted": "0xef9711ca",
    "stakeOf": "0x42623360",
    "duesPaid": "0xce6b6c41",
    "creditLoss": "0x70e6d84c",
    "getBorrowLimit": "0x7c17d237",
    "getFreeCredit": "0xec1e5d13",
    "getBacking": "0x4c00acbb",
    "scoreProvider": "0xc9dd0c93",
    "getCreditScore": "0xd3dd2bdf",
    "scoreOverrides": "0xf75a3e23",
    "defaultedLoans": "0x34ca3573",
    "back": "0xb870f613",
    "isFresh": "0x6268ceaa",
    "lastReportAt": "0x92dc7b7b",
    "maxScoreAge": "0xc82bfbb7",
}
INSUFFICIENT_CREDIT = "0x8ac4bc73"

SIGNATURES = {
    "grantedCredit": "grantedCredit(address)",
    "creditCommitted": "creditCommitted(address)",
    "stakeCommitted": "stakeCommitted(address)",
    "stakeOf": "stakeOf(address)",
    "duesPaid": "duesPaid(address)",
    "creditLoss": "creditLoss(address)",
    "getBorrowLimit": "getBorrowLimit(address)",
    "getFreeCredit": "getFreeCredit(address)",
    "getBacking": "getBacking(address,address)",
    "scoreProvider": "scoreProvider()",
    "getCreditScore": "getCreditScore(address)",
    "scoreOverrides": "scoreOverrides(address)",
    "defaultedLoans": "defaultedLoans(address)",
    "back": "back(address,uint256)",
    "isFresh": "isFresh()",
    "lastReportAt": "lastReportAt()",
    "maxScoreAge": "maxScoreAge()",
    "InsufficientCredit": "InsufficientCredit()",
}


class RpcError(Exception):
    def __init__(self, message, data=None):
        super().__init__(message)
        self.data = data


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(url, data=body, headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        out = json.loads(resp.read())
    if "error" in out:
        err = out["error"]
        raise RpcError(err.get("message", "rpc error"), err.get("data"))
    return out["result"]


def word_address(addr):
    a = addr.lower()
    if a.startswith("0x"):
        a = a[2:]
    if len(a) != 40 or any(c not in "0123456789abcdef" for c in a):
        raise ValueError("not an address: " + addr)
    return a.rjust(64, "0")


def word_uint(n):
    if n < 0:
        raise ValueError("negative amount")
    return format(n, "x").rjust(64, "0")


def calldata(selector, *words):
    return selector + "".join(words)


def words_of(result):
    h = result[2:] if result.startswith("0x") else result
    return [int(h[i : i + 64], 16) for i in range(0, len(h), 64)]


def call(url, to, data, frm=None, block="latest"):
    tx = {"to": to, "data": data}
    if frm:
        tx["from"] = frm
    return rpc(url, "eth_call", [tx, block])


def revert_selector(exc):
    """The 4-byte error selector in a reverted call, or None when none can be found."""
    data = exc.data
    if isinstance(data, dict):  # some nodes nest it
        data = data.get("data")
    if isinstance(data, str) and data.startswith("0x") and len(data) >= 10:
        return data[:10].lower()
    return None


# ───────────────────────────── snapshot ─────────────────────────────


def read_account(url, pool, who):
    w = word_address(who)
    one = lambda name: words_of(call(url, pool, calldata(SEL[name], w)))[0]
    limit, available = words_of(call(url, pool, calldata(SEL["getBorrowLimit"], w)))
    free_credit, free_stake = words_of(call(url, pool, calldata(SEL["getFreeCredit"], w)))
    return {
        "address": who,
        "granted": one("grantedCredit"),
        "score": one("getCreditScore"),
        "override": one("scoreOverrides"),
        "dues": one("duesPaid"),
        "lost": one("creditLoss"),
        "credit_committed": one("creditCommitted"),
        "stake": one("stakeOf"),
        "stake_committed": one("stakeCommitted"),
        "defaulted": one("defaultedLoans"),
        "limit": limit,
        "available": available,
        "free_credit": free_credit,
        "free_stake": free_stake,
    }


def read_edge(url, pool, backer, borrower):
    secured, unsecured = words_of(
        call(url, pool, calldata(SEL["getBacking"], word_address(backer), word_address(borrower)))
    )
    return {"backer": backer, "borrower": borrower, "secured": secured, "unsecured": unsecured}


def read_provider(url, pool):
    """Freshness of the score provider: it is provider-wide, and a stale one zeroes every score."""
    provider = "0x" + words_of(call(url, pool, SEL["scoreProvider"]))[0].to_bytes(20, "big").hex()
    block = rpc(url, "eth_getBlockByNumber", ["latest", False])
    now = int(block["timestamp"], 16)
    info = {"provider": provider, "block": int(block["number"], 16), "block_time": now}
    if int(provider, 16) == 0:
        return info
    try:
        info["fresh"] = bool(words_of(call(url, provider, SEL["isFresh"]))[0])
        last = words_of(call(url, provider, SEL["lastReportAt"]))[0]
        age = words_of(call(url, provider, SEL["maxScoreAge"]))[0]
        info["last_report_at"] = last
        info["max_score_age"] = age
        info["stale_at"] = last + age
        info["seconds_left"] = max(0, last + age - now)
    except (RpcError, IndexError):
        info["fresh"] = None  # a provider without these views
    return info


def take_snapshot(url, pool, a, b, c=None):
    chain = int(rpc(url, "eth_chainId", []), 16)
    snap = {
        "chain_id": chain,
        "pool": pool,
        "provider": read_provider(url, pool),
        "a": read_account(url, pool, a),
        "b": read_account(url, pool, b),
        "edge_ab": read_edge(url, pool, a, b),
    }
    if c:
        snap["c"] = read_account(url, pool, c)
        snap["edge_bc"] = read_edge(url, pool, b, c)
    return snap


# ───────────────────────────── verify ─────────────────────────────


def capacity(acct):
    return acct["free_credit"] + acct["free_stake"]


def verify(before, after, amount, route):
    """Pure function over two snapshots. Returns a list of (status, text); status is
    PASS, FAIL or NOT APPLICABLE."""
    out = []

    def check(ok, text):
        out.append(("PASS" if ok else "FAIL", text))

    for key in ("pool", "chain_id"):
        if before[key] != after[key]:
            return [("FAIL", "snapshots are from different %s: %s vs %s" % (key, before[key], after[key]))]
    for key in ("a", "b"):
        if before[key]["address"].lower() != after[key]["address"].lower():
            return [("FAIL", "snapshots name different addresses for %s" % key)]

    a0, a1, b0, b1 = before["a"], after["a"], before["b"], after["b"]

    fell = capacity(a0) - capacity(a1)
    a_owes = a0["limit"] - a0["available"]
    if a_owes == 0:
        check(fell == amount, "1. A's free capacity (credit + stake) fell by %s (expected exactly %s)" % (usdc(fell), usdc(amount)))
    else:
        check(fell >= amount, "1. A's free capacity fell by %s (at least %s expected: A has an open loan, which draws on backing received first)" % (usdc(fell), usdc(amount)))

    rose = b1["limit"] - b0["limit"]
    if rose == amount:
        check(True, "2. B's borrow limit rose by %s (expected %s)" % (usdc(rose), usdc(amount)))
    elif 0 <= rose < amount:
        out.append(("FAIL", "2. B's borrow limit rose by only %s of %s: the backing is not fully counted (A's cover is short, or the snapshot is stale)" % (usdc(rose), usdc(amount))))
    else:
        check(False, "2. B's borrow limit rose by %s, more than the %s A gave: credit was created" % (usdc(rose), usdc(amount)))

    total0 = a0["limit"] + b0["limit"] + a0["free_stake"] + b0["free_stake"]
    total1 = a1["limit"] + b1["limit"] + a1["free_stake"] + b1["free_stake"]
    owes = a0["limit"] - a0["available"] + b0["limit"] - b0["available"]
    if total1 > total0:
        check(False, "3. conservation broken: limit(A) + limit(B) + free stake rose from %s to %s" % (usdc(total0), usdc(total1)))
    elif total1 == total0:
        check(True, "3. conservation: limit(A) + limit(B) + free stake is %s before and after" % usdc(total0))
    elif owes == 0:
        check(False, "3. neither side owes anything, so the total should be unchanged, but it fell from %s to %s" % (usdc(total0), usdc(total1)))
    else:
        check(True, "3. conservation: the total fell from %s to %s (at most; a borrower in the pair has an open loan, which backing received counts conservatively)" % (usdc(total0), usdc(total1)))

    same = (
        a0["granted"] == a1["granted"]
        and a0["stake"] == a1["stake"]
        and b0["granted"] == b1["granted"]
        and b0["stake"] == b1["stake"]
    )
    check(same, "4. granted credit and stake are unchanged for A and B (backing moves capacity, it creates none)")

    e0, e1 = before["edge_ab"], after["edge_ab"]
    dsec = e1["secured"] - e0["secured"]
    dun = e1["unsecured"] - e0["unsecured"]
    expect = (0, amount) if route == "grant" else (amount, 0)
    check(
        (dsec, dun) == expect,
        "5. the edge A to B gained secured %s and unsecured %s (the %s route expects %s and %s)"
        % (usdc(dsec), usdc(dun), route, usdc(expect[0]), usdc(expect[1])),
    )

    check(
        b1["free_credit"] <= b0["free_credit"] and b1["free_stake"] <= b0["free_stake"],
        "6. B holds no free credit or free stake that it did not hold before (received backing is not free capacity)",
    )

    if "c" in before and "c" in after:
        c0, c1 = before["c"], after["c"]
        check(
            c1["limit"] == c0["limit"] and capacity(c1) == capacity(c0),
            "7. C is unchanged (limit %s, free capacity %s): nothing flowed on to a second hop"
            % (usdc(c1["limit"]), usdc(capacity(c1))),
        )

    for label, snap in (("before", before), ("after", after)):
        acct = snap["a"]
        prov = snap.get("provider", {})
        if route == "grant" and prov.get("fresh") is False and acct["override"] == 0 and acct["score"] == 0:
            out.append(("FAIL", "the score provider is stale in the %s snapshot and A holds no override: A's issued line reads 0" % label))
    prov = after.get("provider", {})
    if prov.get("fresh") and acct_uses_provider(after["a"]):
        out.append(("NOTE", "the score provider reads stale %d s after the latest block: finish the cleanup (back(B, 0), releaseBudget) inside that window, or send a heartbeat report" % prov["seconds_left"]))
    elif route == "grant" and after["a"]["override"] != 0:
        out.append(("NOTE", "A's line is an admin override, so the provider's clock does not apply to it"))
    return out


def acct_uses_provider(acct):
    return acct["override"] == 0 and acct["score"] != 0


def usdc(n):
    return "%s USDC" % (Decimal(n) / USDC).normalize() if n % USDC else "%d USDC" % (n // USDC)


# ───────────────────────────── controls ─────────────────────────────


def simulate_revert(url, pool, frm, to_borrower, amount):
    """Simulate frm.back(to_borrower, amount). Returns ('ok', None) or ('revert', selector)."""
    data = calldata(SEL["back"], word_address(to_borrower), word_uint(amount))
    try:
        call(url, pool, data, frm=frm)
    except RpcError as exc:
        return "revert", revert_selector(exc)
    return "ok", None


def controls(url, pool, a, b, c, stage):
    out = []
    acct_a = read_account(url, pool, a)
    acct_b = read_account(url, pool, b)

    # Control 1: B, holding only received backing, cannot pass it on to C.
    if capacity(acct_b) != 0:
        out.append(("NOT APPLICABLE", "B holds free credit or stake of its own (%s), so a backing of C could succeed for a lawful reason" % usdc(capacity(acct_b))))
    elif acct_b["limit"] == 0 and stage == "before":
        out.append(("NOT APPLICABLE", "before the backing B has no limit at all; the pass-on control is meaningful after A backs B (run it with --stage after as well)"))
    else:
        verdict, sel = simulate_revert(url, pool, b, c, MIN_BACKING)
        out.append(_expect_insufficient("B (limit %s, free capacity 0) backing C with %s" % (usdc(acct_b["limit"]), usdc(MIN_BACKING)), verdict, sel))

    # Control 2: A cannot raise its backing of B above what it holds free.
    edge = read_edge(url, pool, a, b)
    current = edge["secured"] + edge["unsecured"]
    over = max(current + capacity(acct_a) + 1, MIN_BACKING)
    verdict, sel = simulate_revert(url, pool, a, b, over)
    out.append(
        _expect_insufficient(
            "A raising its backing of B to %s (holds %s now, free capacity %s)" % (usdc(over), usdc(current), usdc(capacity(acct_a))),
            verdict,
            sel,
        )
    )
    return out


def _expect_insufficient(what, verdict, sel):
    if verdict == "revert" and sel == INSUFFICIENT_CREDIT:
        return ("PASS", "%s reverts with InsufficientCredit" % what)
    if verdict == "ok":
        return ("FAIL", "%s would succeed (expected InsufficientCredit)" % what)
    return ("FAIL", "%s reverted with %s (expected InsufficientCredit %s)" % (what, sel or "no error data", INSUFFICIENT_CREDIT))


# ───────────────────────────── cli ─────────────────────────────


def print_results(results):
    failed = False
    for status, text in results:
        print("%-14s %s" % (status, text))
        failed = failed or status == "FAIL"
    return 1 if failed else 0


def parse_usdc(text):
    value = Decimal(text) * USDC
    if value != value.to_integral_value() or value <= 0:
        raise argparse.ArgumentTypeError("amount must be a positive USDC value with at most six decimals")
    return int(value)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    def common(sp):
        sp.add_argument("--rpc", required=True)
        sp.add_argument("--pool", required=True)
        sp.add_argument("--a", required=True, help="the backer")
        sp.add_argument("--b", required=True, help="the borrower A backs")
        sp.add_argument("--c", help="a third address B would back (second hop)")

    s = sub.add_parser("snapshot", help="read the state of A, B (and C) and print or save it")
    common(s)
    s.add_argument("--out")
    c = sub.add_parser("controls", help="simulate the negative controls (nothing is sent)")
    common(c)
    c.add_argument("--stage", choices=("before", "after"), required=True)
    v = sub.add_parser("verify", help="compare two snapshots around one back(B, amount) by A")
    v.add_argument("--before", required=True)
    v.add_argument("--after", required=True)
    v.add_argument("--amount", required=True, type=parse_usdc, help="USDC, for example 2 or 1.5")
    v.add_argument("--route", choices=("grant", "stake"), required=True)

    args = p.parse_args(argv)
    if args.cmd == "snapshot":
        snap = take_snapshot(args.rpc, args.pool, args.a, args.b, args.c)
        text = json.dumps(snap, indent=2, sort_keys=True)
        if args.out:
            with open(args.out, "w") as f:
                f.write(text + "\n")
        print(text)
        prov = snap["provider"]
        if "seconds_left" in prov:
            state = "fresh, reads stale in %d s" % prov["seconds_left"] if prov["fresh"] else "stale"
            print("score provider %s (latest block time)" % state, file=sys.stderr)
        return 0
    if args.cmd == "controls":
        if not args.c:
            p.error("controls needs --c")
        return print_results(controls(args.rpc, args.pool, args.a, args.b, args.c, args.stage))
    with open(args.before) as f:
        before = json.load(f)
    with open(args.after) as f:
        after = json.load(f)
    return print_results(verify(before, after, args.amount, args.route))


if __name__ == "__main__":
    sys.exit(main())
