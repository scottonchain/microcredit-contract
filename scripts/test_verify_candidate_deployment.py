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


if __name__ == "__main__":
    unittest.main()
