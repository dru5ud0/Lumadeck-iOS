import importlib.util
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "lumadeck_ios_lab.py"
SPEC = importlib.util.spec_from_file_location("lumadeck_ios_lab", SCRIPT_PATH)
assert SPEC and SPEC.loader
LAB = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LAB)


class RecordingLab(LAB.IPhoneLab):
    def __init__(self) -> None:
        self.instructions = []

    def gesture_session(self, instructions):
        self.instructions = instructions


class IPhoneLabTests(unittest.TestCase):
    def test_unlock_builds_one_secret_free_hid_session(self):
        lab = RecordingLab()

        lab.unlock("1209")

        self.assertEqual("drag 32768 59000 32768 17000 30 0.45", lab.instructions[0])
        self.assertEqual(10, len(lab.instructions))
        self.assertNotIn("1209", "\n".join(lab.instructions))

    def test_unlock_rejects_non_numeric_passcodes(self):
        lab = RecordingLab()

        with self.assertRaises(LAB.LabError):
            lab.unlock("12a4")

    def test_hid_coordinate_range_is_enforced(self):
        for invalid in (-1, 65536):
            with self.assertRaises(LAB.LabError):
                LAB.IPhoneLab._validate_coordinate(invalid)

    def test_evidence_root_is_under_workspace_loot(self):
        expected = LAB.WORKSPACE_ROOT / "loot" / "logs" / "lumadeck-ios"
        self.assertEqual(expected, LAB.DEFAULT_EVIDENCE_ROOT)


if __name__ == "__main__":
    unittest.main()
