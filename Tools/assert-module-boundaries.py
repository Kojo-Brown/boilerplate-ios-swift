#!/usr/bin/env python3
"""Fail if the module graph in Package.swift is not the one the source obeys.

Phase 8 item 7 split one target into four. `.target(dependencies:)` is what
makes the split real to the compiler, and on its own it is not enough to keep
it real:

  * Adding a dependency is a one-line edit. `Core` gaining an edge to
    `Networking` would compile, pass every test, and quietly undo the layering —
    nobody reviews a line in a manifest as carefully as a line in a screen.
  * A file can rely on a module it never imported, because Swift will find a
    type in a transitively loaded module. That compiles today and stops
    compiling the moment the intermediate dependency is dropped, so a build that
    is green says nothing about which edges the source actually needs.
  * The compiler cannot see feature isolation at all. `Features` is one target,
    so `BarcodeScanner` reaching into `TextRecognition` is an ordinary
    same-module reference — exactly the coupling that made the package one
    module in the first place.

So the graph is declared here, checked against the manifest, and checked against
every `import` and every cross-directory type reference in `Sources/`.

It is deliberately a script and not a test: it needs no toolchain, no resolved
packages and no simulator, so it runs on Linux in the lint job and reports even
when the build is broken. Run it with `python3 Tools/assert-module-boundaries.py`.
"""
from __future__ import annotations

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(REPO, "Sources")
TESTS = os.path.join(REPO, "Tests")

# The graph, spelled out. Package.swift is checked against this rather than read
# as the truth, so that widening a target's dependencies fails here instead of
# passing silently.
EXPECTED_GRAPH = {
    "Core": set(),
    "Networking": {"Core"},
    "Features": {"Core", "Networking"},
    "BoilerplateiOSSwift": {"Core", "Networking", "Features"},
}

TARGET_PATHS = {
    "Core": "Sources/Core",
    "Networking": "Sources/Networking",
    "Features": "Sources/Features",
    "BoilerplateiOSSwift": "Sources/App",
}

# A feature may reach sideways only to `Shared`. Anything else is one screen
# knowing about another, which is what a slot in the parent view is for.
SHARED_FEATURE_DIR = "Shared"

TYPE_DECL = re.compile(
    r"^(?:(?:package|private|fileprivate|internal|public|open|final|indirect)\s+)*"
    r"(?:class|struct|enum|protocol|actor|typealias)\s+([A-Za-z_]\w*)"
)
IMPORT = re.compile(r"^\s*(?:@testable\s+)?import\s+(?:struct\s+|class\s+|enum\s+|func\s+)?([A-Za-z_]\w*)")


def strip_noise(line: str, in_block: bool) -> tuple[str, bool]:
    """Drop comments and string literals so a mention in prose is not a reference."""
    out: list[str] = []
    i, n = 0, len(line)
    while i < n:
        if in_block:
            end = line.find("*/", i)
            if end == -1:
                return "".join(out), True
            in_block = False
            i = end + 2
            continue
        ch = line[i]
        if ch == "/" and i + 1 < n and line[i + 1] == "/":
            break
        if ch == "/" and i + 1 < n and line[i + 1] == "*":
            in_block = True
            i += 2
            continue
        if ch == '"':
            i += 1
            while i < n:
                if line[i] == "\\":
                    i += 2
                    continue
                if line[i] == '"':
                    i += 1
                    break
                i += 1
            out.append('""')
            continue
        out.append(ch)
        i += 1
    return "".join(out), in_block


def swift_files(root: str) -> list[str]:
    found = []
    for dirpath, _, names in os.walk(root):
        for name in sorted(names):
            if name.endswith(".swift"):
                found.append(os.path.join(dirpath, name))
    return sorted(found)


def code_lines(path: str) -> list[str]:
    lines, in_block = [], False
    for raw in open(path, encoding="utf-8").read().split("\n"):
        code, in_block = strip_noise(raw, in_block)
        lines.append(code)
    return lines


def owner_of(path: str) -> str:
    rel = os.path.relpath(path, REPO)
    for target, prefix in TARGET_PATHS.items():
        if rel == prefix or rel.startswith(prefix + os.sep):
            return target
    raise SystemExit(f"{rel} is under Sources/ but in none of the declared targets")


def feature_of(path: str) -> str | None:
    """The feature directory a file belongs to, for files under Sources/Features."""
    rel = os.path.relpath(path, os.path.join(REPO, "Sources", "Features"))
    if rel.startswith(".."):
        return None
    parts = rel.split(os.sep)
    return parts[0] if len(parts) > 1 else None


def check_manifest(problems: list[str]) -> None:
    manifest = open(os.path.join(REPO, "Package.swift"), encoding="utf-8").read()
    for block in re.finditer(r"\.(?:test)?[Tt]arget\(\s*name:\s*\"([^\"]+)\"(.*?)\n        \)", manifest, re.S):
        name, body = block.group(1), block.group(2)
        if name not in EXPECTED_GRAPH:
            continue
        declared = {d for d in re.findall(r"\"([A-Za-z_]\w*)\"", body.split("path:")[0]) if d in EXPECTED_GRAPH}
        if declared != EXPECTED_GRAPH[name]:
            problems.append(
                f"Package.swift: target {name} depends on {sorted(declared)}, "
                f"but the declared graph is {sorted(EXPECTED_GRAPH[name])}"
            )


def main() -> int:
    problems: list[str] = []
    check_manifest(problems)

    files = swift_files(SOURCES)

    # Where every top-level type in the package is declared.
    declared: dict[str, str] = {}
    declared_file: dict[str, str] = {}
    for path in files:
        depth = 0
        for code in code_lines(path):
            if depth == 0:
                m = TYPE_DECL.match(code)
                if m:
                    declared.setdefault(m.group(1), owner_of(path))
                    declared_file.setdefault(m.group(1), path)
            depth += code.count("{") - code.count("}")

    for path in files:
        rel = os.path.relpath(path, REPO)
        target = owner_of(path)
        allowed = EXPECTED_GRAPH[target]
        lines = code_lines(path)

        imported = set()
        for number, code in enumerate(lines, 1):
            m = IMPORT.match(code)
            if not m:
                continue
            module = m.group(1)
            if module not in EXPECTED_GRAPH:
                continue
            imported.add(module)
            if module == target:
                problems.append(f"{rel}:{number}: imports its own module {module}")
            elif module not in allowed:
                problems.append(
                    f"{rel}:{number}: {target} imports {module}, which is not one of its "
                    f"dependencies ({sorted(allowed) or 'none'})"
                )

        body = "\n".join(lines)
        used_modules = set()
        for m in re.finditer(r"\b([A-Za-z_]\w*)\b", body):
            home = declared.get(m.group(1))
            if home is None or home == target:
                continue
            used_modules.add(home)
            if home not in allowed:
                problems.append(f"{rel}: {target} names {m.group(1)}, which lives in {home}")
        for module in sorted(used_modules - imported):
            if module in allowed:
                problems.append(
                    f"{rel}: names types from {module} without importing it "
                    f"(it resolves transitively today and will stop when the graph changes)"
                )

        # Feature isolation, which the compiler cannot see: Features is one target.
        mine = feature_of(path)
        if mine and mine != SHARED_FEATURE_DIR:
            for m in re.finditer(r"\b([A-Za-z_]\w*)\b", body):
                home_file = declared_file.get(m.group(1))
                if home_file is None:
                    continue
                theirs = feature_of(home_file)
                if theirs and theirs not in (mine, SHARED_FEATURE_DIR):
                    problems.append(
                        f"{rel}: feature {mine} names {m.group(1)} from feature {theirs}; "
                        f"take a view slot from the parent, or move the type to Features/Shared"
                    )

    if problems:
        print("Module boundary violations:\n", file=sys.stderr)
        for problem in sorted(set(problems)):
            print(f"  {problem}", file=sys.stderr)
        print(f"\n{len(set(problems))} violation(s).", file=sys.stderr)
        return 1

    print(f"Module boundaries hold across {len(files)} source files.")
    for target in sorted(EXPECTED_GRAPH):
        deps = sorted(EXPECTED_GRAPH[target])
        print(f"  {target:20} -> {', '.join(deps) if deps else '(nothing)'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
