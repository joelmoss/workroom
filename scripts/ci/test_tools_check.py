"""tools_check reads the repo's pins and reports tools against them."""

import re
import unittest

from makevars import make_value
import tools_check as tc


class PinParsingTests(unittest.TestCase):
    def test_every_pin_is_read_from_the_repo(self):
        pins = tc.parse_pins()
        self.assertRegex(pins["go"], r"^\d+\.\d+(\.\d+)?$")
        self.assertEqual(pins["rust"], make_value("VCS_RUST"))
        for name in ("golangci-lint", "shellcheck", "jactionlint"):
            with self.subTest(name=name):
                self.assertRegex(pins[name], r"^\d+\.\d+\.\d+$")
        self.assertRegex(pins["xcode"], r"^\d+(\.\d+)*$")

    def test_go_pin_matches_go_mod(self):
        go_mod = tc.read("go.mod")
        self.assertEqual(tc.parse_pins()["go"], re.search(r"^go (\S+)$", go_mod, re.M)[1])


class CompareTests(unittest.TestCase):
    def test_same_version_is_ok(self):
        self.assertEqual(tc.compare("t", "1.2.3", "1.2.3", "h")[0], tc.OK)

    def test_two_part_pin_accepts_any_patch(self):
        self.assertEqual(tc.compare("t", "1.27.3", "1.27", "h")[0], tc.OK)
        self.assertEqual(tc.compare("t", "1.270.3", "1.27", "h")[0], tc.MISMATCH)

    def test_missing_and_mismatch_fail(self):
        self.assertEqual(tc.compare("t", None, "1.2.3", "h")[0], tc.MISSING)
        status, line = tc.compare("t", "1.2.2", "1.2.3", "install t 1.2.3")
        self.assertEqual(status, tc.MISMATCH)
        self.assertIn("local 1.2.2, pinned 1.2.3", line)

    def test_newer_is_a_note_only_when_allowed(self):
        self.assertEqual(tc.compare("t", "27.2", "27.1", "h", newer_is_note=True)[0], tc.NOTE)
        self.assertEqual(tc.compare("t", "27.2", "27.1", "h")[0], tc.MISMATCH)
        self.assertEqual(tc.compare("t", "26.9", "27.1", "h", newer_is_note=True)[0],
                         tc.MISMATCH)


if __name__ == "__main__":
    unittest.main()
