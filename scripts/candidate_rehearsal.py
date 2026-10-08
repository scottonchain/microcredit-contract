#!/usr/bin/env python3
"""Rehearse the bootstrap candidate end to end with `cast`, the same calls a custodian makes on a public chain.

Standard library plus Foundry's `cast`. No key is read or written: this script uses an Anvil node's unlocked accounts
(`anvil --fork-url https://sepolia.base.org --chain-id 84532`). It generates fresh throwaway keys in memory for every role
(never written to disk; Anvil's well-known dev accounts carry EIP-7702 code on the public chain, so their signatures fail
the ERC-1271 path), funds them with ETH through `anvil_setBalance` and with USDC by impersonating a holder on the fork.
For a public chain the custodian runs the same calls with `--account <keystore>` in place of `--private-key`, and
`cast wallet sign --data` on the JSON that `typed-data` prints.

  candidate_rehearsal.py run --rpc http://127.0.0.1:8546 --pool 0x.. --router 0x.. [--with-default]
  candidate_rehearsal.py typed-data pool|consent --chain-id N --verifying 0x.. [fields as --key value]

The run: lender deposits 5 USDC; the borrower names the router as manager; a root deposits 1 USDC; the root and a mid sign
consents, the borrower signs the pool request; anyone submits `originate`; negative controls (every direct origination path
and a forged consent refuse); a stranger repays within the first day; `sync`; the root withdraws; the lender withdraws all;
the aggregate USDC of every role is checked equal before and after. `--with-default` adds a second borrower that is never
repaid and is defaulted after a fork time jump (labelled as time travel; not possible on a public chain).
"""
import argparse, json, subprocess, sys

USDC_DEFAULT = "0x036CbD53842c5426634e7929541eC2318f3dCF7e"
USDC_SOURCE_DEFAULT = "0x73872B8fB7F1771C67911f03edc75aBdc9514973"  # the live pool holds test USDC on Base Sepolia
DAY = 86400


def pool_domain(chain_id, verifying):
    return {"name": "DecentralizedMicrocredit", "version": "1", "chainId": chain_id, "verifyingContract": verifying}


def router_domain(chain_id, verifying):
    return {"name": "TransitiveStakeRouter", "version": "1", "chainId": chain_id, "verifyingContract": verifying}


DOMAIN_TYPE = [{"name": "name", "type": "string"}, {"name": "version", "type": "string"},
               {"name": "chainId", "type": "uint256"}, {"name": "verifyingContract", "type": "address"}]
POOL_FIELDS = [("borrower", "address"), ("amount", "uint256"), ("to", "address"), ("repaymentPeriod", "uint256"),
               ("maxAprBps", "uint256"), ("nonce", "uint256"), ("deadline", "uint256")]
CONSENT_FIELDS = [("from", "address"), ("to", "address"), ("borrower", "address"), ("limit", "uint256"),
                  ("maxTerm", "uint256"), ("version", "uint256"), ("expiry", "uint256")]


def typed(primary, fields, domain, message):
    return {"types": {"EIP712Domain": DOMAIN_TYPE, primary: [{"name": n, "type": t} for n, t in fields]},
            "primaryType": primary, "domain": domain, "message": {n: str(message[n]) if t == "uint256" else message[n] for n, t in fields}}


def pool_typed(chain_id, pool, m):
    return typed("BorrowAndDisburse", POOL_FIELDS, pool_domain(chain_id, pool), m)


def consent_typed(chain_id, router, m):
    return typed("EdgeConsent", CONSENT_FIELDS, router_domain(chain_id, router), m)


class Cast:
    def __init__(self, rpc):
        self.rpc = rpc

    def run(self, *args):
        p = subprocess.run(["cast", *args], capture_output=True, text=True)
        if p.returncode != 0:
            raise RuntimeError(f"cast {' '.join(args[:3])}...: {p.stderr.strip()[:400]}")
        return p.stdout.strip()

    def call(self, to, sig, *a, frm=None):
        extra = ["--from", frm] if frm else []
        return self.run("call", "--rpc-url", self.rpc, *extra, to, sig, *a).split(" ")[0]

    def call_reverts(self, to, sig, *a, frm=None):
        extra = ["--from", frm] if frm else []
        p = subprocess.run(["cast", "call", "--rpc-url", self.rpc, *extra, to, sig, *a], capture_output=True, text=True)
        return p.returncode != 0, (p.stderr + p.stdout)

    keys = {}  # address (lowercase) -> throwaway private key, in memory only

    def send(self, frm, to, sig, *a):
        key = self.keys.get(frm.lower())
        who = ["--private-key", key] if key else ["--unlocked", "--from", frm]
        out = self.run("send", "--rpc-url", self.rpc, *who, "--json", to, sig, *a)
        r = json.loads(out)
        if r.get("status") not in ("0x1", 1, "1"):
            raise RuntimeError(f"tx failed: {out[:300]}")
        return r["transactionHash"]

    def sign(self, signer, typed_data):
        return self.run("wallet", "sign", "--data", "--private-key", self.keys[signer.lower()], json.dumps(typed_data))

    def selector(self, sig):
        return self.run("sig", sig)

    def now(self):
        return int(self.run("block", "--rpc-url", self.rpc, "-f", "timestamp"))


def usdc_amt(x):
    return int(round(x * 1_000_000))


def run(a):
    c = Cast(a.rpc)
    chain = int(c.run("chain-id", "--rpc-url", a.rpc))
    names = ["deployer", "lender", "borrower", "root", "mid", "vendor", "payer", "submitter", "borrower2"]
    roles = {}
    for n in names:
        w = json.loads(c.run("wallet", "new", "--json"))[0]
        roles[n] = w["address"]
        Cast.keys[w["address"].lower()] = w["private_key"]
        c.run("rpc", "--rpc-url", a.rpc, "anvil_setBalance", w["address"], "0xDE0B6B3A7640000")
    L, B, R, M, V, P, S, B2 = (roles[k] for k in ("lender", "borrower", "root", "mid", "vendor", "payer", "submitter", "borrower2"))
    pool, router, usdc = a.pool, a.router, a.usdc
    log = []

    def step(msg):
        log.append(msg); print(f"- {msg}")

    def bal(x):
        return int(c.call(usdc, "balanceOf(address)(uint256)", x))

    # funding by impersonating a USDC holder (fork only)
    c.run("rpc", "--rpc-url", a.rpc, "anvil_impersonateAccount", a.usdc_source)
    c.run("rpc", "--rpc-url", a.rpc, "anvil_setBalance", a.usdc_source, "0x56BC75E2D63100000")
    fund = {L: 5, R: 1, P: 1.0, B2: 0}
    if a.with_default:
        fund[R] = 2
    for who, amt in fund.items():
        if amt:
            c.send(a.usdc_source, usdc, "transfer(address,uint256)", who, str(usdc_amt(amt)))
    tracked = [L, B, R, M, V, P, S, B2]
    total0 = sum(bal(x) for x in tracked) + bal(pool) + bal(router)
    step(f"funded roles by impersonating the USDC holder; aggregate of roles+pool+router before = {total0} units")

    # 1 lender deposit
    c.send(L, usdc, "approve(address,uint256)", pool, str(usdc_amt(5)))
    c.send(L, pool, "depositFunds(uint256)", str(usdc_amt(5)))
    step("lender deposited 5 USDC to the candidate pool")

    # 2 borrower names the router as manager (the one direct borrower transaction)
    c.send(B, pool, "setManager(address)", router)
    assert c.call(pool, "managerOf(address)(address)", B).lower() == router.lower()
    step("borrower named the router as manager (before any backing exists)")

    # 3 root deposit
    c.send(R, usdc, "approve(address,uint256)", router, str(usdc_amt(1)))
    c.send(R, router, "deposit(uint256)", str(usdc_amt(1)))
    step("root deposited 1 USDC to the router")

    # 4 signatures
    now = c.now()
    amount, term, apr = usdc_amt(1), 7 * DAY, 933
    expiry = now + 30 * DAY
    root_edge = dict(zip([n for n, _ in CONSENT_FIELDS], [R, M, B, amount, 30 * DAY, 0, expiry]))
    mid_edge = dict(zip([n for n, _ in CONSENT_FIELDS], [M, B, B, amount, 30 * DAY, 0, expiry]))
    root_sig = c.sign(R, consent_typed(chain, router, root_edge))
    mid_sig = c.sign(M, consent_typed(chain, router, mid_edge))
    nonce = int(c.call(pool, "nonces(address)(uint256)", B))
    req = dict(zip([n for n, _ in POOL_FIELDS], [B, amount, V, term, apr, nonce, now + 3600]))
    pool_sig = c.sign(B, pool_typed(chain, pool, req))

    def tup_req(r):
        return "(" + ",".join(str(r[n]) for n, _ in POOL_FIELDS) + ")"

    def tup_consent(m):
        return "(" + ",".join(str(m[n]) for n, _ in CONSENT_FIELDS) + ")"

    def paths(rsig, msig):
        return "[(" + f"{amount},{tup_consent(root_edge)},{rsig},{tup_consent(mid_edge)},{msig}" + ")]"

    ORIG = ("originate((address,uint256,address,uint256,uint256,uint256,uint256),bytes,"
            "(uint256,(address,address,address,uint256,uint256,uint256,uint256),bytes,"
            "(address,address,address,uint256,uint256,uint256,uint256),bytes)[])")

    # 5 negative controls (read-only calls)
    not_manager = c.selector("NotManager()")
    bad, out = c.call_reverts(pool, "requestLoan(uint256)", str(amount), frm=B)
    assert bad and not_manager in out, out
    bad, out = c.call_reverts(pool, "borrowAndDisburseMeta((address,uint256,address,uint256,uint256,uint256,uint256),bytes)", tup_req(req), pool_sig, frm=S)
    assert bad and not_manager in out, out
    forged = root_sig[:-4] + ("0000" if not root_sig.endswith("0000") else "1111")
    bad, out = c.call_reverts(router, ORIG, tup_req(req), pool_sig, paths(forged, mid_sig), frm=S)
    assert bad, "a forged consent must fail"
    step("negative controls refused: direct requestLoan by the borrower, borrowAndDisburseMeta by a stranger, a forged root consent")

    # 6 originate
    v0, l0 = bal(V), int(c.call(pool, "totalLentOut()(uint256)"))
    h = c.send(S, router, ORIG, tup_req(req), pool_sig, paths(root_sig, mid_sig))
    ids = c.call(pool, "getBorrowerLoanIds(address)(uint256[])", B)
    loan_id = int(ids.strip("[]").split(",")[-1])
    assert bal(V) - v0 == amount and int(c.call(pool, "totalLentOut()(uint256)")) - l0 == amount
    step(f"originate by a stranger (tx {h}): loan {loan_id}, vendor +1 USDC, pool lent out +1 USDC, vault staked and backing the borrower")

    # 7 a replay of the same signed request fails
    bad, _ = c.call_reverts(router, ORIG, tup_req(req), pool_sig, paths(root_sig, mid_sig), frm=S)
    assert bad
    step("replay of the same signed request refused")

    # 8 direct repayment frees pool capacity, but the router still owns the origination
    owed = int(c.call(pool, "getCurrentOutstandingAmount(uint256)(uint256)", str(loan_id)))
    c.send(P, usdc, "approve(address,uint256)", pool, str(owed))
    c.send(P, pool, "repayLoan(uint256,uint256)", str(loan_id), str(owed))
    bad, out = c.call_reverts(pool, "requestLoan(uint256)", str(amount), frm=B)
    assert bad and not_manager in out
    step(f"stranger repaid {owed} units at the pool inside the first day; the router is still the only door (direct requestLoan refused)")

    # 9 sync, root withdraws
    c.send(S, router, "sync(address)", B)
    assert int(c.call(router, "free(address)(uint256)", R)) == amount and int(c.call(router, "locked(address)(uint256)", R)) == 0
    c.send(R, router, "withdraw(uint256)", str(amount))
    step("sync by a stranger returned the lot; the root withdrew 1 USDC; no loss")

    # 10 optional default path on the fork (time travel)
    if a.with_default:
        c.send(B2, pool, "setManager(address)", router)
        c.send(R, usdc, "approve(address,uint256)", router, str(usdc_amt(2)))
        c.send(R, router, "deposit(uint256)", str(usdc_amt(2)))
        now2 = c.now()
        re2 = dict(zip([n for n, _ in CONSENT_FIELDS], [R, M, B2, usdc_amt(2), 30 * DAY, 0, now2 + 90 * DAY]))
        me2 = dict(zip([n for n, _ in CONSENT_FIELDS], [M, B2, B2, usdc_amt(2), 30 * DAY, 0, now2 + 90 * DAY]))
        rs, ms = c.sign(R, consent_typed(chain, router, re2)), c.sign(M, consent_typed(chain, router, me2))
        r2 = dict(zip([n for n, _ in POOL_FIELDS], [B2, usdc_amt(2), V, term, apr, int(c.call(pool, "nonces(address)(uint256)", B2)), now2 + 3600]))
        ps = c.sign(B2, pool_typed(chain, pool, r2))
        path2 = "[(" + f"{usdc_amt(2)},{tup_consent(re2)},{rs},{tup_consent(me2)},{ms}" + ")]"
        c.send(S, router, ORIG, tup_req(r2), ps, path2)
        id2 = int(c.call(pool, "getBorrowerLoanIds(address)(uint256[])", B2).strip("[]").split(",")[-1])
        c.run("rpc", "--rpc-url", a.rpc, "evm_increaseTime", str(term + 30 * DAY + 60))
        c.run("rpc", "--rpc-url", a.rpc, "evm_mine")
        c.send(S, pool, "markDefaulted(uint256)", str(id2))
        c.send(S, router, "sync(address)", B2)
        loss = int(c.call(router, "lossOf(address)(uint256)", R))
        assert loss == usdc_amt(2), loss
        step(f"[fork time travel] second borrower never repaid; defaulted after {term // DAY}+30 days; sync attributed the whole 2 USDC loss to the root (lossOf = {loss}); lenders lost no principal")

    # 11 lender exits; aggregate conservation
    c.send(L, pool, "withdrawFunds(uint256)", str(2**256 - 1))
    total1 = sum(bal(x) for x in tracked) + bal(pool) + bal(router)
    exp = total0
    step(f"lender withdrew everything; aggregate after = {total1} units (before {total0})")
    assert total1 == exp, f"aggregate changed: {total0} -> {total1}"
    if not a.with_default:
        lent = int(c.call(pool, "totalLentOut()(uint256)"))
        assert lent == 0
    print("REHEARSAL OK" + (" (with default path)" if a.with_default else ""))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--rpc", required=True)
    r.add_argument("--pool", required=True)
    r.add_argument("--router", required=True)
    r.add_argument("--usdc", default=USDC_DEFAULT)
    r.add_argument("--usdc-source", default=USDC_SOURCE_DEFAULT)
    r.add_argument("--with-default", action="store_true")
    t = sub.add_parser("typed-data")
    t.add_argument("kind", choices=["pool", "consent"])
    t.add_argument("--chain-id", type=int, required=True)
    t.add_argument("--verifying", required=True)
    for n, _ in POOL_FIELDS + CONSENT_FIELDS:
        try:
            t.add_argument(f"--{n}")
        except argparse.ArgumentError:
            pass
    a = ap.parse_args()
    if a.cmd == "run":
        return run(a)
    fields = POOL_FIELDS if a.kind == "pool" else CONSENT_FIELDS
    msg = {n: getattr(a, n) for n, _ in fields}
    missing = [n for n, v in msg.items() if v is None]
    if missing:
        sys.exit("missing: " + ", ".join("--" + m for m in missing))
    print(json.dumps((pool_typed if a.kind == "pool" else consent_typed)(a.chain_id, a.verifying, msg), indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
