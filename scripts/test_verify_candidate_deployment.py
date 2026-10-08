import unittest
import verify_candidate_deployment as v


class VerifyTest(unittest.TestCase):
    def test_mask_zeroes_only_the_immutable_spans(self):
        code = bytes(range(1, 21))
        out = v.mask(code, {"7": [{"start": 2, "length": 4}], "9": [{"start": 10, "length": 2}]})
        self.assertEqual(out[:2], code[:2])
        self.assertEqual(out[2:6], b"\0\0\0\0")
        self.assertEqual(out[6:10], code[6:10])
        self.assertEqual(out[10:12], b"\0\0")
        self.assertEqual(out[12:], code[12:])

    def test_strip_metadata_drops_the_cbor_trailer(self):
        body = b"\x60\x80\x60\x40" * 4
        meta = b"\xa2\x64ipfs"  # 6 bytes of metadata
        code = body + meta + len(meta).to_bytes(2, "big")
        self.assertEqual(v.strip_metadata(code), body)

    def test_strip_metadata_ignores_a_nonsense_length(self):
        code = b"\x01\x02\x03\xff\xff"
        self.assertEqual(v.strip_metadata(code), code)

    def test_two_builds_differing_only_in_metadata_match_without_it(self):
        body = b"\x60\x80" * 8
        a = body + b"\xa1AAAA" + (5).to_bytes(2, "big")
        b = body + b"\xa1BBBB" + (5).to_bytes(2, "big")
        self.assertNotEqual(a, b)
        self.assertEqual(v.strip_metadata(a), v.strip_metadata(b))


POOL = "0x" + "11" * 20
OTHER = "0x" + "22" * 20
ROUTER = "0x" + "33" * 20
USDC = "0x" + "44" * 20
ZERO = "0x" + "00" * 20


def good_wiring():
    return {"pool.usdc": USDC, "router.pool": POOL, "router.token": USDC, "pool.ORIGINATOR": ROUTER, "lens.credit": POOL,
            "pool.effrRate()": 433, "pool.riskPremium()": 500, "pool.maxLoanAmount()": 100_000_000}


def word(addr):
    return "0x" + "0" * 24 + addr[2:]


class WiringTest(unittest.TestCase):
    """Codex review 5462466632: the lens check was vacuous (a missing `pool()` getter read as success)."""

    def checks(self, w, chain_id=1):
        return v.wiring_checks(w, chain_id, POOL, ROUTER)

    def test_a_correctly_wired_candidate_passes_every_check(self):
        self.assertTrue(all(self.checks(good_wiring()).values()))

    def test_a_lens_wired_to_another_pool_is_rejected(self):
        w = good_wiring()
        w["lens.credit"] = OTHER
        c = self.checks(w)
        self.assertFalse(c["lens.credit == pool (the lens reads this pool)"])
        self.assertFalse(all(c.values()))

    def test_a_missing_or_zero_lens_link_cannot_pass(self):
        for bad in (None, ZERO, ""):
            w = good_wiring()
            w["lens.credit"] = bad
            self.assertFalse(self.checks(w)["lens.credit == pool (the lens reads this pool)"], bad)
        w = good_wiring()
        del w["lens.credit"]
        self.assertFalse(self.checks(w)["lens.credit == pool (the lens reads this pool)"])

    def test_the_lens_check_is_case_insensitive_on_the_address(self):
        w = good_wiring()
        w["lens.credit"] = POOL.upper().replace("0X", "0x")
        self.assertTrue(self.checks(w)["lens.credit == pool (the lens reads this pool)"])

    def test_another_originator_or_router_pool_is_rejected(self):
        for key in ("pool.ORIGINATOR", "router.pool"):
            w = good_wiring()
            w[key] = OTHER
            self.assertFalse(all(self.checks(w).values()), key)

    def test_the_pool_may_not_name_the_zero_address_as_originator_when_the_router_is_zero(self):
        w = good_wiring()
        w["pool.ORIGINATOR"] = ZERO
        c = v.wiring_checks(w, 1, POOL, ZERO)
        self.assertFalse(all(c.values()))

    def test_read_wiring_reads_credit_and_fails_closed_without_the_getter(self):
        sel = {"pool": {fn: "00000000" for fn in ("usdc()", "owner()", "effrRate()", "riskPremium()", "maxLoanAmount()", "ORIGINATOR()")},
               "lens": {"credit()": "00000000"},
               "router": {fn: "00000000" for fn in ("pool()", "token()", "officer()", "officerAdmin()")}}
        values = {("pool", "usdc()"): word(USDC), ("pool", "owner()"): word(OTHER), ("pool", "effrRate()"): hex(433),
                  ("pool", "riskPremium()"): hex(500), ("pool", "maxLoanAmount()"): hex(100_000_000),
                  ("pool", "ORIGINATOR()"): word(ROUTER), ("lens", "credit()"): word(OTHER), ("router", "pool()"): word(POOL),
                  ("router", "token()"): word(USDC), ("router", "officer()"): word(ZERO), ("router", "officerAdmin()"): word(OTHER)}
        w = v.read_wiring(lambda role, fn, args="": values[(role, fn)], sel)
        self.assertEqual(w["lens.credit"].lower(), OTHER)
        self.assertFalse(all(v.wiring_checks(w, 1, POOL, ROUTER).values()))  # the lens reads another pool
        del sel["lens"]["credit()"]  # the old artifact shape: a lens with no such getter must stop the run, not pass
        with self.assertRaises(SystemExit):
            v.read_wiring(lambda role, fn, args="": values[(role, fn)], sel)


if __name__ == "__main__":
    unittest.main()
