import importlib.util
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "lumadeck_airplay_origin.py"
SPEC = importlib.util.spec_from_file_location("lumadeck_airplay_origin", SCRIPT_PATH)
assert SPEC and SPEC.loader
ORIGIN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ORIGIN)


class RangeTests(unittest.TestCase):
    def test_closed_range(self):
        self.assertEqual((2, 5), ORIGIN.parse_range("bytes=2-5", 10))

    def test_open_range(self):
        self.assertEqual((7, 9), ORIGIN.parse_range("bytes=7-", 10))

    def test_suffix_range(self):
        self.assertEqual((6, 9), ORIGIN.parse_range("bytes=-4", 10))

    def test_end_is_clamped(self):
        self.assertEqual((8, 9), ORIGIN.parse_range("bytes=8-99", 10))

    def test_invalid_ranges(self):
        for value in (None, "items=0-1", "bytes=10-11", "bytes=x-y", "bytes=4-2"):
            self.assertIsNone(ORIGIN.parse_range(value, 10))


if __name__ == "__main__":
    unittest.main()
