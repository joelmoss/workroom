#!/usr/bin/env python3
"""Tests for check-test-windows.py. Standard library only.

    python3 macapp/Scripts/check-test-windows_test.py

Each case runs the real script as a subprocess against a throwaway test root.
"""

import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "check-test-windows.py")


class CheckTests(unittest.TestCase):
    def run_check(self, files):
        with tempfile.TemporaryDirectory() as root:
            for relative, source in files.items():
                path = os.path.join(root, relative)
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w") as f:
                    f.write(source)
            r = subprocess.run([sys.executable, SCRIPT, "--root", root],
                               capture_output=True, text=True)
            return r.returncode, r.stderr

    def test_each_plain_call_fails_with_its_place(self):
        for call in ("window.orderFront(nil)", "window.orderFrontRegardless()",
                     "window.makeKeyAndOrderFront(nil)"):
            with self.subTest(call=call):
                code, err = self.run_check({"PaneTests.swift": f"func f() {{\n  {call}\n}}\n"})
                self.assertEqual(code, 1)
                self.assertIn("PaneTests.swift:2", err)
                self.assertIn("showTestWindow", err)

    def test_a_nested_file_is_scanned(self):
        code, err = self.run_check({"Glass/GlassTests.swift": "w.orderFrontRegardless()\n"})
        self.assertEqual(code, 1)
        self.assertIn(os.path.join("Glass", "GlassTests.swift") + ":1", err)

    def test_the_helpers_pass(self):
        code, _ = self.run_check({
            "PaneTests.swift": "showTestWindow(window, makeKey: true)\n"
                               "showTestWindowVisibly(cover, because: \"occlusion\")\n",
        })
        self.assertEqual(code, 0)

    def test_the_helper_file_may_order_windows(self):
        code, _ = self.run_check({
            os.path.join("Support", "TestWindows.swift"): "window.orderFrontRegardless()\n",
        })
        self.assertEqual(code, 0)

    def test_a_comment_naming_a_call_passes(self):
        code, _ = self.run_check({
            "PaneTests.swift": "// never window.orderFront(nil) here\nlet x = 1  // orderFront(\n",
        })
        self.assertEqual(code, 0)

    def test_a_call_after_a_string_holding_slashes_fails(self):
        code, err = self.run_check({
            "PaneTests.swift": 'let url = "https://x"; w.orderFront(nil)\n',
        })
        self.assertEqual(code, 1)
        self.assertIn("PaneTests.swift:1", err)

    def test_a_string_naming_a_call_passes(self):
        code, _ = self.run_check({"PaneTests.swift": 'let s = "w.orderFront(nil)"\n'})
        self.assertEqual(code, 0)

    def test_a_line_marked_allow_passes(self):
        code, _ = self.run_check({
            "CloakTests.swift": "w.orderFront(nil)  // check-test-windows: allow (the cloak's test)\n",
        })
        self.assertEqual(code, 0)

    def test_the_mark_covers_only_its_own_line(self):
        code, err = self.run_check({
            "CloakTests.swift": "// check-test-windows: allow\nw.orderFront(nil)\n",
        })
        self.assertEqual(code, 1)
        self.assertIn("CloakTests.swift:2", err)

    def test_a_similar_name_passes(self):
        code, _ = self.run_check({"PaneTests.swift": "window.orderFrontWithAnimation()\n"})
        self.assertEqual(code, 0)


if __name__ == "__main__":
    unittest.main()
