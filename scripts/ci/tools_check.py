"""`make tools-check`: compare this machine's tools with the versions the repo pins.

Read-only. Every pin is read from where the repo already records it (go.mod, ci-go.yml,
ci-actions.yml, mk/vcs.mk through make, the setup-app-build composite); none is written here.
Tools are found on PATH however they were installed (Homebrew, `go install`, rustup, mise, ...).
Prints one line per tool and exits non-zero when a tool is missing or at another version.
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

from makevars import make_value

ROOT = Path(__file__).resolve().parents[2]

OK, MISSING, MISMATCH, NOTE = "ok", "missing", "mismatch", "note"


def read(relative):
    return (ROOT / relative).read_text()


def first(pattern, text, what):
    found = re.search(pattern, text, re.M)
    if not found:
        raise SystemExit(f"tools-check: cannot find {what}")
    return found[1]


def parse_pins():
    """Every pinned version, read from the file that records it."""
    ci_go = read(".github/workflows/ci-go.yml")
    ci_actions = read(".github/workflows/ci-actions.yml")
    xcode = read(".github/actions/setup-app-build/action.yml")
    return {
        "go": first(r"^go (\d+(?:\.\d+)*)\s*$", read("go.mod"), "the go line in go.mod"),
        "golangci-lint": first(r"^\s*GOLANGCI_LINT_VERSION:\s*(\S+)", ci_go,
                               "GOLANGCI_LINT_VERSION in ci-go.yml"),
        "rust": make_value("VCS_RUST"),
        "shellcheck": first(r"^\s*SHELLCHECK_VERSION:\s*(\S+)", ci_actions,
                            "SHELLCHECK_VERSION in ci-actions.yml"),
        "jactionlint": first(r"^\s*JACTIONLINT_VERSION:\s*(\S+)", ci_actions,
                             "JACTIONLINT_VERSION in ci-actions.yml"),
        "xcode": first(r"^\s*xcode-version:\s*[\"']?([\d.]+)", xcode,
                       "xcode-version in setup-app-build"),
    }


def numbers(version):
    return tuple(int(part) for part in version.split("."))


def run(command, env=None):
    """The command's stdout, or None when it is missing or fails."""
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=60, env=env)
    except (OSError, subprocess.SubprocessError):
        return None
    return result.stdout if result.returncode == 0 else None


def version_in(text, pattern=r"(\d+\.\d+(?:\.\d+)?)"):
    found = re.search(pattern, text or "")
    return found[1] if found else None


def compare(name, local, pinned, hint, newer_is_note=False):
    """A (status, line) pair for a tool at `local` against the version `pinned`."""
    if local is None:
        return MISSING, f"{name}: not found; {hint}"
    # A pin of `1.27` (go.mod may write two parts) is met by any `1.27.x`.
    same = local == pinned or local.startswith(pinned + ".")
    if same:
        return OK, f"{name} {local}"
    if newer_is_note and numbers(local) > numbers(pinned):
        return NOTE, f"{name} {local} is newer than the pinned {pinned}, which is fine"
    return MISMATCH, f"{name}: local {local}, pinned {pinned}; {hint}"


def check_go(pin):
    if not shutil.which("go"):
        return [(MISSING, f"go: not found; install Go {pin}")]
    local = version_in(run(["go", "version"]), r"go version go(\d+\.\d+(?:\.\d+)?)")
    rows = [compare("go", local, pin, f"install Go {pin}", newer_is_note=True)]
    # A GOROOT left over from another Go makes every package fail to compile with
    # `version "goX" does not match go tool version "goY"`.
    env_root = os.environ.get("GOROOT")
    if env_root:
        clean = {key: value for key, value in os.environ.items() if key != "GOROOT"}
        own = (run(["go", "env", "GOROOT"], env=clean) or "").strip()
        if own and os.path.realpath(env_root) != os.path.realpath(own):
            rows.append((MISMATCH, f"GOROOT: env says {env_root}, the go on PATH uses {own}; "
                                   "unset GOROOT"))
    return rows


def check_rust(pin):
    if not shutil.which("rustup"):
        return [(MISSING, f"rust: rustup not found; install rustup, then "
                          f"`rustup toolchain install {pin} --component rustfmt,clippy`")]
    # The vcs targets run `rustup which --toolchain $(VCS_RUST) cargo`; ask the same.
    cargo = run(["rustup", "which", "--toolchain", pin, "cargo"])
    if cargo is None:
        return [(MISSING, f"rust {pin}: toolchain not installed; "
                          f"rustup toolchain install {pin} --component rustfmt,clippy")]
    rows = [(OK, f"rust {pin}")]
    for tool in ("cargo-fmt", "cargo-clippy"):
        if run(["rustup", "which", "--toolchain", pin, tool]) is None:
            rows.append((MISSING, f"rust {pin}: {tool} component missing; "
                                  f"rustup component add rustfmt clippy --toolchain {pin}"))
    return rows


def check_xcode(pin):
    if not shutil.which("xcodebuild"):
        return [(MISSING, f"xcode: xcodebuild not found; install Xcode {pin}")]
    local = version_in(run(["xcodebuild", "-version"]), r"Xcode (\d+(?:\.\d+)*)")
    if local is None:
        return [(MISSING, f"xcode: xcodebuild gave no version (xcode-select?); install Xcode {pin}")]
    return [compare("xcode", local, pin, f"install Xcode {pin}", newer_is_note=True)]


def check_simple(name, pin, command):
    if not shutil.which(command[0]):
        return [(MISSING, f"{name}: not found; install {name} {pin}")]
    local = version_in(run(command), r"(\d+\.\d+\.\d+)")
    return [compare(name, local, pin, f"install {name} {pin}")]


def main():
    pins = parse_pins()
    rows = []
    rows += check_go(pins["go"])
    rows += check_simple("golangci-lint", pins["golangci-lint"], ["golangci-lint", "--version"])
    rows += check_rust(pins["rust"])
    rows += check_simple("shellcheck", pins["shellcheck"], ["shellcheck", "--version"])
    rows += check_simple("jactionlint", pins["jactionlint"], ["jactionlint", "--version"])
    rows += check_xcode(pins["xcode"])
    rows += [(OK, "xcodegen") if shutil.which("xcodegen")
             else (MISSING, "xcodegen: not found; install xcodegen (brew install xcodegen)")]
    for status, line in rows:
        print(f"{status:<8} {line}")
    return 1 if any(status in (MISSING, MISMATCH) for status, _ in rows) else 0


if __name__ == "__main__":
    sys.exit(main())
