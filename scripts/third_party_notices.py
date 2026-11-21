#!/usr/bin/env python3
"""Writes, or checks, the third-party notices Workroom's dependencies' licences require (#714).

Two files, each generated whole:

- `vcs/crates/workroomd/THIRD-PARTY-NOTICES.txt`: the workroom binary's. Every Rust crate it links
  on the targets it ships for, read from the real dependency graph by cargo-about, and the other
  code compiled into it (libghostty-vt and what that links, cobra's completion scripts, the Rust
  and Zig runtimes, musl). The binary embeds it, because a remote host is pushed only the binary,
  and the standalone archives carry it beside the binary.
- `macapp/Resources/THIRD-PARTY-NOTICES.txt`: the app bundle's, `Contents/Resources/` in the app.
  The binary's notices, and everything else the bundle ships (`ships: app` in components.json).

    scripts/third_party_notices.py write --cargo-about <path> --cargo-about-version <x.y.z>
    scripts/third_party_notices.py check --cargo-about <path> --cargo-about-version <x.y.z>

`check` fails when either file is stale, when a shipped crate's licence is not in about.toml's
accepted list, when a crate has no licence text with its copyright, or when a component's pin, or a
Package.resolved pin, no longer matches what components.json records. `make notices` and
`make notices-check` run them.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
THIRD_PARTY = ROOT / "third-party"
COMPONENTS = THIRD_PARTY / "components.json"
ABOUT_CONFIG = THIRD_PARTY / "about.toml"
CRATE_MANIFEST = ROOT / "vcs" / "crates" / "workroomd" / "Cargo.toml"
APP_RESOLVED = (ROOT / "macapp" / "WorkroomApp.xcodeproj" / "project.xcworkspace" / "xcshareddata"
                / "swiftpm" / "Package.resolved")
GRAMMARS = ROOT / "macapp" / "Packages" / "SyntaxHighlighting" / "Grammars"
OUTPUTS = {
    "workroom": ROOT / "vcs" / "crates" / "workroomd" / "THIRD-PARTY-NOTICES.txt",
    "app": ROOT / "macapp" / "Resources" / "THIRD-PARTY-NOTICES.txt",
}
# The features the shipped binary is built with (macapp/Scripts/build-daemon.sh).
FEATURES = "terminal-state"

# The licences a component outside the crate graph may carry. A copyleft one, weak copyleft
# (MPL-2.0) included, needs a `review` naming it, so it is never added quietly.
PERMISSIVE = {
    "MIT", "ISC", "Zlib", "BSD-2-Clause", "BSD-3-Clause", "Apache-2.0", "Unicode-3.0", "CC0-1.0",
    "FTL", "libpng-2.0", "OFL-1.1", "LicenseRef-KhronosFreeUse", "CC-BY-4.0", "Unlicense",
    "LicenseRef-Powerline-Symbols",
}
COPYLEFT = {"GPL-2.0-only", "GPL-3.0-or-later", "LGPL-2.1-or-later", "MPL-2.0",
            "LicenseRef-libgit2-linking-exception"}

RULE = "=" * 78
THIN = "-" * 78

HEADERS = {
    "workroom": (
        "This file covers the workroom binary: the Rust crates it links on macOS and Linux, and "
        "the other code compiled into it."
    ),
    "app": (
        "This file covers the Workroom app bundle, including the workroom binary inside it "
        "(Contents/Resources/workroom and Contents/Resources/workroom-linux-*). The names and "
        "logos of the tools Workroom shows beside their terminals belong to their owners, and "
        "are used only to identify those tools."
    ),
}


class NoticeError(Exception):
    """A problem `check` reports and `write` refuses to write over."""


def wrap(text, width=78):
    """`text` as lines of at most `width`, broken at spaces."""
    lines, line = [], ""
    for word in text.split():
        if line and len(line) + 1 + len(word) > width:
            lines.append(line)
            line = word
        else:
            line = f"{line} {word}" if line else word
    if line:
        lines.append(line)
    return "\n".join(lines)


def clean(text):
    """A licence text with LF line ends, no trailing spaces and no blank lines around it. Some
    crates' files end their lines with CRLF; the notices use LF throughout."""
    lines = [line.rstrip() for line in text.replace("\r\n", "\n").split("\n")]
    return "\n".join(lines).strip("\n")


def licence_tokens(expression):
    """The licence identifiers in an SPDX expression."""
    return {t for t in re.split(r"[\s()]+", expression) if t and t not in {"AND", "OR", "WITH"}}


def load_components():
    return json.loads(COMPONENTS.read_text())


def check_components(manifest, root=ROOT):
    """Every problem with components.json against the repository, as messages."""
    problems = []
    components = manifest["components"]
    seen = set()
    for component in components:
        cid = component["id"]
        if cid in seen:
            problems.append(f"{cid}: listed twice")
        seen.add(cid)
        if component["ships"] not in OUTPUTS:
            problems.append(f"{cid}: ships must be one of {sorted(OUTPUTS)}")
        tokens = licence_tokens(component["license"])
        unknown = tokens - PERMISSIVE - COPYLEFT
        if unknown:
            problems.append(f"{cid}: licence {sorted(unknown)} is not on the allow-list in "
                            "scripts/third_party_notices.py")
        if tokens & COPYLEFT and not component.get("review"):
            problems.append(f"{cid}: a copyleft licence needs a `review` for the owner")
        if not component["files"]:
            problems.append(f"{cid}: no licence file")
        for name in component["files"]:
            if not (root / name).is_file():
                problems.append(f"{cid}: {name} does not exist")
        pin = component.get("pin")
        if pin:
            path = root / pin["file"]
            found = re.search(pin["pattern"], path.read_text()) if path.is_file() else None
            if not found:
                problems.append(f"{cid}: {pin['file']} no longer matches {pin['pattern']!r}")
            elif found[1] != pin["value"]:
                problems.append(
                    f"{cid}: {pin['file']} now says {found[1]}, but components.json records "
                    f"{pin['value']}. Copy the licence files from the new version, then update "
                    "the entry and its pin.")
    problems += check_swiftpm(manifest, root)
    problems += check_grammars(manifest, root)
    return problems


def check_swiftpm(manifest, root=ROOT):
    """The app's Package.resolved pins, each a component at the same revision or not shipped."""
    resolved = root / APP_RESOLVED.relative_to(ROOT)
    pins = {pin["identity"]: pin["state"].get("revision")
            for pin in json.loads(resolved.read_text())["pins"]}
    listed = {c["swiftpm"]["identity"]: c for c in manifest["components"] if "swiftpm" in c}
    not_shipped = manifest["not_shipped"]["swiftpm"]
    problems = []
    for identity, revision in sorted(pins.items()):
        if identity in not_shipped:
            continue
        component = listed.get(identity)
        if component is None:
            problems.append(f"Package.resolved pins {identity}, which components.json does not "
                            "list: add it with its licence, or say under not_shipped why not")
        elif component["swiftpm"]["revision"] != revision:
            problems.append(
                f"{component['id']}: Package.resolved pins {revision}, but components.json "
                f"records {component['swiftpm']['revision']}. Copy the licence files from the new "
                "version, then update the entry.")
    for identity in sorted(set(listed) - set(pins)):
        problems.append(f"{listed[identity]['id']}: no longer in Package.resolved; remove it")
    return problems


def check_grammars(manifest, root=ROOT):
    """Each vendored grammar under Grammars/ is a component."""
    ids = {c["id"] for c in manifest["components"]}
    grammars = root / GRAMMARS.relative_to(ROOT)
    return [f"{d.name}: vendored under {GRAMMARS.relative_to(ROOT)} but not in components.json"
            for d in sorted(grammars.iterdir()) if d.is_dir() and d.name not in ids]


def run_cargo_about(cargo_about, version):
    """cargo-about's JSON for the shipped binary's dependency graph."""
    install = (f"Install it with `cargo install cargo-about --locked --features cli --version "
               f"{version}`, or set CARGO_ABOUT to its path.")
    try:
        reported = subprocess.run([cargo_about, "--version"], capture_output=True, text=True,
                                  check=True).stdout.split()
    except (OSError, subprocess.CalledProcessError):
        raise NoticeError(f"cannot run {cargo_about}. {install}") from None
    if reported[-1:] != [version]:
        raise NoticeError(
            f"{cargo_about} is {' '.join(reported)}; the notices are made with cargo-about "
            f"{version}. {install}")
    # cargo-about reads every crate's sources offline, so the build is the same on every machine;
    # this fetches the crates of all four targets first, which a host's own build does not.
    subprocess.run(["cargo", "fetch", "--locked", "--manifest-path", str(CRATE_MANIFEST)],
                   check=True, stdout=subprocess.DEVNULL)
    result = subprocess.run(
        [cargo_about, "generate", "--format", "json", "--config", str(ABOUT_CONFIG),
         "--manifest-path", str(CRATE_MANIFEST), "--features", FEATURES, "--frozen", "--fail"],
        capture_output=True, text=True)
    if result.returncode != 0:
        raise NoticeError("cargo-about failed. A crate's licence is not in third-party/about.toml's "
                          f"accepted list, or cannot be read:\n{result.stderr}")
    return json.loads(result.stdout)


def about_targets():
    """The targets third-party/about.toml lists (Python 3.9, macOS's, has no TOML reader)."""
    block = re.search(r"^targets = \[(.*?)\]", ABOUT_CONFIG.read_text(), re.M | re.S)[1]
    return re.findall(r'"([^"]+)"', block)


def linked_packages(metadata):
    """The package ids `cargo metadata --filter-platform` output says the root links: its normal
    dependencies, transitively. A proc-macro runs in the compiler and is not linked, so it and
    what only it depends on are left out, as are build and dev dependencies."""
    packages = {p["id"]: p for p in metadata["packages"]}
    nodes = {n["id"]: n for n in metadata["resolve"]["nodes"]}
    root = metadata["resolve"]["root"]
    linked, queue = set(), [root]
    while queue:
        for dep in nodes[queue.pop()]["deps"]:
            if not any(kind["kind"] is None for kind in dep["dep_kinds"]):
                continue
            pkg = dep["pkg"]
            if pkg in linked or any("proc-macro" in t["kind"] for t in packages[pkg]["targets"]):
                continue
            linked.add(pkg)
            queue.append(pkg)
    return linked


def run_cargo_metadata():
    """The packages the shipped binary links on any of its targets."""
    linked = set()
    for target in about_targets():
        result = subprocess.run(
            ["cargo", "metadata", "--format-version", "1", "--frozen", "--manifest-path",
             str(CRATE_MANIFEST), "--features", FEATURES, "--filter-platform", target],
            capture_output=True, text=True, check=True)
        linked |= linked_packages(json.loads(result.stdout))
    return linked


def crate_sections(about, supplements, linked=None, root=ROOT):
    """The crates' notices: one section per licence text, naming every crate under it.

    Only cargo-about's crates that are also in `linked` (all of them, when it is None) are named,
    less Workroom's own (no registry source), and each of those must have a licence. A text
    cargo-about found no file for is the bare licence, without the crate's copyright: such a crate
    needs a supplement, which names the licence it takes (one the crate offers) and the files that
    hold it."""
    own = {c["package"]["id"] for c in about["crates"] if c["package"]["source"] is None}

    def shipped(crate):
        return crate["id"] not in own and (linked is None or crate["id"] in linked)

    groups = {}
    covered = set()
    for licence in about["licenses"]:
        users = [u["crate"] for u in licence["used_by"] if shipped(u["crate"])]
        if not users:
            continue
        covered.update(c["id"] for c in users)
        if licence.get("source_path") is None:
            for crate in users:
                supplement = supplements.get(crate["name"])
                if not supplement:
                    raise NoticeError(
                        f"{crate['name']} {crate['version']} ships no licence file, so its "
                        f"{licence['id']} notice would have no copyright. Copy the licence from "
                        "its repository into third-party/licenses and list it under "
                        "crate_supplements in components.json.")
                if supplement["license"] not in licence_tokens(crate["license"] or ""):
                    raise NoticeError(f"{crate['name']} does not offer {supplement['license']}")
                text = "\n\n".join(clean((root / f).read_text()) for f in supplement["files"])
                groups.setdefault((supplement["license"], text), set()).add(
                    (crate["name"], crate["version"]))
            continue
        groups.setdefault((licence["id"], clean(licence["text"])), set()).update(
            (c["name"], c["version"]) for c in users)
    # cargo-about's graph is the one that counts (cargo metadata's also unifies dev-dependencies'
    # features); `linked` only takes out of it what is not linked.
    graph = {c["package"]["id"] for c in about["crates"]}
    if linked is not None:
        missing = sorted((graph & linked) - own - covered)
        if missing:
            raise NoticeError(f"cargo-about gave no licence for linked crates: {missing}")
    # Ordered by licence, then crate, then text: cargo-about's own order varies from run to run.
    sections = []
    for (licence_id, text), crates in sorted(
            groups.items(), key=lambda item: (item[0][0], sorted(item[1]), item[0][1])):
        names = ", ".join(f"{name} {version}" for name, version in sorted(crates))
        sections.append(f"{RULE}\nRust crates under {licence_id}: {names}\n{THIN}\n\n{text}\n")
    return sections


def component_section(component, root=ROOT):
    lines = [RULE, f"{component['name']} {component['version']}"]
    licence = component["license"]
    if component.get("offered"):
        licence += f" (offered under {component['offered']})"
    lines.append(f"Licence: {licence}")
    lines.append(f"Source: {component['source']}")
    if component.get("note"):
        lines.append(wrap(component["note"]))
    lines.append(THIN)
    lines.append("")
    if component.get("copyright"):
        lines += [component["copyright"], ""]
    for name in component["files"]:
        lines += [clean((root / name).read_text()), ""]
    return "\n".join(lines)


def render(target, manifest, crates, root=ROOT):
    """The notices file for `target` (`workroom` or `app`)."""
    wanted = {"workroom"} if target == "workroom" else {"workroom", "app"}
    components = [c for c in manifest["components"] if c["ships"] in wanted]
    head = "\n".join([
        "Third-party software notices",
        "",
        wrap("Workroom is a Codaset product. It includes the third-party software below, each "
             "under the licence given with it. " + HEADERS[target]),
        "",
        wrap("Generated by `make notices` from vcs/Cargo.lock and third-party/components.json; "
             "do not edit it by hand."),
        "",
    ])
    body = [component_section(c, root) for c in components] + crates
    return head + "\n" + "\n".join(body)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("mode", choices=["write", "check"])
    parser.add_argument("--cargo-about", default="cargo-about")
    parser.add_argument("--cargo-about-version", required=True)
    args = parser.parse_args(argv)

    manifest = load_components()
    problems = check_components(manifest)
    try:
        about = run_cargo_about(args.cargo_about, args.cargo_about_version)
        crates = crate_sections(about, manifest["crate_supplements"], run_cargo_metadata())
    except NoticeError as e:
        problems.append(str(e))
        crates = None
    if crates is not None:
        for target, path in OUTPUTS.items():
            text = render(target, manifest, crates)
            # newline="": compare the bytes, so a CR that reached the file still shows as stale.
            current = None
            if path.is_file():
                with open(path, encoding="utf-8", newline="") as f:
                    current = f.read()
            if args.mode == "write" and not problems:
                if current != text:
                    with open(path, "w", encoding="utf-8", newline="") as f:
                        f.write(text)
                    print(f"wrote {path.relative_to(ROOT)}")
            elif current != text:
                problems.append(f"{path.relative_to(ROOT)} is stale: run `make notices`")
    for problem in problems:
        print(f"notices: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
