#!/usr/bin/env python3
"""Audit the escape hatches out of Swift 6's `Sendable` checking.

Swift 6 language mode checks `Sendable` conformance for you — except where the
source opts out. `@unchecked Sendable` and `nonisolated(unsafe)` are both
promises the compiler takes on trust and then stops re-verifying, including
after a later edit adds an unguarded stored property beside the ones the
original promise was about. They are the only two ways a data race gets past a
build that this package's CI already proves is warning-free, so they are the
thing worth counting.

This does not ban them. Two sites here are load-bearing and cannot be written
any other way (see the table below). What it bans is an *unrecorded* one: every
occurrence must be listed in `ALLOWED` with a reason, and every entry in
`ALLOWED` must still exist. The second direction matters as much as the first —
a suppression that outlives the code it was granted for is how an allowlist
turns into a rubber stamp.

Usage:  python3 .github/scripts/assert-sendable-audit.py [repo-root]
Exit:   0 when the tree matches the table, 1 otherwise.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# (path, declared symbol) -> why the escape hatch is the only option there.
#
# Keyed on the symbol as well as the file so that moving the hatch onto a
# different type in the same file reads as a new, unreviewed one.
ALLOWED: dict[tuple[str, str], str] = {
    (
        "Sources/Features/TextRecognition/Services/CameraService.swift",
        "CapturedFrame",
    ): (
        "Wraps a CMSampleBuffer. CoreMedia's types carry no Sendable "
        "annotation and are not ours to annotate, so the single hop this "
        "frame really takes — capture queue to recogniser, never mutated "
        "after capture, not retained past the recognise call — is not "
        "expressible to the checker."
    ),
    (
        "Sources/Features/TextRecognition/Services/CameraService.swift",
        "CameraService",
    ): (
        "Holds AVCaptureSession and AVCaptureVideoPreviewLayer, neither of "
        "which is Sendable, with every mutation of the session confined to "
        "sessionQueue. The isolation is a serial DispatchQueue rather than an "
        "actor because AVCaptureVideoDataOutputSampleBufferDelegate delivers "
        "on a queue you hand it, and the compiler cannot see that a queue "
        "guards a property. The frame stream is no longer part of this "
        "reason: it moved to DelegateStream, which keeps its state inside an "
        "OSAllocatedUnfairLock and is Sendable without an opt-out."
    ),
}

HATCHES = (
    re.compile(r"@unchecked\s+Sendable"),
    re.compile(r"\bnonisolated\(unsafe\)"),
)

# The declaration a hatch sits on, e.g. `final class CameraService: NSObject,`
# or `struct CapturedFrame: @unchecked Sendable {`. `nonisolated(unsafe)` sits
# on a property instead, so `let`/`var` is in the alternation too.
DECLARATION = re.compile(
    r"\b(?:actor|class|struct|enum|extension|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)"
)

SCANNED_DIRS = ("Sources", "Tests")


def declared_symbol(lines: list[str], index: int) -> str:
    """Name the declaration the hatch on `lines[index]` belongs to.

    A hatch is usually on the declaration line itself. When the declaration is
    wrapped across lines the hatch can land below it, so walk back a little to
    find the name rather than reporting the file alone.
    """
    for offset in range(0, 4):
        if index - offset < 0:
            break
        match = DECLARATION.search(lines[index - offset])
        if match:
            return match.group(1)
    return "<unknown>"


def find_hatches(root: Path) -> list[tuple[str, str, int, str]]:
    """Return (relative path, symbol, 1-based line number, line) per occurrence."""
    found: list[tuple[str, str, int, str]] = []
    for directory in SCANNED_DIRS:
        base = root / directory
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*.swift")):
            lines = path.read_text(encoding="utf-8").splitlines()
            for index, line in enumerate(lines):
                # A hatch named inside a comment is prose about one, not one.
                code = line.split("//", 1)[0]
                if not any(pattern.search(code) for pattern in HATCHES):
                    continue
                relative = path.relative_to(root).as_posix()
                found.append(
                    (relative, declared_symbol(lines, index), index + 1, line.strip())
                )
    return found


def main(argv: list[str]) -> int:
    root = Path(argv[1] if len(argv) > 1 else ".").resolve()
    found = find_hatches(root)
    seen: set[tuple[str, str]] = set()
    failures: list[str] = []

    for relative, symbol, line_number, text in found:
        key = (relative, symbol)
        seen.add(key)
        if key in ALLOWED:
            print(f"ok        {relative}:{line_number}  {symbol}")
            continue
        failures.append(
            f"::error file={relative},line={line_number}::Unrecorded opt-out of "
            f"Sendable checking on `{symbol}`: {text}. Prefer isolation "
            f"(an actor, @MainActor) or state held inside an "
            f"OSAllocatedUnfairLock, as the mock services and EventBus do. If "
            f"the hatch is genuinely unavoidable, add it to ALLOWED in "
            f"{Path(__file__).name} with the reason."
        )

    for key, reason in ALLOWED.items():
        if key not in seen:
            failures.append(
                f"::error::Stale entry in ALLOWED: {key[0]} no longer declares "
                f"`{key[1]}` with an opt-out. Granted for: {reason} — delete "
                f"the entry so the allowlist keeps meaning something."
            )

    print(
        f"\n{len(found)} opt-out(s) out of Sendable checking, "
        f"{len(ALLOWED)} recorded as allowed."
    )

    if failures:
        print()
        for failure in failures:
            print(failure)
        return 1

    print("Sendable audit passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
