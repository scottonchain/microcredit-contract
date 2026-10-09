"""Transport failures must not masquerade as evidence of a contract revert."""
import io
import json
import unittest
import urllib.error
from unittest.mock import patch

import rpc_client as r
import candidate_fork as f


class RpcTest(unittest.TestCase):
    def response(self, payload):
        return patch("rpc_client.urllib.request.urlopen", return_value=io.BytesIO(json.dumps(payload).encode()))

    def test_success_and_null_result(self):
        for result in ("0x14a34", None):
            with self.response({"jsonrpc": "2.0", "id": 1, "result": result}) as request:
                self.assertEqual(r.rpc("http://localhost:8545", "eth_chainId", []), result)
                body = json.loads(request.call_args.args[0].data)
                self.assertEqual(body["method"], "eth_chainId")
                self.assertEqual(body["params"], [])

    def test_revert_data_is_preserved(self):
        with self.response({"jsonrpc": "2.0", "id": 1, "error": {"code": 3, "message": "execution reverted", "data": "0x12345678"}}):
            with self.assertRaises(r.RpcError) as raised:
                r.rpc("http://localhost:8545", "eth_call", [])
        self.assertEqual(raised.exception.data, "0x12345678")
        self.assertEqual(raised.exception.code, 3)

    def test_malformed_or_mismatched_envelopes_fail(self):
        for response in ([], None, {}, {"jsonrpc": "2.0", "id": 2, "result": 1},
                         {"jsonrpc": "2.0", "id": 1}, {"jsonrpc": "2.0", "id": 1, "result": 1, "error": {}},
                         {"jsonrpc": "2.0", "id": 1, "error": "bad"}):
            with self.subTest(response=response), self.response(response), self.assertRaises(r.RpcError):
                r.rpc("http://localhost:8545", "eth_call", [])

    def test_transport_failure_does_not_echo_provider_credentials_or_carry_revert_data(self):
        error = urllib.error.URLError("https://example.invalid/private-provider-credential")
        with patch("rpc_client.urllib.request.urlopen", side_effect=error), self.assertRaises(r.RpcError) as raised:
            r.rpc("https://example.invalid/private-provider-credential", "eth_call", [])
        self.assertNotIn("private-provider-credential", str(raised.exception))
        self.assertIsNone(raised.exception.data)

    def test_non_json_failure(self):
        with patch("rpc_client.urllib.request.urlopen", return_value=io.BytesIO(b"not JSON")), self.assertRaisesRegex(r.RpcError, "did not return JSON"):
            r.rpc("http://localhost:8545", "eth_call", [])

    def test_fork_probe_requires_base_sepolia(self):
        for result, expected in (("0x14a34", True), ("0x7a69", False), (None, False), ("garbage", False)):
            with patch("candidate_fork.rpc", return_value=result):
                self.assertEqual(f.chain_id_probe(8546), expected)

    def test_pinned_block_has_matching_number_and_hash(self):
        block = {"number": "0x7", "hash": "0x" + "a" * 64}
        with patch("candidate_fork.rpc", side_effect=["0xa", block]):
            self.assertEqual(f.pinned_block("unused", 3), (7, block["hash"]))
        for bad in (None, {**block, "number": "0x8"}, {**block, "hash": None}):
            with patch("candidate_fork.rpc", side_effect=["0xa", bad]), self.assertRaises(f.ForkError):
                f.pinned_block("unused", 3)
        with self.assertRaises(f.ForkError):
            f.pinned_block("unused", -1)
        with patch("candidate_fork.rpc", return_value="0x1"), self.assertRaises(f.ForkError):
            f.pinned_block("unused", 3)


if __name__ == "__main__":
    unittest.main()
