#!/usr/bin/env python3
"""Tests for check-main-actor-fs.py. Standard library only.

    python3 macapp/Scripts/check-main-actor-fs_test.py

Each case runs the real script as a subprocess against a throwaway source root and allowlist.
"""

import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "check-main-actor-fs.py")


class CheckTests(unittest.TestCase):
    def run_check(self, source, allowlist=""):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "VersionControl"))
            os.makedirs(os.path.join(root, "AppShell"))
            with open(os.path.join(root, "VersionControl", "Model.swift"), "w") as f:
                f.write(source)
            allow = os.path.join(root, "allow.txt")
            with open(allow, "w") as f:
                f.write(allowlist)
            r = subprocess.run([sys.executable, SCRIPT, "--root", root, "--allowlist", allow],
                               capture_output=True, text=True)
            return r.returncode, r.stderr

    def test_a_main_actor_stat_fails_naming_the_fix(self):
        code, err = self.run_check(
            "@MainActor final class M {\n  func f(_ p: String) -> Bool {\n"
            "    FileManager.default\n      .fileExists(atPath: p)\n  }\n}\n")
        self.assertEqual(code, 1)
        self.assertIn("VersionControl/Model.swift:4: `fileExists` in `f`", err)
        self.assertIn("GitRepositoryProbe.blockingRead", err)

    def test_every_listed_call_is_caught(self):
        calls = ["realpath(p, nil)", "fm.attributesOfItem(atPath: p)",
                 "fm.contentsOfDirectory(atPath: p)", "try await RepositoryLocation.local(p)",
                 "url.resolvingSymlinksInPath()", "URL(fileURLWithPath: p).resourceValues(forKeys: [])",
                 "VCSStatusService.canonicalPath(p)"]
        body = "".join(f"  func f{i}() {{ {c} }}\n" for i, c in enumerate(calls))
        code, err = self.run_check("final class M {\n" + body + "}\n")
        self.assertEqual(code, 1)
        self.assertIn(f"{len(calls)} problem(s)", err)

    def test_comments_and_strings_are_not_calls(self):
        code, err = self.run_check(
            "/// Uses `realpath(3)` and `FileManager.default.fileExists(atPath:)`.\n"
            "func f() { let key = \"realpath(\\(p))\" /* resourceValues( */ }\n")
        self.assertEqual((code, err), (0, ""))

    def test_a_bounded_read_closure_passes(self):
        code, err = self.run_check(
            "func f(_ p: String) async {\n"
            "  _ = await GitRepositoryProbe.blockingRead(\"k\", timeout: 3, {\n"
            "    FileManager.default.fileExists(atPath: p)\n  })\n"
            "  _ = await Self.boundedRead(\"k\", timeout: 3) {\n"
            "    if true { try? await RepositoryLocation.local(p) } else { nil }\n  }\n}\n")
        self.assertEqual((code, err), (0, ""))

    def test_a_block_after_a_finished_bounded_read_is_checked(self):
        code, _ = self.run_check(
            "func f(_ p: String) async {\n"
            "  let a = await GitRepositoryProbe.blockingRead(\"k\", timeout: 3, work)\n"
            "  if a == nil { _ = FileManager.default.fileExists(atPath: p) }\n}\n")
        self.assertEqual(code, 1)

    def test_nonisolated_alone_is_not_an_exemption(self):
        code, _ = self.run_check(
            "nonisolated static func f(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }\n")
        self.assertEqual(code, 1)

    def test_an_allowlisted_call_passes_and_a_stale_entry_fails(self):
        source = "final class M {\n  var home = VCSStatusService.canonicalPath(NSHomeDirectory())\n}\n"
        entry = "VersionControl/Model.swift | home | canonicalPath | known: the home folder\n"
        self.assertEqual(self.run_check(source, entry), (0, ""))
        code, err = self.run_check("final class M {}\n", entry)
        self.assertEqual(code, 1)
        self.assertIn("stale entry", err)


if __name__ == "__main__":
    unittest.main()
