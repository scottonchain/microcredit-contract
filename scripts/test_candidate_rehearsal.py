import json, os, re, unittest
import candidate_rehearsal as cr

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "packages", "foundry", "contracts")


def type_string(name, fields):
    return f"{name}(" + ",".join(f"{t} {n}" for n, t in fields) + ")"


def read_text(path):
    with open(path) as f:
        return f.read()


def source_string(file, constant):
    text = read_text(os.path.join(SRC, file))
    m = re.search(constant + r"\s*=\s*keccak256\(\s*\"([^\"]+)\"", text)
    return m.group(1)


class RehearsalTypedDataTest(unittest.TestCase):
    def test_pool_type_matches_the_contract(self):
        self.assertEqual(type_string("BorrowAndDisburse", cr.POOL_FIELDS),
                         source_string("DecentralizedMicrocredit.sol", "BORROW_AND_DISBURSE_TYPEHASH"))

    def test_consent_type_matches_the_router(self):
        self.assertEqual(type_string("EdgeConsent", cr.CONSENT_FIELDS),
                         source_string("TransitiveStakeRouter.sol", "CONSENT_TYPEHASH"))

    def test_accept_type_matches_the_order_router(self):
        self.assertEqual(type_string("AcceptOrder", cr.ACCEPT_FIELDS),
                         source_string("BootstrapOrderRouter.sol", "ACCEPT_TYPEHASH"))

    def test_approval_type_matches_the_order_router(self):
        self.assertEqual(type_string("JobApproval", cr.APPROVAL_FIELDS),
                         source_string("BootstrapOrderRouter.sol", "APPROVAL_TYPEHASH"))

    def test_intent_struct_matches_the_order_router(self):
        text = read_text(os.path.join(SRC, "BootstrapOrderRouter.sol"))
        body = re.search(r"struct Intent \{(.*?)\}", text, re.S).group(1)
        fields = [tuple(reversed(line.split("//")[0].strip().rstrip(";").split())) for line in body.splitlines() if line.strip() and not line.strip().startswith("//")]
        self.assertEqual([(n, t) for n, t in fields], cr.INTENT_FIELDS)

    def test_domains_match_the_constructors(self):
        pool = read_text(os.path.join(SRC, "DecentralizedMicrocredit.sol"))
        router = read_text(os.path.join(SRC, "BootstrapOrderRouter.sol"))
        self.assertIn('EIP712("DecentralizedMicrocredit", "1")', pool)
        self.assertIn('EIP712("BootstrapOrderRouter", "1")', router)
        self.assertEqual(cr.pool_domain(1, "0x1")["name"], "DecentralizedMicrocredit")
        self.assertEqual(cr.router_domain(1, "0x1")["name"], "BootstrapOrderRouter")
        self.assertEqual(cr.router_domain(1, "0x1")["version"], "1")

    def test_the_candidate_deploys_one_manager_and_no_unbound_router(self):
        deploy = read_text(os.path.join(SRC, "..", "script", "DeployBootstrapCandidate.s.sol"))
        self.assertIn("new BootstrapOrderRouter(pool)", deploy)
        self.assertIn("predictedRouter", deploy)
        self.assertNotIn("new TransitiveStakeRouter", deploy)
        self.assertNotIn("BootstrapOrderEscrow", deploy)

    def test_typed_data_shape(self):
        m = dict(zip([n for n, _ in cr.CONSENT_FIELDS], ["0xa", "0xb", "0xc", 5, 6, 0, 9]))
        td = cr.consent_typed(84532, "0xr", m)
        self.assertEqual(td["primaryType"], "EdgeConsent")
        self.assertEqual(td["message"]["limit"], "5")
        self.assertEqual([f["name"] for f in td["types"]["EdgeConsent"]], [n for n, _ in cr.CONSENT_FIELDS])


class WalletJsonTest(unittest.TestCase):
    """Foundry 1.5 prints a bare list, 1.8 wraps it; both must work (Hermes's reproduction on 1.8.4)."""

    ADDR, KEY = "0x" + "ab" * 20, "0x" + "cd" * 32

    def test_bare_list_from_foundry_1_5(self):
        out = json.dumps([{"address": self.ADDR, "private_key": self.KEY}])
        self.assertEqual(cr.new_wallet(out), {"address": self.ADDR, "private_key": self.KEY})

    def test_wrapped_data_from_foundry_1_8(self):
        out = json.dumps({"schema_version": "0.1", "success": True, "data": [{"address": self.ADDR, "private_key": self.KEY, "x": 1}]})
        self.assertEqual(cr.new_wallet(out), {"address": self.ADDR, "private_key": self.KEY})

    def test_a_single_object_is_accepted_and_garbage_fails_closed(self):
        self.assertEqual(cr.new_wallet(json.dumps({"address": self.ADDR, "private_key": self.KEY}))["address"], self.ADDR)
        for bad in ("[]", '{"data": []}', '{"data": [{"address": "0x1"}]}', "not json"):
            with self.assertRaises(Exception):
                cr.new_wallet(bad)


if __name__ == "__main__":
    unittest.main()
