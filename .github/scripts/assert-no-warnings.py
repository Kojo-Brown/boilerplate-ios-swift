#!/usr/bin/env python3
"""Fail the build when the compiler emitted a warning against this package's own sources.

Phase 0 item 4 asks for a confirmation that the project builds under Swift 6
strict concurrency with no warnings. `Package.swift` already selects
`.swiftLanguageMode(.v6)`, which turns complete concurrency checking on, and
`LanguageMode.swift` in each target turns that into a compile-time `#error`
rather than a claim about a manifest. Neither of those says anything about
warnings: `xcodebuild` exits 0 with any number of them, and nothing in CI has
ever read the build log for one. This script is the part that makes "no
warnings" a gate instead of an assertion.

**Scope: diagnostics attributed to a file inside this checkout.** Warnings from
`GoogleSignIn-iOS` — checked out into DerivedData, outside the workspace — are
not this package's to fix, and failing on them would hand a third party a veto
over every build here. They are printed, counted and grouped so a regression in
a dependency is still visible, but they do not fail the job.

Warnings that name no file are printed the same way. Those come from the build
system rather than from compiling a source file (duplicate build phase inputs,
a runner-specific toolchain notice) and describe the environment, not the code.
If one ever appears that *is* about this package, the group in the log is where
it will be seen.

Duplicates are collapsed. `xcodebuild` re-emits the same diagnostic once per
compilation unit that pulls the declaration in, so a single warning in a widely
imported file arrives dozens of times; the count is kept and shown.

Usage: assert-no-warnings.py <build.log> [<repo-root>]
"""

import os
import re
import sys
from collections import Counter

# `path:line:col: warning: message`, the shape clang and swift-frontend both
# emit. Anchored at the start of the line (leading whitespace allowed, which
# xcodebuild adds when nesting under a task) so that the multi-kilobyte
# `swift-frontend` command line xcodebuild echoes on failure cannot match by
# containing the word somewhere in a flag.
DIAGNOSTIC = re.compile(
    r"^\s*(?P<path>[^\s:][^:]*):(?P<line>\d+):(?P<col>\d+):\s+warning:\s+(?P<message>.*)$"
)

# A warning with no source location: `warning: message`, emitted by xcodebuild
# itself rather than by a compiler frontend.
UNATTRIBUTED = re.compile(r"^\s*warning:\s+(?P<message>.*)$")

# Directories inside the checkout that hold this package's own code. Everything
# else under the repo root — `.build`, `.swiftpm`, a vendored checkout — is
# either generated or someone else's.
OWNED = ("Sources", "Tests")


def owned(path: str, root: str) -> bool:
    """True when `path` names a file this repository is responsible for."""
    try:
        relative = os.path.relpath(os.path.realpath(path), root)
    except ValueError:  # different drive on Windows; cannot be ours
        return False
    if relative.startswith(os.pardir):
        return False
    return relative.split(os.sep)[0] in OWNED


def render(title: str, counts: Counter) -> None:
    total = sum(counts.values())
    print(f"::group::{title} — {len(counts)} distinct, {total} total")
    for (location, message), count in sorted(counts.items()):
        repeat = f"  (x{count})" if count > 1 else ""
        print(f"  {location}: warning: {message}{repeat}")
    print("::endgroup::")


def main(log_path: str, root: str) -> int:
    root = os.path.realpath(root)

    ours: Counter = Counter()
    foreign: Counter = Counter()
    unattributed: Counter = Counter()

    with open(log_path, encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            match = DIAGNOSTIC.match(raw.rstrip("\n"))
            if match:
                path = match["path"]
                if owned(path, root):
                    # Relative, so the log reads like the diff it points at.
                    bucket, shown = ours, os.path.relpath(os.path.realpath(path), root)
                else:
                    bucket, shown = foreign, path
                bucket[(f"{shown}:{match['line']}:{match['col']}", match["message"])] += 1
                continue
            match = UNATTRIBUTED.match(raw.rstrip("\n"))
            if match:
                unattributed[("(no source location)", match["message"])] += 1

    if foreign:
        render("Warnings from dependencies (not gated)", foreign)
    if unattributed:
        render("Warnings with no source location (not gated)", unattributed)

    if not ours:
        owned_dirs = " or ".join(f"{name}/" for name in OWNED)
        print(f"No compiler warnings from {owned_dirs} — the package builds clean.")
        return 0

    render("Warnings from this package — these fail the build", ours)
    print(
        f"::error::{len(ours)} distinct compiler warning(s) in this package's own sources. "
        "Phase 0 item 4 requires the project to build with none.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        print(__doc__, file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1], sys.argv[2] if len(sys.argv) == 3 else os.getcwd()))
