"""scripts/third_party_notices.py: what the notices check catches, against a scratch tree (#714)."""

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import third_party_notices as notices  # noqa: E402

RESOLVED = notices.APP_RESOLVED.relative_to(notices.ROOT)
GRAMMARS = notices.GRAMMARS.relative_to(notices.ROOT)


def component(**overrides):
    entry = {"id": "lib", "name": "lib", "version": "1.0", "license": "MIT",
             "source": "https://example.com/lib", "ships": "app", "files": ["LICENSE"]}
    entry.update(overrides)
    return entry


class CheckComponentsTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        (self.root / "LICENSE").write_text("Copyright lib's authors\n")
        (self.root / "pin.sh").write_text('LIB_VERSION="1.0"\n')
        (self.root / GRAMMARS).mkdir(parents=True)
        self.pins({"sparkle": "abc"})

    def pins(self, pins):
        path = self.root / RESOLVED
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"pins": [{"identity": i, "state": {"revision": r}}
                                             for i, r in pins.items()]}))

    def problems(self, *components, not_shipped=None):
        manifest = {"components": list(components),
                    "not_shipped": {"swiftpm": not_shipped or {}}}
        return notices.check_components(manifest, self.root)

    def test_a_covered_tree_has_no_problems(self):
        self.assertEqual(self.problems(component(swiftpm={"identity": "sparkle",
                                                          "revision": "abc"})), [])

    def test_a_package_resolved_pin_with_no_entry_fails(self):
        self.assertRegex("\n".join(self.problems(component())), "pins sparkle")

    def test_a_package_resolved_pin_named_not_shipped_passes(self):
        self.assertEqual(self.problems(component(), not_shipped={"sparkle": "build only"}), [])

    def test_a_moved_package_resolved_pin_fails(self):
        self.pins({"sparkle": "def"})
        found = self.problems(component(swiftpm={"identity": "sparkle", "revision": "abc"}))
        self.assertRegex("\n".join(found), "pins def")

    def test_a_moved_version_line_fails(self):
        pin = {"file": "pin.sh", "pattern": 'LIB_VERSION="([^"]+)"', "value": "0.9"}
        found = self.problems(component(pin=pin), not_shipped={"sparkle": "-"})
        self.assertRegex("\n".join(found), "now says 1.0")

    def test_a_licence_off_the_allow_list_fails(self):
        found = self.problems(component(license="SSPL-1.0"), not_shipped={"sparkle": "-"})
        self.assertRegex("\n".join(found), "allow-list")

    def test_a_copyleft_licence_needs_a_review(self):
        found = self.problems(component(license="GPL-3.0-or-later"),
                              not_shipped={"sparkle": "-"})
        self.assertRegex("\n".join(found), "needs a `review`")
        self.assertEqual(self.problems(component(license="GPL-3.0-or-later", review="owner"),
                                       not_shipped={"sparkle": "-"}), [])

    def test_a_missing_licence_file_fails(self):
        found = self.problems(component(files=["NOPE"]), not_shipped={"sparkle": "-"})
        self.assertRegex("\n".join(found), "NOPE does not exist")

    def test_a_vendored_grammar_with_no_entry_fails(self):
        (self.root / GRAMMARS / "tree-sitter-zig").mkdir()
        found = self.problems(component(), not_shipped={"sparkle": "-"})
        self.assertRegex("\n".join(found), "tree-sitter-zig")


def about(*licences, own=()):
    crates = [{"package": {"id": n, "source": None if n in own else "registry"}}
              for licence in licences for n in licence["users"]]
    return {"crates": crates, "licenses": [
        {"id": licence["id"], "text": licence["text"], "source_path": licence.get("path"),
         "used_by": [{"crate": {"id": n, "name": n, "version": "1.0"}} for n in licence["users"]]}
        for licence in licences]}


class CrateSectionTests(unittest.TestCase):
    def test_crates_sharing_a_text_share_a_section_and_own_crates_are_left_out(self):
        sections = notices.crate_sections(about(
            {"id": "MIT", "text": "Copyright b\r\nMIT  \r\n", "path": "x", "users": ["b", "a"]},
            {"id": "MIT", "text": "MIT", "users": ["workroom"]}, own={"workroom"}), {})
        self.assertEqual(len(sections), 1)
        self.assertIn("Rust crates under MIT: a 1.0, b 1.0\n", sections[0])
        self.assertIn("Copyright b\nMIT\n", sections[0])

    def test_a_crate_without_a_licence_file_needs_a_supplement(self):
        bare = about({"id": "MIT", "text": "MIT", "users": ["objc2"]})
        with self.assertRaisesRegex(notices.NoticeError, "objc2 1.0 ships no licence file"):
            notices.crate_sections(bare, {})
        with tempfile.TemporaryDirectory() as scratch:
            (Path(scratch) / "LICENSE-MIT").write_text("Copyright objc2's authors\n")
            sections = notices.crate_sections(bare, {"objc2": ["LICENSE-MIT"]}, Path(scratch))
        self.assertIn("Copyright objc2's authors", sections[0])


if __name__ == "__main__":
    unittest.main()
