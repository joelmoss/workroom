#!/usr/bin/env python3
"""Keep standalone Swift benchmarks' invalid-state checks out of crash reporting."""

import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CRASH_CALL = re.compile(
    r"\b(?:fatalError|precondition(?:Failure)?|assert(?:ionFailure)?)\s*\("
)


def crash_calls(source):
    return [
        (source.count("\n", 0, match.start()) + 1, match.group().strip())
        for match in CRASH_CALL.finditer(source)
    ]


class BenchmarkSafetyTests(unittest.TestCase):
    def test_benchmark_sources_use_normal_error_exits(self):
        sources = sorted((ROOT / "macapp/Benchmarks").rglob("*.swift"))
        self.assertTrue(sources, "No benchmark sources found; the guard would check nothing")
        violations = [
            f"{path.relative_to(ROOT)}:{line}: {call}: use fail/require with a normal error exit"
            for path in sources
            for line, call in crash_calls(path.read_text())
        ]
        self.assertEqual(violations, [], "\n".join(violations))

    def test_guard_rejects_crash_calls(self):
        for name in ("fatalError", "precondition", "preconditionFailure", "assert", "assertionFailure"):
            with self.subTest(name=name):
                self.assertEqual(len(crash_calls(f'Swift.{name}\n  ("invalid state")')), 1)
        self.assertEqual(crash_calls('require(false, "invalid state")'), [])

    def test_invalid_state_exits_with_error_report(self):
        # Compile the real failure path without AppKit or Sentry. No window, telemetry,
        # GUI lock, app build or installed SDK is needed to check the exit contract.
        failure_source = ROOT / "macapp/Benchmarks/Sentry/Failure.swift"
        self.assertEqual(crash_calls(failure_source.read_text()), [], "Refusing to run crash calls")
        with tempfile.TemporaryDirectory(prefix="benchmark-safety-") as directory:
            fixture = Path(directory)
            main = fixture / "main.swift"
            main.write_text(
                'require(CommandLine.arguments.count == 3, "Expected state and report path")\n'
                'require(CommandLine.arguments[1] == "valid", "Invalid fixture state")\n'
            )
            executable = fixture / "failure-probe"
            build = subprocess.run([
                "xcrun", "swiftc", "-O", "-swift-version", "6",
                str(failure_source), str(main),
                "-o", str(executable),
            ], capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            for state, status in (("valid", 0), ("invalid", 2)):
                with self.subTest(state=state):
                    report = fixture / f"{state} report.json"
                    result = subprocess.run(
                        [str(executable), state, str(report)],
                        capture_output=True, text=True, timeout=10,
                    )
                    self.assertEqual(result.returncode, status, result.stderr)
                    self.assertFalse(report.exists(), "Failed checks must not write a measurement")
                    error_report = Path(str(report) + ".error.json")
                    if state == "invalid":
                        self.assertEqual(
                            json.loads(error_report.read_text()), {"error": "Invalid fixture state"}
                        )
                        self.assertIn("Invalid fixture state", result.stderr)
                    else:
                        self.assertFalse(error_report.exists())
                        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
