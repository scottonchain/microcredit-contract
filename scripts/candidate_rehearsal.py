#!/usr/bin/env python3
"""Rehearse the bootstrap candidate end to end with `cast`, the same calls a custodian makes on a public chain.

Standard library plus Foundry's `cast`. No key is read or written: this script uses an Anvil node's unlocked accounts
(`anvil --fork-url https://sepolia.base.org --chain-id 84532`). It generates fresh throwaway keys in memory for every role
(never written to disk; Anvil's well-known dev accounts carry EIP-7702 code on the public chain, so their signatures fail
the ERC-1271 path), funds them with ETH through `anvil_setBalance` and with USDC by impersonating a holder on the fork.
For a public chain the custodian runs the same calls with `--account <keystore>` in place of `--private-key`, and
`cast wallet sign --data` on the JSON that `typed-data` prints.

  candidate_rehearsal.py run --rpc http://127.0.0.1:8546 --pool 0x.. --router 0x.. [--with-default]
  candidate_rehearsal.py typed-data pool|consent|accept --chain-id N --verifying 0x.. [fields as --key value]

The product is one manager, `BootstrapOrderRouter`. The run: a lender deposits 5 USDC; the worker names the router as its
manager; two roots deposit 1 USDC each; a customer funds an exact order (1 USDC advance to a vendor, 1.5 USDC price); the
roots and a mid sign consents, the worker signs the pool request and its acceptance of the order; negative controls (every
direct origination path, a tampered request, a forged consent and the unbound router entry refuse); anyone submits
`originateOrder`; a replay refuses; the customer settles (the debt is paid first, the worker receives the remainder, the
roots' lot returns); roots and lender withdraw; the aggregate USDC of every role, vault, pool and router is checked equal
before and after. `--with-default` adds a second order that the customer refunds and nobody cures, defaulted after a fork
time jump (labelled as time travel; not possible on a public chain): the whole lot is attributed to the roots pro rata and
lenders lose no principal.
"""
import argparse, json, subprocess, sys

USDC_DEFAULT = "0x036CbD53842c5426634e7929541eC2318f3dCF7e"
USDC_SOURCE_DEFAULT = "0x73872B8fB7F1771C67911f03edc75aBdc9514973"  # the live pool holds test USDC on Base Sepolia
DAY = 86400


def pool_domain(chain_id, verifying):
    return {"name": "DecentralizedMicrocredit", "version": "1", "chainId": chain_id, "verifyingContract": verifying}


def router_domain(chain_id, verifying):
    return {"name": "BootstrapOrderRouter", "version": "1", "chainId": chain_id, "verifyingContract": verifying}


DOMAIN_TYPE = [{"name": "name", "type": "string"}, {"name": "version", "type": "string"},
               {"name": "chainId", "type": "uint256"}, {"name": "verifyingContract", "type": "address"}]
POOL_FIELDS = [("borrower", "address"), ("amount", "uint256"), ("to", "address"), ("repaymentPeriod", "uint256"),
               ("maxAprBps", "uint256"), ("nonce", "uint256"), ("deadline", "uint256")]
CONSENT_FIELDS = [("from", "address"), ("to", "address"), ("borrower", "address"), ("limit", "uint256"),
                  ("maxTerm", "uint256"), ("version", "uint256"), ("expiry", "uint256")]
ACCEPT_FIELDS = [("orderId", "uint256"), ("payer", "address"), ("price", "uint256"), ("maxDebt", "uint256"),
                 ("settleBy", "uint256"), ("intentHash", "bytes32")]
INTENT_FIELDS = [("worker", "address"), ("vendor", "address"), ("amount", "uint256"), ("term", "uint256"),
                 ("maxAprBps", "uint256"), ("nonce", "uint256"), ("deadline", "uint256"), ("jobHash", "bytes32")]


def typed(primary, fields, domain, message):
    return {"types": {"EIP712Domain": DOMAIN_TYPE, primary: [{"name": n, "type": t} for n, t in fields]},
            "primaryType": primary, "domain": domain, "message": {n: str(message[n]) if t == "uint256" else message[n] for n, t in fields}}


def pool_typed(chain_id, pool, m):
    return typed("BorrowAndDisburse", POOL_FIELDS, pool_domain(chain_id, pool), m)


def consent_typed(chain_id, router, m):
    return typed("EdgeConsent", CONSENT_FIELDS, router_domain(chain_id, router), m)


def accept_typed(chain_id, router, m):
    return typed("AcceptOrder", ACCEPT_FIELDS, router_domain(chain_id, router), m)


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


def tup(fields, m):
    return "(" + ",".join(str(m[n]) for n, _ in fields) + ")"


INTENT_T = "(address,address,uint256,uint256,uint256,uint256,uint256,bytes32)"
REQ_T = "(address,uint256,address,uint256,uint256,uint256,uint256)"
CONSENT_T = "(address,address,address,uint256,uint256,uint256,uint256)"
PATH_T = f"(uint256,{CONSENT_T},bytes,{CONSENT_T},bytes)"
ORIG = f"originateOrder(uint256,{REQ_T},bytes,bytes,{PATH_T}[])"
FUND = f"fund({INTENT_T},uint256,uint256,uint256)"
UNBOUND = f"originate({REQ_T},bytes,{PATH_T}[])"  # the unbound router's entry: it must not exist on the bootstrap router


def run(a):
    c = Cast(a.rpc)
    chain = int(c.run("chain-id", "--rpc-url", a.rpc))
    names = ["deployer", "lender", "worker", "root1", "root2", "mid", "vendor", "customer", "submitter", "worker2"]
    roles = {}
    for n in names:
        w = json.loads(c.run("wallet", "new", "--json"))[0]
        roles[n] = w["address"]
        Cast.keys[w["address"].lower()] = w["private_key"]
        c.run("rpc", "--rpc-url", a.rpc, "anvil_setBalance", w["address"], "0xDE0B6B3A7640000")
    L, W, R1, R2, M, V, C, S, W2 = (roles[k] for k in ("lender", "worker", "root1", "root2", "mid", "vendor", "customer", "submitter", "worker2"))
    pool, router, usdc = a.pool, a.router, a.usdc
    price, amount = usdc_amt(1.5), usdc_amt(1)
    log = []

    def step(msg):
        log.append(msg); print(f"- {msg}")

    def bal(x):
        return int(c.call(usdc, "balanceOf(address)(uint256)", x))

    def vault(w):
        v = c.call(router, "vaultOf(address)(address)", w)
        return None if int(v, 16) == 0 else v

    # funding by impersonating a USDC holder (fork only)
    c.run("rpc", "--rpc-url", a.rpc, "anvil_impersonateAccount", a.usdc_source)
    c.run("rpc", "--rpc-url", a.rpc, "anvil_setBalance", a.usdc_source, "0x56BC75E2D63100000")
    fund = {L: 5, R1: 1, R2: 1, C: 1.5 * (2 if a.with_default else 1)}
    for who, amt in fund.items():
        c.send(a.usdc_source, usdc, "transfer(address,uint256)", who, str(usdc_amt(amt)))
    tracked = [L, W, R1, R2, M, V, C, S, W2]

    def aggregate():
        vs = [v for v in (vault(W), vault(W2)) if v]
        return sum(bal(x) for x in tracked + vs) + bal(pool) + bal(router)

    total0 = aggregate()
    step(f"funded roles by impersonating the USDC holder; aggregate of roles+vaults+pool+router before = {total0} units")

    # 1 lender deposit; 2 the worker names the router (the one direct worker transaction)
    c.send(L, usdc, "approve(address,uint256)", pool, str(usdc_amt(5)))
    c.send(L, pool, "depositFunds(uint256)", str(usdc_amt(5)))
    step("lender deposited 5 USDC to the candidate pool")
    for w in (W, W2) if a.with_default else (W,):
        c.send(w, pool, "setManager(address)", router)
        assert c.call(pool, "managerOf(address)(address)", w).lower() == router.lower()
    step("worker named the router as its only manager (before any backing exists)")

    # 3 roots deposit
    for r in (R1, R2):
        c.send(r, usdc, "approve(address,uint256)", router, str(usdc_amt(1)))
        c.send(r, router, "deposit(uint256)", str(usdc_amt(1)))
    step("two roots deposited 1 USDC each to the router")

    def one_order(worker, job, split=(600_000, 400_000)):
        """Fund an exact order, sign everything, return what the submitter needs."""
        now = c.now()
        term, apr, settle_by = 7 * DAY, 933, now + 30 * DAY
        nonce = int(c.call(pool, "nonces(address)(uint256)", worker))
        intent = dict(zip([n for n, _ in INTENT_FIELDS],
                          [worker, V, amount, term, apr, nonce, now + 3600, c.run("keccak", job)]))
        order_id = int(c.call(router, "nextOrderId()(uint256)"))
        c.send(C, usdc, "approve(address,uint256)", router, str(price))
        c.send(C, router, FUND, tup(INTENT_FIELDS, intent), str(price), str(price), str(settle_by))
        ihash = c.call(router, f"intentHash({INTENT_T})(bytes32)", tup(INTENT_FIELDS, intent))
        accept = dict(zip([n for n, _ in ACCEPT_FIELDS], [order_id, C, price, price, settle_by, ihash]))
        accept_sig = c.sign(worker, accept_typed(chain, router, accept))
        req = dict(zip([n for n, _ in POOL_FIELDS], [worker, amount, V, term, apr, nonce, intent["deadline"]]))
        pool_sig = c.sign(worker, pool_typed(chain, pool, req))
        expiry = now + 90 * DAY
        paths = []
        for root, part in zip((R1, R2), split):
            re = dict(zip([n for n, _ in CONSENT_FIELDS], [root, M, "0x" + "00" * 20, usdc_amt(100), 30 * DAY, 0, expiry]))
            me = dict(zip([n for n, _ in CONSENT_FIELDS], [M, worker, worker, usdc_amt(100), 30 * DAY, 0, expiry]))
            paths.append((part, re, c.sign(root, consent_typed(chain, router, re)), me, c.sign(M, consent_typed(chain, router, me))))
        return order_id, req, pool_sig, accept_sig, paths

    def paths_arg(paths):
        return "[" + ",".join(f"({p},{tup(CONSENT_FIELDS, re)},{rs},{tup(CONSENT_FIELDS, me)},{ms})" for p, re, rs, me, ms in paths) + "]"

    # 4 order A: fund, sign, negative controls
    id_a, req, pool_sig, accept_sig, paths = one_order(W, "rehearsal-A")
    step(f"customer funded order {id_a} (1 USDC advance to the vendor, price 1.5 USDC); worker signed the pool request and the acceptance; roots and mid signed consents")
    not_manager = c.selector("NotManager()")
    bad, out = c.call_reverts(pool, "requestLoan(uint256)", str(amount), frm=W)
    assert bad and not_manager in out, out
    bad, out = c.call_reverts(pool, f"borrowAndDisburseMeta({REQ_T},bytes)", tup(POOL_FIELDS, req), pool_sig, frm=S)
    assert bad and not_manager in out, out
    tampered = dict(req, to=S)
    bad, out = c.call_reverts(router, ORIG, str(id_a), tup(POOL_FIELDS, tampered), pool_sig, accept_sig, paths_arg(paths), frm=S)
    assert bad and c.selector("IntentMismatch()") in out, out
    forged_paths = [(p, re, rs[:-4] + ("0000" if not rs.endswith("0000") else "1111"), me, ms) for p, re, rs, me, ms in paths]
    bad, _ = c.call_reverts(router, ORIG, str(id_a), tup(POOL_FIELDS, req), pool_sig, accept_sig, paths_arg(forged_paths), frm=S)
    assert bad, "a forged consent must fail"
    bad, _ = c.call_reverts(router, UNBOUND, tup(POOL_FIELDS, req), pool_sig, paths_arg(paths), frm=S)
    assert bad, "the unbound router entry must not exist here"
    step("negative controls refused: direct requestLoan by the worker, borrowAndDisburseMeta by a stranger, a tampered vendor, a forged consent, the unbound `originate` entry")

    # 5 originate by a stranger
    v0, l0 = bal(V), int(c.call(pool, "totalLentOut()(uint256)"))
    h = c.send(S, router, ORIG, str(id_a), tup(POOL_FIELDS, req), pool_sig, accept_sig, paths_arg(paths))
    ids = c.call(pool, "getBorrowerLoanIds(address)(uint256[])", W)
    loan_a = int(ids.strip("[]").split(",")[-1])
    assert int(c.call(router, "loanOrder(uint256)(uint256)", str(loan_a))) == id_a
    assert bal(V) - v0 == amount and int(c.call(pool, "totalLentOut()(uint256)")) - l0 == amount
    assert int(c.call(router, "locked(address)(uint256)", R1)) == 600_000 and int(c.call(router, "locked(address)(uint256)", R2)) == 400_000
    step(f"originateOrder by a stranger (tx {h}): loan {loan_a} bound to order {id_a}, vendor +1 USDC, pool lent out +1 USDC; roots locked 0.6 and 0.4 USDC; the customer's escrow stays apart")
    bad, _ = c.call_reverts(router, ORIG, str(id_a), tup(POOL_FIELDS, req), pool_sig, accept_sig, paths_arg(paths), frm=S)
    assert bad
    step("replay of the same order and signatures refused")

    # 6 settle: debt first, then the worker; the lot returns
    w0 = bal(W)
    c.send(C, router, "settleOrder(uint256)", str(id_a))
    assert bal(W) - w0 == price - amount, (bal(W) - w0)
    assert int(c.call(router, "locked(address)(uint256)", R1)) == 0 and int(c.call(router, "free(address)(uint256)", R1)) == usdc_amt(1)
    assert int(c.call(router, "totalEscrowHeld()(uint256)")) == 0
    step(f"customer settled: the 1 USDC debt was repaid first (loan closed), the worker received {price - amount} units, the roots' lot returned, escrow is zero")

    # 7 optional default path on the fork (time travel)
    if a.with_default:
        id_b, req_b, ps_b, as_b, paths_b = one_order(W2, "rehearsal-B")
        c.send(S, router, ORIG, str(id_b), tup(POOL_FIELDS, req_b), ps_b, as_b, paths_arg(paths_b))
        loan_b = int(c.call(pool, "getBorrowerLoanIds(address)(uint256[])", W2).strip("[]").split(",")[-1])
        c.send(C, router, "refundOrder(uint256)", str(id_b))
        assert int(c.call(router, "totalEscrowHeld()(uint256)")) == 0
        c.run("rpc", "--rpc-url", a.rpc, "evm_increaseTime", str(7 * DAY + 30 * DAY + 60))
        c.run("rpc", "--rpc-url", a.rpc, "evm_mine")
        c.send(S, pool, "markDefaulted(uint256)", str(loan_b))
        c.send(S, router, "sync(address)", W2)
        l1, l2 = (int(c.call(router, "lossOf(address)(uint256)", r)) for r in (R1, R2))
        assert (l1, l2) == (600_000, 400_000), (l1, l2)
        step(f"[fork time travel] order {id_b}: the customer refunded and nobody cured the loan; defaulted after 7+30 days; sync attributed the whole lot to the roots pro rata (lossOf = {l1} and {l2}); lenders lost no principal")

    # 8 exits and aggregate conservation
    for r in (R1, R2):
        f = int(c.call(router, "free(address)(uint256)", r))
        if f:
            c.send(r, router, "withdraw(uint256)", str(f))
    c.send(L, pool, "withdrawFunds(uint256)", str(2**256 - 1))
    total1 = aggregate()
    step(f"roots and lender withdrew everything; aggregate after = {total1} units (before {total0})")
    assert total1 == total0, f"aggregate changed: {total0} -> {total1}"
    assert int(c.call(pool, "totalLentOut()(uint256)")) == 0 and bal(router) == 0
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
    t.add_argument("kind", choices=["pool", "consent", "accept"])
    t.add_argument("--chain-id", type=int, required=True)
    t.add_argument("--verifying", required=True)
    for n, _ in POOL_FIELDS + CONSENT_FIELDS + ACCEPT_FIELDS:
        try:
            t.add_argument(f"--{n}")
        except argparse.ArgumentError:
            pass
    a = ap.parse_args()
    if a.cmd == "run":
        return run(a)
    fields = {"pool": POOL_FIELDS, "consent": CONSENT_FIELDS, "accept": ACCEPT_FIELDS}[a.kind]
    msg = {n: getattr(a, n) for n, _ in fields}
    missing = [n for n, v in msg.items() if v is None]
    if missing:
        sys.exit("missing: " + ", ".join("--" + m for m in missing))
    print(json.dumps({"pool": pool_typed, "consent": consent_typed, "accept": accept_typed}[a.kind](a.chain_id, a.verifying, msg), indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
