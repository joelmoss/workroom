"""The toolchain pins agree wherever they are written.

Zig, cargo-zigbuild and Rust are each pinned once, with copies a bump has to find: Zig in the
install-zig composite and in the libghostty-vt build script, cargo-zigbuild in its composite, and
Rust in mk/vcs.mk (read through make) and in ci-rust.yml's three install steps. A caller can also
pass a composite another version. Any copy that disagrees fails here rather than on the next run.
"""

import re
import unittest
from pathlib import Path

from makevars import make_value

ROOT = Path(__file__).resolve().parents[2]
ACTIONS = ROOT / ".github" / "actions"
CI_FILES = (sorted((ROOT / ".github" / "workflows").glob("*.yml"))
            + sorted(ACTIONS.glob("*/action.yml")))


def input_default(action, name):
    """The `default:` of one input of a composite action."""
    text = (ACTIONS / action / "action.yml").read_text()
    block = re.search(rf"^  {name}:\n((?:    .*\n)+)", text, re.M)[1]
    return re.search(r'^\s+default: "([^"]+)"$', block, re.M)[1]


def passed_inputs(action, name):
    """Each value a workflow or composite passes the action's input, with the file it is in."""
    for path in CI_FILES:
        lines = path.read_text().splitlines()
        for index, line in enumerate(lines):
            if line.strip().removeprefix("- ") != f"uses: ./.github/actions/{action}":
                continue
            # The step's own keys sit at the indent of `uses:`, its inputs deeper.
            indent = line.index("uses:")
            for following in lines[index + 1:]:
                if following.strip() and len(following) - len(following.lstrip()) < indent:
                    break
                found = re.match(rf"\s+{name}:\s*(.+?)\s*$", following)
                if found:
                    yield path.relative_to(ROOT).as_posix(), found[1].strip("\"'")


class ToolPinTests(unittest.TestCase):
    def test_zig_is_the_version_libghostty_vt_builds_with(self):
        pin = input_default("install-zig", "version")
        engine = (ROOT / "vcs" / "scripts" / "build-ghostty-vt.sh").read_text()
        self.assertEqual(pin, re.search(r'^ZIG_VERSION="([^"]+)"', engine, re.M)[1])
        for where, version in passed_inputs("install-zig", "version"):
            with self.subTest(where=where):
                self.assertEqual(version, pin)

    def test_cargo_zigbuild_is_installed_only_by_its_composite(self):
        pin = input_default("install-cargo-zigbuild", "version")
        self.assertRegex(pin, r"^\d+\.\d+\.\d+$")
        for where, version in passed_inputs("install-cargo-zigbuild", "version"):
            with self.subTest(where=where):
                self.assertEqual(version, pin)
        own = ACTIONS / "install-cargo-zigbuild" / "action.yml"
        for path in CI_FILES:
            if path != own:
                with self.subTest(path=path.relative_to(ROOT).as_posix()):
                    self.assertNotRegex(path.read_text(), r"cargo install cargo-zigbuild")

    def test_rust_is_the_toolchain_the_makefile_lints_with(self):
        pin = make_value("VCS_RUST")
        self.assertRegex(pin, r"^\d+\.\d+\.\d+$")
        # Every numbered toolchain a workflow names; `stable`, which the app's daemon build tracks
        # on purpose, is not a pin.
        pattern = (r"rustup (?:toolchain install|default|run|target add --toolchain) (\d[\w.-]*)"
                   r"|Install Rust (\d[\w.-]*)|\+(\d+\.\d+\.\d+)\b")
        found = []
        for path in CI_FILES:
            for match in re.finditer(pattern, path.read_text()):
                found.append((path.relative_to(ROOT).as_posix(),
                              next(group for group in match.groups() if group)))
        self.assertTrue(any(where.endswith("/ci-rust.yml") for where, _ in found),
                        "found no Rust pin in ci-rust.yml")
        for where, version in found:
            with self.subTest(where=where):
                self.assertEqual(version, pin)


if __name__ == "__main__":
    unittest.main()
