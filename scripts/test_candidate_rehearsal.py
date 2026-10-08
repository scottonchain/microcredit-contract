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

    def test_accept_type_matches_the_order_router(self):
        self.assertEqual(type_string("AcceptOrder", cr.ACCEPT_FIELDS),
                         source_string("BootstrapOrderRouter.sol", "ACCEPT_TYPEHASH"))

    def test_approval_type_matches_the_order_router(self):
        self.assertEqual(type_string("JobApproval", cr.APPROVAL_FIELDS),
                         source_string("BootstrapOrderRouter.sol", "APPROVAL_TYPEHASH"))

    def test_intent_struct_matches_the_order_router(self):
        text = open(os.path.join(SRC, "BootstrapOrderRouter.sol")).read()
        body = re.search(r"struct Intent \{(.*?)\}", text, re.S).group(1)
        fields = [tuple(reversed(line.split("//")[0].strip().rstrip(";").split())) for line in body.splitlines() if line.strip() and not line.strip().startswith("//")]
        self.assertEqual([(n, t) for n, t in fields], cr.INTENT_FIELDS)

    def test_domains_match_the_constructors(self):
        pool = open(os.path.join(SRC, "DecentralizedMicrocredit.sol")).read()
        router = open(os.path.join(SRC, "BootstrapOrderRouter.sol")).read()
        self.assertIn('EIP712("DecentralizedMicrocredit", "1")', pool)
        self.assertIn('EIP712("BootstrapOrderRouter", "1")', router)
        self.assertEqual(cr.pool_domain(1, "0x1")["name"], "DecentralizedMicrocredit")
        self.assertEqual(cr.router_domain(1, "0x1")["name"], "BootstrapOrderRouter")
        self.assertEqual(cr.router_domain(1, "0x1")["version"], "1")

    def test_the_candidate_deploys_one_manager_and_no_unbound_router(self):
        deploy = open(os.path.join(SRC, "..", "script", "DeployBootstrapCandidate.s.sol")).read()
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


if __name__ == "__main__":
    unittest.main()
