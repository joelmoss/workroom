"""Exercise the Linux lint launcher without downloading images or starting containers."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
RUST = re.search(r"^VCS_RUST := (.+)$", (ROOT / "Makefile").read_text(), re.M)[1]
STUB = '''#!{python}
import hashlib, json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["LINT_TEST_LOG"], "a") as log:
    log.write(json.dumps([name, *args]) + "\\n")
if name == "uname":
    print(os.environ.get("LINT_TEST_OS", "Darwin") if args == ["-s"] else "arm64")
elif name == "shasum":
    sys.exit(127)
elif name == "sha256sum":
    print(hashlib.sha256(pathlib.Path(args[0]).read_bytes()).hexdigest(), args[0])
elif name in ("container", "docker", "podman"):
    if args[0] in ("system", "info"):
        sys.exit(1 if name in os.environ.get("LINT_TEST_OFF", "").split(",") else 0)
    sys.exit(int(os.environ.get("LINT_TEST_" + args[0].upper() + "_EXIT", "0")))
'''


class LinuxLintTests(unittest.TestCase):
    def run_launcher(self, **overrides):
        with tempfile.TemporaryDirectory(prefix="linux-lint-test-") as directory:
            fixture = Path(directory)
            binary = fixture / "bin"
            binary.mkdir()
            names = ["uname", "container", "docker", "podman", "make", "sha256sum"]
            if overrides.get("LINT_TEST_NO_SHASUM"):
                names.append("shasum")
            for name in names:
                path = binary / name
                path.write_text(STUB.format(python=sys.executable))
                path.chmod(0o755)
            env = os.environ.copy()
            env.update(PATH=f"{binary}:/usr/bin:/bin", XDG_CACHE_HOME=str(fixture / "cache"),
                       LINT_TEST_LOG=str(fixture / "calls.jsonl"), **overrides)
            result = subprocess.run(
                ["/bin/bash", str(ROOT / "vcs/scripts/lint-linux.sh"), RUST],
                env=env, capture_output=True, text=True, timeout=10,
            )
            calls = [json.loads(line) for line in (fixture / "calls.jsonl").read_text().splitlines()]
            return result, calls

    def test_native_linux_uses_canonical_gate(self):
        result, calls = self.run_launcher(LINT_TEST_OS="Linux")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(["make", "-C", str(ROOT), "vcs-lint", f"VCS_RUST={RUST}"], calls)
        self.assertFalse(any(call[0] == "container" for call in calls))

    def test_container_has_read_only_source_and_separate_caches(self):
        result, calls = self.run_launcher()
        self.assertEqual(result.returncode, 0, result.stderr)
        build = next(call for call in calls if call[:2] == ["container", "build"])
        run = next(call for call in calls if call[:2] == ["container", "run"])
        self.assertIn(f"RUST_VERSION={RUST}", build)
        self.assertIn(f"{ROOT}:/workroom:ro", run)
        self.assertIn("CARGO_HOME=/cache/cargo", run)
        self.assertIn("CARGO_TARGET_DIR=/cache/target", run)
        self.assertIn("GIT_CEILING_DIRECTORIES=/workroom", run)
        self.assertIn("--user", run)
        self.assertEqual(run[run.index("--memory") + 1], "4G")
        self.assertEqual(run[-4], build[build.index("--tag") + 1])
        self.assertEqual(run[-3:], ["make", "vcs-lint", f"VCS_RUST={RUST}"])

    def test_installed_but_stopped_runtime_falls_back(self):
        result, calls = self.run_launcher(LINT_TEST_OFF="container")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(call[:2] == ["docker", "run"] for call in calls))

    def test_sha256sum_fallback_is_available_to_linux_ci(self):
        result, calls = self.run_launcher(LINT_TEST_NO_SHASUM="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(call[0] == "sha256sum" for call in calls))

    def test_no_runtime_is_a_failure_not_a_skip(self):
        result, calls = self.run_launcher(LINT_TEST_OFF="container,docker,podman")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no working container runtime", result.stderr)
        self.assertFalse(any("build" in call or "run" in call for call in calls))

    def test_build_and_lint_failures_propagate(self):
        for phase, status in (("BUILD", 7), ("RUN", 9)):
            with self.subTest(phase=phase):
                result, calls = self.run_launcher(**{f"LINT_TEST_{phase}_EXIT": str(status)})
                self.assertEqual(result.returncode, status)
                if phase == "BUILD":
                    self.assertFalse(any(call[:2] == ["container", "run"] for call in calls))

    def test_zig_image_pins_match_engine_and_ci(self):
        engine = (ROOT / "vcs/scripts/build-ghostty-vt.sh").read_text()
        version = re.search(r'^ZIG_VERSION="([^"]+)"', engine, re.M)[1]
        image = (ROOT / "vcs/scripts/linux-lint/Dockerfile").read_text()
        for arch in ("aarch64", "x86_64"):
            self.assertIn(f"{version}/{arch})", image)
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        checksum = re.search(r'archive: x86_64-linux\s+sha256: "([a-f0-9]{64})"', ci)[1]
        self.assertIn(checksum, image)

    def test_discovery_ceiling_handles_host_only_worktree_metadata(self):
        with tempfile.TemporaryDirectory(prefix="linux-lint-git-") as directory:
            fixture = Path(directory)
            checkout = fixture / "checkout"
            nested = checkout / "vcs"
            nested.mkdir(parents=True)
            (checkout / ".git").write_text(f"gitdir: {fixture}/not-mounted/worktrees/dev\n")
            remote = fixture / "remote.git"
            subprocess.run(["git", "init", "--bare", "-q", str(remote)], check=True)
            command = ["git", "ls-remote", str(remote)]
            broken = subprocess.run(command, cwd=nested, capture_output=True)
            self.assertNotEqual(broken.returncode, 0)
            env = os.environ.copy()
            env["GIT_CEILING_DIRECTORIES"] = str(checkout)
            fixed = subprocess.run(command, cwd=nested, env=env, capture_output=True)
            self.assertEqual(fixed.returncode, 0, fixed.stderr.decode())


if __name__ == "__main__":
    unittest.main()
