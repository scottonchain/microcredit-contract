import os, re, unittest
import candidate_rehearsal as cr

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "packages", "foundry", "contracts")


def type_string(name, fields):
    return f"{name}(" + ",".join(f"{t} {n}" for n, t in fields) + ")"


def source_string(file, constant):
    text = open(os.path.join(SRC, file)).read()
    m = re.search(constant + r"\s*=\s*keccak256\(\s*\"([^\"]+)\"", text)
    return m.group(1)


class RehearsalTypedDataTest(unittest.TestCase):
    def test_pool_type_matches_the_contract(self):
        self.assertEqual(type_string("BorrowAndDisburse", cr.POOL_FIELDS),
                         source_string("DecentralizedMicrocredit.sol", "BORROW_AND_DISBURSE_TYPEHASH"))

    def test_consent_type_matches_the_router(self):
        self.assertEqual(type_string("EdgeConsent", cr.CONSENT_FIELDS),
                         source_string("TransitiveStakeRouter.sol", "CONSENT_TYPEHASH"))

    def test_domains_match_the_constructors(self):
        pool = open(os.path.join(SRC, "DecentralizedMicrocredit.sol")).read()
        router = open(os.path.join(SRC, "TransitiveStakeRouter.sol")).read()
        self.assertIn('EIP712("DecentralizedMicrocredit", "1")', pool)
        self.assertIn('EIP712("TransitiveStakeRouter", "1")', router)
        self.assertEqual(cr.pool_domain(1, "0x1")["name"], "DecentralizedMicrocredit")
        self.assertEqual(cr.router_domain(1, "0x1")["name"], "TransitiveStakeRouter")

    def test_typed_data_shape(self):
        m = dict(zip([n for n, _ in cr.CONSENT_FIELDS], ["0xa", "0xb", "0xc", 5, 6, 0, 9]))
        td = cr.consent_typed(84532, "0xr", m)
        self.assertEqual(td["primaryType"], "EdgeConsent")
        self.assertEqual(td["message"]["limit"], "5")
        self.assertEqual([f["name"] for f in td["types"]["EdgeConsent"]], [n for n, _ in cr.CONSENT_FIELDS])


if __name__ == "__main__":
    unittest.main()
