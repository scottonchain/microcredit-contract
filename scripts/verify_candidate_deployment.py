#!/usr/bin/env python3
"""Read-only check that deployed bytecode is the reviewed build (standard library; uses curl for the RPC).

  verify_candidate_deployment.py --rpc URL --pool 0x.. --lens 0x.. --router 0x.. [--out packages/foundry/out] [--json]

For each contract it fetches the on-chain code, takes the compiled artifact (`forge build`) and compares them with the
immutable slots zeroed on both sides (the constructor writes immutables into the runtime code). It reports a strict match,
a match ignoring the trailing CBOR metadata (source paths/compiler hash can differ between hosts), the code size against
EIP-170, and the immutable values found. Then it reads the wiring through getters: token and pool links, rates, owner.
Exit 0 only if every contract matches at least without metadata and every wiring check holds.
"""
import argparse, hashlib, json, os, subprocess, sys

CONTRACTS = {  # role -> (artifact path under out/, name)
    "pool": ("DecentralizedMicrocredit.sol", "DecentralizedMicrocredit"),
    "lens": ("MicrocreditLens.sol", "MicrocreditLens"),
    "router": ("BootstrapOrderRouter.sol", "BootstrapOrderRouter"),  # the one manager of the bootstrap product
}
USDC_BASE_SEPOLIA = "0x036cbd53842c5426634e7929541ec2318f3dcf7e"


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
    out = subprocess.run(["curl", "-s", "-m", "30", "-X", "POST", "-H", "content-type: application/json", "--data", body, url],
                         capture_output=True, text=True).stdout
    r = json.loads(out)
    if "error" in r:
        raise RuntimeError(f"{method}: {r['error']}")
    return r["result"]


def call(url, to, selector, args=""):
    return rpc(url, "eth_call", [{"to": to, "data": selector + args}, "latest"])


def mask(code, refs):
    b = bytearray(code)
    for spans in refs.values():
        for s in spans:
            b[s["start"]:s["start"] + s["length"]] = b"\0" * s["length"]
    return bytes(b)


def strip_metadata(code):
    n = int.from_bytes(code[-2:], "big")
    return code[:-(n + 2)] if 0 < n < len(code) - 2 else code


META_PREFIX = bytes.fromhex("a264697066735822")  # CBOR map {"ipfs": <34-byte multihash>, "solc": <3 bytes>} as solc 0.8 writes it
META_SUFFIX = bytes.fromhex("64736f6c6343")


def zero_metadata_hashes(code):
    """Zero the 34-byte ipfs hash of every metadata blob in `code`, the trailing one and any carried inside (a contract that
    creates another contract holds that contract's creation code, metadata included). The hash depends on the checkout path;
    the solc version bytes next to it are kept."""
    b, i = bytearray(code), 0
    while True:
        i = code.find(META_PREFIX, i)
        if i < 0:
            return bytes(b)
        j = i + len(META_PREFIX)
        if code[j + 34:j + 34 + len(META_SUFFIX)] == META_SUFFIX:
            b[j:j + 34] = b"\0" * 34
        i = j


def portable(code):
    """What two hosts building the same source must agree on: the code without metadata anywhere."""
    return zero_metadata_hashes(strip_metadata(code))


def addr_word(h):
    return "0x" + h[-40:]

ZERO = "0x" + "0" * 40


def read_wiring(get, sel):
    """Read every wiring value through getters. A getter the artifact does not have, or that returns nothing, raises:
    a check can never pass because its value was not read (Codex review 5462466632, the lens.pool false positive)."""
    need = {"pool": ("usdc()", "owner()", "effrRate()", "riskPremium()", "maxLoanAmount()", "ORIGINATOR()"),
            "lens": ("credit()",),
            "router": ("pool()", "token()", "officer()", "officerAdmin()")}
    for role, fns in need.items():
        for fn in fns:
            if fn not in sel[role]:
                raise SystemExit(f"{role} artifact has no {fn}: the wiring cannot be verified")
    w = {"pool.usdc": addr_word(get("pool", "usdc()")), "pool.owner": addr_word(get("pool", "owner()"))}
    for fn in ("effrRate()", "riskPremium()", "maxLoanAmount()"):
        w["pool." + fn] = int(get("pool", fn), 16)
    w["lens.credit"] = addr_word(get("lens", "credit()"))  # MicrocreditLens names the pool `credit`
    w["router.pool"], w["router.token"] = addr_word(get("router", "pool()")), addr_word(get("router", "token()"))
    w["pool.ORIGINATOR"] = addr_word(get("pool", "ORIGINATOR()"))
    w["router.officer"] = addr_word(get("router", "officer()"))  # zero until the admin names one: nothing originates before that
    w["router.officerAdmin"] = addr_word(get("router", "officerAdmin()"))
    return w


def wiring_checks(w, chain_id, pool, router):
    """Every entry is a strict comparison of a value that was read; a missing or zero link fails."""
    def same(x, y):
        return isinstance(x, str) and isinstance(y, str) and x.lower() == y.lower() and x.lower() != ZERO
    return {
        "pool.usdc == Circle Base Sepolia USDC (chain 84532 only)": chain_id != 84532 or w.get("pool.usdc") == USDC_BASE_SEPOLIA,
        "router.pool == pool": same(w.get("router.pool"), pool),
        "pool.ORIGINATOR == router (the pool admits no other originator, for any borrower)": same(w.get("pool.ORIGINATOR"), router),
        "router.token == pool.usdc": same(w.get("router.token"), w.get("pool.usdc")),
        "lens.credit == pool (the lens reads this pool)": same(w.get("lens.credit"), pool),
        "pool params 433/500/100e6": (w.get("pool.effrRate()"), w.get("pool.riskPremium()"), w.get("pool.maxLoanAmount()")) == (433, 500, 100_000_000),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rpc", required=True)
    for k in CONTRACTS:
        ap.add_argument(f"--{k}", required=True)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "packages", "foundry", "out"))
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    report, ok = {"rpc_chain_id": int(rpc(a.rpc, "eth_chainId", []), 16), "contracts": {}, "wiring": {}}, True
    sel = {}
    for role, (file, name) in CONTRACTS.items():
        art = json.load(open(os.path.join(a.out, file, f"{name}.json")))
        sel[role] = art["methodIdentifiers"]
        onchain = bytes.fromhex(rpc(a.rpc, "eth_getCode", [getattr(a, role), "latest"])[2:])
        built = bytes.fromhex(art["deployedBytecode"]["object"][2:])
        refs = art["deployedBytecode"]["immutableReferences"]
        m_on, m_built = mask(onchain, refs), mask(built, refs)
        strict = m_on == m_built
        nometa = portable(m_on) == portable(m_built)
        imm = {}
        for ast, spans in refs.items():
            vals = {onchain[s["start"]:s["start"] + s["length"]].hex() for s in spans}
            imm[ast] = sorted(vals)[0] if len(vals) == 1 else sorted(vals)
        report["contracts"][role] = {
            "address": getattr(a, role), "onchain_bytes": len(onchain), "eip170_margin": 24576 - len(onchain),
            "masked_sha256_onchain": hashlib.sha256(m_on).hexdigest(), "masked_sha256_build": hashlib.sha256(m_built).hexdigest(),
            # the CBOR trailer carries the compiler's metadata hash, which depends on the checkout path: compare hosts on this one
            "masked_nometa_sha256_onchain": hashlib.sha256(portable(m_on)).hexdigest(),
            "masked_nometa_sha256_build": hashlib.sha256(portable(m_built)).hexdigest(),
            "match_strict": strict, "match_ignoring_metadata": nometa, "immutables": imm,
            "abi_sha256": hashlib.sha256(json.dumps(art["abi"], sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
        }
        ok &= nometa and len(onchain) <= 24576

    def get(role, fn, args=""):
        return call(a.rpc, getattr(a, role), "0x" + sel[role][fn], args)

    w = report["wiring"]
    w.update(read_wiring(get, sel))
    checks = wiring_checks(w, report["rpc_chain_id"], a.pool, a.router)
    report["checks"] = checks
    ok &= all(checks.values())
    report["ok"] = ok
    if a.json:
        print(json.dumps(report, indent=1))
    else:
        for role, c in report["contracts"].items():
            print(f"{role:7} {c['address']} {c['onchain_bytes']:>6} B (margin {c['eip170_margin']}) strict={c['match_strict']} no-metadata={c['match_ignoring_metadata']} masked-sha256 {c['masked_sha256_onchain'][:16]} abi-sha256 {c['abi_sha256'][:16]}")
        for k, v in checks.items():
            print(("PASS " if v else "FAIL ") + k)
        print("OK" if ok else "MISMATCH")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
