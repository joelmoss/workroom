#!/usr/bin/env python3
"""Flags synchronous file-system calls in the app's git and inspector code (`make app-lint`).

    python3 macapp/Scripts/check-main-actor-fs.py [--root DIR] [--allowlist FILE]

A `stat`, `realpath` or directory read on a stalled network mount blocks its thread until the
kernel gives up; on the main actor that freezes every window (Codex, three rounds on #812). Under
the scanned folders each such call must run inside a `GitRepositoryProbe.blockingRead` or
`boundedRead` closure, which runs it off the main actor under a timeout, or have an allowlist entry
saying why it is safe (or that it is a known, unfixed exception).

A `nonisolated` function is NOT exempt by itself: a synchronous one runs on its caller's actor.
It goes in the allowlist, naming its off-main callers.

Allowlist (`main-actor-fs-allowlist.txt` beside this script), one entry a line:

    <file under the root> | <enclosing function> | <call> | <one-line reason>

`<enclosing function>` is the innermost named `func`, `init`, `var` or `let` around the call, or
`-` at the top level. An entry covers every such call in that function. An entry that matches no
call fails the check, so the list never outlives the code. Standard library only.
"""

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.join(HERE, "..", "WorkroomApp", "Core")
DEFAULT_ALLOWLIST = os.path.join(HERE, "main-actor-fs-allowlist.txt")
SCANNED = ("VersionControl", "AppShell")

# Matched by method name, whatever the receiver (`fm.fileExists`, `entry.resourceValues`).
CALLS = (
    ("realpath", re.compile(r"\brealpath\s*\(")),
    ("fileExists", re.compile(r"\.\s*fileExists\s*\(")),
    ("attributesOfItem", re.compile(r"\.\s*attributesOfItem\s*\(")),
    ("contentsOfDirectory", re.compile(r"\.\s*contentsOfDirectory\s*\(")),
    ("RepositoryLocation.local", re.compile(r"\bRepositoryLocation\s*\.\s*local\s*\(")),
    ("resolvingSymlinksInPath", re.compile(r"\bresolvingSymlinksInPath\b")),
    ("resourceValues", re.compile(r"\.\s*resourceValues\s*\(")),
    # `VCSStatusService.canonicalPath` is a synchronous `realpath`: calling it is the same stat.
    ("canonicalPath", re.compile(r"\bcanonicalPath\s*\(")),
)
BOUNDED = re.compile(r"\b(blockingRead|boundedRead)\b")
DECL = re.compile(r"\b(func\s+([A-Za-z_][A-Za-z0-9_]*)|init\b|(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*))")
FIX = ("wrap it in GitRepositoryProbe.blockingRead (or boundedRead for async work) so it runs off "
       "the main actor under a timeout, or add an entry with its reason to "
       "macapp/Scripts/main-actor-fs-allowlist.txt")


def strip(source):
    """`source` with comments and string-literal contents blanked to spaces, newlines kept, so
    offsets and line numbers still match. An interpolation's code is blanked with its string."""
    out = list(source)
    i, n = 0, len(source)

    def blank(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        if source.startswith("//", i):
            j = source.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif source.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if source.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif source.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            blank(i, j)
            i = j
        elif source[i] == '"':
            quote = '"""' if source.startswith('"""', i) else '"'
            j = i + len(quote)
            while j < n and not source.startswith(quote, j):
                j += 2 if source[j] == "\\" else 1
            j = min(n, j + len(quote))
            blank(i + 1, j - 1)
            i = j
        else:
            i += 1
    return "".join(out)


def opens_bounded_closure(header):
    """Whether the `{` after `header` opens a closure passed to `blockingRead`/`boundedRead`: inside
    its argument list, or its trailing closure."""
    calls = list(BOUNDED.finditer(header))
    if not calls:
        return False
    rest = header[calls[-1].end():]
    depth = 0
    for k, ch in enumerate(rest):
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return rest[k + 1:].strip() == ""
    return depth > 0 or rest.strip() == ""


CONTINUES_LINE = (".", ",", ")", "]", "->", "where", "throws", "rethrows", "async", "&&", "||",
                  "?", ":", "=", "+", "-", "*", "/", "{")
OPENS_LINE = ("(", "[", ",", "=", "->", "&&", "||", ":", "in")


def statement_ended(tail):
    """Whether `tail`, the text after a declaration's name, holds a later statement: a line that
    neither continues the one before nor follows one left open."""
    lines = [line.strip() for line in tail.split("\n")]
    for previous, line in zip(lines, lines[1:]):
        if not line or not previous:
            continue
        if not line.startswith(CONTINUES_LINE) and not previous.endswith(OPENS_LINE):
            return True
    return False


def decl_name(header):
    """The name a `{` after `header` opens the body of, if it opens a declaration's body."""
    names = [m for m in DECL.finditer(header)]
    if not names:
        return None
    m = names[-1]
    if statement_ended(header[m.end():]):
        return None
    if m.group(2):
        return m.group(2)
    if m.group(3):
        # A `var`/`let` whose `{` is a computed body or a closure initialiser, not an `if let`.
        before = header[:m.start()].rstrip()
        if re.search(r"\b(if|guard|while|case)\s*$", before) or before.endswith(","):
            return None
        return m.group(3)
    return "init"


def scan(path, source):
    """Each `(line, call, enclosing function)` in `source` not inside a bounded read."""
    text = strip(source)
    events = []  # (offset, kind, payload)
    for name, pattern in CALLS:
        for m in pattern.finditer(text):
            if not re.search(r"\bfunc\s+$", text[:m.start()][-40:]):  # its declaration, no call
                events.append((m.start(), 1, name))
    for k, ch in enumerate(text):
        if ch in "{}":
            events.append((k, 0, ch))
    events.sort()
    stack = []  # (bounded, name)
    last = 0
    hits = []
    for offset, kind, payload in events:
        if kind == 0 and payload == "{":
            header = text[last:offset]
            bounded = opens_bounded_closure(header) or any(b for b, _ in stack)
            stack.append((bounded, decl_name(header)))
            last = offset + 1
        elif kind == 0:
            if not stack:
                raise ValueError(f"{path}: unbalanced `}}` at line {text.count(chr(10), 0, offset) + 1}")
            stack.pop()
            last = offset + 1
        elif not any(b for b, _ in stack):
            enclosing = next((n for _, n in reversed(stack) if n), None)
            if enclosing is None:
                # A stored property's initialiser in a type's body: the property it initialises.
                decls = [m for m in DECL.finditer(text[last:offset]) if m.group(3)]
                enclosing = decls[-1].group(3) if decls else "-"
            hits.append((text.count("\n", 0, offset) + 1, payload, enclosing))
    if stack:
        # A string or comment the stripper misread: fail rather than pass on a wrong parse.
        raise ValueError(f"{path}: {len(stack)} unclosed `{{` at end of file")
    return hits


def read_allowlist(path):
    entries = {}
    with open(path, encoding="utf-8") as f:
        for number, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split("|", 3)]
            if len(parts) != 4 or not all(parts):
                sys.exit(f"{path}:{number}: want `file | function | call | reason`, got: {line}")
            entries[tuple(parts[:3])] = number
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=DEFAULT_ROOT)
    parser.add_argument("--allowlist", default=DEFAULT_ALLOWLIST)
    args = parser.parse_args()
    root = os.path.normpath(args.root)
    allowed = read_allowlist(args.allowlist)
    used = set()
    failures = []
    for folder in SCANNED:
        for directory, _, files in sorted(os.walk(os.path.join(root, folder))):
            for name in sorted(files):
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(directory, name)
                rel = os.path.relpath(path, root)
                with open(path, encoding="utf-8") as f:
                    source = f.read()
                try:
                    hits = scan(rel, source)
                except ValueError as error:
                    failures.append(f"{error}: cannot check this file")
                    continue
                for line, call, enclosing in hits:
                    key = (rel, enclosing, call)
                    if key in allowed:
                        used.add(key)
                    else:
                        failures.append(f"{rel}:{line}: `{call}` in `{enclosing}` touches the file "
                                        f"system and may run on the main actor: {FIX}")
    for key, number in sorted(allowed.items(), key=lambda kv: kv[1]):
        if key not in used:
            failures.append(f"{os.path.relpath(args.allowlist)}:{number}: stale entry, no "
                            f"`{key[2]}` in `{key[1]}` of {key[0]}: remove it")
    for failure in failures:
        print(failure, file=sys.stderr)
    if failures:
        print(f"check-main-actor-fs: {len(failures)} problem(s)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
