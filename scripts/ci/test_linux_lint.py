"""Exercise the Linux lint launcher without downloading images or starting containers."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

from makevars import make_value


ROOT = Path(__file__).resolve().parents[2]
RUST = make_value("VCS_RUST")
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
    # A file argument, or standard input when there is none, as the real tool reads.
    data = pathlib.Path(args[0]).read_bytes() if args else sys.stdin.buffer.read()
    print(hashlib.sha256(data).hexdigest(), args[0] if args else "-")
elif name in ("container", "docker", "podman"):
    if args[0] in ("system", "info"):
        sys.exit(1 if name in os.environ.get("LINT_TEST_OFF", "").split(",") else 0)
    sys.exit(int(os.environ.get("LINT_TEST_" + args[0].upper() + "_EXIT", "0")))
'''


def copy_checkout(into):
    """A checkout holding just what the launcher reads, at `into`; its launcher's path."""
    for relative in ("vcs/scripts/lint-linux.sh", "vcs/scripts/build-ghostty-vt.sh",
                     "vcs/scripts/linux-lint/Dockerfile"):
        target = into / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((ROOT / relative).read_bytes())
    return into / "vcs/scripts/lint-linux.sh"


def env_of(run):
    return dict(run[i + 1].split("=", 1) for i, arg in enumerate(run) if arg == "--env")


class LinuxLintTests(unittest.TestCase):
    def run_launcher(self, *gate, launcher=None, files=None, **overrides):
        """Runs the launcher with stubbed tools: its result and every stub call. `files`, when
        given, is filled with the text of each file the container run mounts from the cache."""
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
            env.pop("WR_LINT_RUNTIME", None)
            env.update(PATH=f"{binary}:/usr/bin:/bin", XDG_CACHE_HOME=str(fixture / "cache"),
                       LINT_TEST_LOG=str(fixture / "calls.jsonl"), **overrides)
            result = subprocess.run(
                ["/bin/bash", str(launcher or ROOT / "vcs/scripts/lint-linux.sh"), RUST, *gate],
                env=env, capture_output=True, text=True, timeout=10,
            )
            log = fixture / "calls.jsonl"
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            if files is not None:
                for call in calls:
                    for i, arg in enumerate(call[:-1]):
                        source = call[i + 1].split(":", 1)[0]
                        if arg == "--volume" and source.startswith(str(fixture / "cache")):
                            if Path(source).is_file():
                                files[call[i + 1]] = Path(source).read_text()
            return result, calls

    def test_native_linux_uses_canonical_gate(self):
        result, calls = self.run_launcher(LINT_TEST_OS="Linux")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(["make", "-C", str(ROOT), "vcs-lint", f"VCS_RUST={RUST}"], calls)
        self.assertFalse(any(call[0] == "container" for call in calls))

    def test_runtime_has_read_only_source_and_separate_caches(self):
        result, calls = self.run_launcher()
        self.assertEqual(result.returncode, 0, result.stderr)
        build = next(call for call in calls if call[:2] == ["docker", "build"])
        run = next(call for call in calls if call[:2] == ["docker", "run"])
        self.assertIn(f"RUST_VERSION={RUST}", build)
        self.assertIn(f"{ROOT}:/workroom:ro", run)
        self.assertIn("CARGO_HOME=/cache/cargo", run)
        self.assertRegex(env_of(run)["CARGO_TARGET_DIR"], r"^/cache/target-[0-9a-f]{12}$")
        self.assertIn("GIT_CEILING_DIRECTORIES=/workroom", run)
        self.assertIn("--user", run)
        self.assertEqual(run[run.index("--memory") + 1], "4G")
        self.assertEqual(run[-4], build[build.index("--tag") + 1])
        self.assertEqual(run[-3:], ["make", "vcs-lint", f"VCS_RUST={RUST}"])

    def test_each_checkout_builds_in_its_own_target_dir(self):
        # Every checkout mounts at /workroom, so in one shared target dir another workroom's older
        # build of a crate looked fresh to cargo (#832).
        with tempfile.TemporaryDirectory(prefix="linux-lint-checkouts-") as directory:
            first = copy_checkout(Path(directory) / "first")
            second = copy_checkout(Path(directory) / "second")
            targets = []
            for launcher in (first, second, first):
                result, calls = self.run_launcher(launcher=launcher)
                self.assertEqual(result.returncode, 0, result.stderr)
                run = next(call for call in calls if call[:2] == ["docker", "run"])
                targets.append(env_of(run)["CARGO_TARGET_DIR"])
            self.assertNotEqual(targets[0], targets[1])
            self.assertEqual(targets[0], targets[2])

    def test_the_container_user_has_an_account_entry(self):
        # The tests that read their own account entry, as a host's daemon does, need one for a
        # uid the image doesn't know (a Mac's 501).
        files = {}
        result, calls = self.run_launcher("vcs-test", files=files)
        self.assertEqual(result.returncode, 0, result.stderr)
        run = next(call for call in calls if call[:2] == ["docker", "run"])
        mounts = [run[i + 1] for i, arg in enumerate(run) if arg == "--volume"]
        passwd = next(mount for mount in mounts if mount.endswith(":/etc/passwd:ro"))
        entries = [line.split(":") for line in files[passwd].splitlines()]
        mine = [entry for entry in entries if entry[2] == str(os.getuid())]
        self.assertEqual(len(mine), 1, files[passwd])
        self.assertEqual(mine[0][3], str(os.getgid()))
        self.assertEqual(mine[0][5], "/cache/home")
        self.assertEqual(env_of(run)["HOME"], "/cache/home")
        self.assertIn(["root", "x", "0", "0", "root", "/root", "/bin/bash"], entries)

    def test_vcs_test_gate_runs_the_tests_with_their_flags(self):
        flags = "-p workroom --test resume_session"
        result, calls = self.run_launcher("vcs-test", VCS_TEST_FLAGS=flags)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("vcs-test-linux:", result.stdout)
        run = next(call for call in calls if call[:2] == ["docker", "run"])
        self.assertEqual(run[-4:], ["make", "vcs-test", f"VCS_RUST={RUST}", f"VCS_TEST_FLAGS={flags}"])
        self.assertIn("--user", run)

        result, calls = self.run_launcher("vcs-test", LINT_TEST_OS="Linux", VCS_TEST_FLAGS=flags)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(["make", "-C", str(ROOT), "vcs-test", f"VCS_RUST={RUST}",
                       f"VCS_TEST_FLAGS={flags}"], calls)

    def test_only_the_tests_cap_their_links_and_get_an_account_entry(self):
        # Linking every test binary at once outgrew the container's 4G (2026-11-27); the lint links
        # none, so it keeps cargo's default jobs, and the mounts it was proven with.
        for gate, jobs in ((), None), (("vcs-test",), "4"):
            with self.subTest(gate=gate):
                result, calls = self.run_launcher(*gate)
                self.assertEqual(result.returncode, 0, result.stderr)
                run = next(call for call in calls if call[:2] == ["docker", "run"])
                self.assertEqual(env_of(run).get("CARGO_BUILD_JOBS"), jobs)
                self.assertEqual(env_of(run).get("RUST_TEST_THREADS"), jobs)
                self.assertEqual(any(arg.endswith(":/etc/passwd:ro") for arg in run), jobs is not None)
        result, calls = self.run_launcher("vcs-test", VCS_TEST_LINUX_JOBS="2")
        run = next(call for call in calls if call[:2] == ["docker", "run"])
        self.assertEqual(env_of(run)["CARGO_BUILD_JOBS"], "2")
        self.assertEqual(env_of(run)["RUST_TEST_THREADS"], "2")

    def test_the_tests_build_as_heads_commit_time(self):
        # A test pushes build 1 as an older daemon and expects it refused, which a daemon built as 1
        # would take as current; the lint compares no builds.
        head = subprocess.run(["git", "-C", str(ROOT), "log", "-1", "--format=%ct"],
                              capture_output=True, text=True, check=True).stdout.strip()
        for gate, build in ((), "1"), (("vcs-test",), head):
            with self.subTest(gate=gate):
                result, calls = self.run_launcher(*gate)
                self.assertEqual(result.returncode, 0, result.stderr)
                run = next(call for call in calls if call[:2] == ["docker", "run"])
                self.assertEqual(env_of(run)["WORKROOMD_BUILD"], build)
        self.assertGreater(int(head), 1)

    def test_an_unknown_gate_fails_before_any_container_starts(self):
        result, calls = self.run_launcher("vcs-bench")
        self.assertEqual(result.returncode, 2)
        self.assertIn("no gate 'vcs-bench'", result.stderr)
        self.assertFalse(any(call[1:2] in (["build"], ["run"]) for call in calls))

    def test_zig_caches_stay_off_the_host_mount(self):
        # Docker Desktop's macOS bind mount has no exclusive flock, which Zig's cache needs (#599).
        result, calls = self.run_launcher()
        self.assertEqual(result.returncode, 0, result.stderr)
        run = next(call for call in calls if call[:2] == ["docker", "run"])
        env = dict(run[i + 1].split("=", 1) for i, arg in enumerate(run) if arg == "--env")
        for key in ("ZIG_GLOBAL_CACHE_DIR", "WR_GHOSTTY_VT_ZIG_CACHE"):
            self.assertIn(key, env)
            self.assertFalse(env[key].startswith("/cache"), f"{key}={env[key]}")
        self.assertEqual(env["WR_GHOSTTY_VT_CACHE"], "/cache/ghostty-vt")

    def test_installed_but_stopped_runtime_falls_back(self):
        result, calls = self.run_launcher(LINT_TEST_OFF="docker")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(call[:2] == ["podman", "run"] for call in calls))

    def test_docker_and_podman_come_before_apples_container(self):
        # Zig's fetch of Ghostty's dependencies failed under container 1.7.1 and worked under Docker.
        for off, picked in (("", "docker"), ("docker", "podman"), ("docker,podman", "container")):
            with self.subTest(off=off):
                result, calls = self.run_launcher(LINT_TEST_OFF=off)
                self.assertEqual(result.returncode, 0, result.stderr)
                runs = [call[0] for call in calls if call[1:2] == ["run"]]
                self.assertEqual(runs, [picked])

    def test_wr_lint_runtime_picks_the_runtime(self):
        result, calls = self.run_launcher(WR_LINT_RUNTIME="container")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(call[:2] == ["container", "run"] for call in calls))
        self.assertFalse(any(call[0] in ("docker", "podman") for call in calls))

    def test_wr_lint_runtime_that_is_not_working_fails_naming_it(self):
        result, calls = self.run_launcher(WR_LINT_RUNTIME="container", LINT_TEST_OFF="container")
        self.assertEqual(result.returncode, 1)
        self.assertIn("WR_LINT_RUNTIME=container", result.stderr)
        self.assertFalse(any(call[0] in ("docker", "podman") for call in calls))
        self.assertFalse(any(call[1:2] in (["build"], ["run"]) for call in calls))

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
                    self.assertFalse(any(call[:2] == ["docker", "run"] for call in calls))

    def test_zig_image_pins_match_engine_and_ci(self):
        engine = (ROOT / "vcs/scripts/build-ghostty-vt.sh").read_text()
        version = re.search(r'^ZIG_VERSION="([^"]+)"', engine, re.M)[1]
        image = (ROOT / "vcs/scripts/linux-lint/Dockerfile").read_text()
        for arch in ("aarch64", "x86_64"):
            self.assertIn(f"{version}/{arch})", image)
        # Every workflow that installs the x86_64 Linux Zig, wherever its jobs live.
        checksums = {checksum for path in (ROOT / ".github/workflows").glob("*.yml")
                     for checksum in re.findall(r'archive: x86_64-linux\s+sha256: "([a-f0-9]{64})"',
                                                path.read_text())}
        self.assertTrue(checksums, "no workflow installs the x86_64 Linux Zig")
        for checksum in checksums:
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
