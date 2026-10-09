#!/usr/bin/env python3
"""Fail if a test in this bundle is written so that it cannot fail.

Phase 12 item 1 moved the suite to Swift Testing. The two frameworks are
designed to coexist in one test target, and that is exactly what makes the
migration dangerous: every wrong combination below compiles, links, runs, and
reports success.

  * `XCTAssertEqual` inside a `@Test` function. XCTest's assertions report to
    the *current XCTestCase*, and inside a Swift Testing test there is not one.
    The failure is recorded against nothing; the test passes.
  * `#expect` inside an `XCTestCase`. Mirror image: the expectation is recorded
    against no current Swift Testing test, so a false expectation is lost.
  * `func testSomething()` left inside a suite that is no longer an
    `XCTestCase`. XCTest discovered methods by that name prefix; Swift Testing
    discovers the `@Test` attribute and nothing else. The method survives the
    migration, compiles, and is never called again — which is how a
    "migration" silently deletes coverage while every file still looks full of
    tests.
  * A `*Tests.swift` file with no test in it at all, for the same reason one
    step further along.

None of these is visible in a green CI run, which is the only reason this
script exists. It is deliberately not a Swift test: a test cannot catch the
case where tests have stopped running. It is syntactic, so it needs no
toolchain, no resolved packages and no simulator — it runs on Linux in the lint
job, and it is one of the three gates in this repo the scheduled agent can run
locally.

XCTest is not banned. It is still the only framework that can express a
performance baseline (`measure`) or drive a UI through XCUIApplication, and
Phase 12 item 4 will need it. What is banned is an *unrecorded* XCTest suite:
every `XCTestCase` must be listed in `ALLOWED_XCTEST_SUITES` with the reason
XCTest is the right choice there, and every entry must still exist — a stale
entry is how an allowlist turns into a rubber stamp.

Usage:  python3 Tools/assert-test-framework.py [repo-root]
Exit:   0 when every test in the tree can fail, 1 otherwise.
"""
from __future__ import annotations

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (file, suite type) -> why XCTest rather than Swift Testing.
#
# Empty, and that is the honest state of the tree: the six `*XCTests.swift`
# mirrors that used to be here were duplicate spellings of suites that already
# existed in Swift Testing, not uses of anything XCTest alone provides, so they
# were absorbed rather than kept. The table is here because the next XCTest
# suite will have a reason, and this is where it gets written down.
ALLOWED_XCTEST_SUITES: dict[tuple[str, str], str] = {}

IMPORT = re.compile(r"^\s*(?:@\w+\s+)*import\s+(\w+)")

# `final class FooTests: XCTestCase {`, and the same through a local base class
# is caught by the second pattern below naming any superclass list containing
# XCTestCase.
XCTEST_SUBCLASS = re.compile(
    r"\b(?:final\s+)?class\s+(\w+)\s*:\s*[^{]*\bXCTestCase\b"
)

# The XCTest surface that silently no-ops inside a Swift Testing test. `measure`
# and the expectation API are in here too: they are instance methods on
# XCTestCase, so a `@Test` cannot call them at all, but naming them gives a
# clearer error than "cannot find 'measure' in scope".
XCTEST_API = re.compile(
    r"\b(XCTAssert\w*|XCTFail|XCTUnwrap|XCTSkip\w*|XCTestExpectation"
    r"|XCTExpectFailure|expectation\(description:|wait\(for:)"
)

SWIFT_TESTING_MACRO = re.compile(r"#(expect|require)\s*\(")

# The XCTest naming convention, which Swift Testing does not honour.
XCTEST_METHOD = re.compile(r"\bfunc\s+(test[A-Z_]\w*|test)\s*\(")

TEST_ATTRIBUTE = re.compile(r"@Test\b")

STRING_LITERAL = re.compile(r'"(?:\\.|[^"\\])*"')


def code_lines(path: str) -> list[str]:
    """The file with string literals blanked and line comments removed.

    Literals go first so that a `//` inside one — a URL in a fixture — does not
    swallow the rest of the line, and so that an assertion *named* in a doc
    comment is not mistaken for one being called.
    """
    with open(path, encoding="utf-8") as handle:
        raw = handle.read().splitlines()
    out = []
    for line in raw:
        without_strings = STRING_LITERAL.sub('""', line)
        out.append(without_strings.split("//", 1)[0])
    return out


def swift_files(root: str) -> list[str]:
    found = []
    for base, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if d not in {".build", ".swiftpm"}]
        for name in names:
            if name.endswith(".swift"):
                found.append(os.path.join(base, name))
    return sorted(found)


def is_annotated(lines: list[str], index: int) -> bool:
    """Whether the declaration on `lines[index]` carries `@Test`.

    The attribute may sit on the `func` line or on its own line above it,
    possibly with other attributes between. Doc comments are already stripped,
    so the walk back stops at the first line that is neither blank nor an
    attribute.
    """
    if TEST_ATTRIBUTE.search(lines[index]):
        return True
    cursor = index - 1
    while cursor >= 0:
        stripped = lines[cursor].strip()
        if not stripped:
            cursor -= 1
            continue
        if not stripped.startswith("@"):
            return False
        if TEST_ATTRIBUTE.search(stripped):
            return True
        cursor -= 1
    return False


def main(argv: list[str]) -> int:
    root = os.path.abspath(argv[1]) if len(argv) > 1 else REPO
    tests = os.path.join(root, "Tests")
    problems: list[str] = []
    seen_suites: set[tuple[str, str]] = set()
    swift_testing_files = 0
    swift_testing_cases = 0
    xctest_suites = 0

    for path in swift_files(tests):
        rel = os.path.relpath(path, root)
        lines = code_lines(path)
        imports = {m.group(1) for m in (IMPORT.match(line) for line in lines) if m}
        uses_swift_testing = "Testing" in imports
        uses_xctest = "XCTest" in imports

        if uses_swift_testing and uses_xctest:
            problems.append(
                f"{rel}: imports both Testing and XCTest. One file, one "
                f"framework: it is the mixed file where a cross-framework "
                f"assertion gets written, and neither framework reports one."
            )

        declared_here = [
            (number, m.group(1))
            for number, line in enumerate(lines, 1)
            for m in [XCTEST_SUBCLASS.search(line)]
            if m
        ]
        xctest_suites += len(declared_here)
        for number, name in declared_here:
            key = (rel, name)
            seen_suites.add(key)
            if key not in ALLOWED_XCTEST_SUITES:
                problems.append(
                    f"{rel}:{number}: unrecorded XCTest suite `{name}`. Write it "
                    f"as a Swift Testing `@Suite` with `@Test` and `#expect`, or "
                    f"— if it needs `measure`, XCUIApplication or something else "
                    f"only XCTest provides — add it to ALLOWED_XCTEST_SUITES in "
                    f"Tools/assert-test-framework.py with that reason."
                )

        test_count = sum(len(TEST_ATTRIBUTE.findall(line)) for line in lines)
        if uses_swift_testing:
            swift_testing_files += 1
            swift_testing_cases += test_count

        for number, line in enumerate(lines, 1):
            if uses_swift_testing and not uses_xctest:
                found = XCTEST_API.search(line)
                if found:
                    problems.append(
                        f"{rel}:{number}: `{found.group(1)}` in a Swift Testing "
                        f"file. XCTest assertions report to the current "
                        f"XCTestCase, and inside a @Test there is none, so a "
                        f"failure here is recorded against nothing and the test "
                        f"passes. Use #expect / #require / Issue.record."
                    )
            if uses_xctest and not uses_swift_testing:
                found = SWIFT_TESTING_MACRO.search(line)
                if found:
                    problems.append(
                        f"{rel}:{number}: `#{found.group(1)}` inside an XCTest "
                        f"file. It is recorded against no current Swift Testing "
                        f"test, so it cannot fail the XCTestCase it sits in. Use "
                        f"XCTAssert…, or move the suite to Swift Testing."
                    )
            if uses_xctest:
                continue
            method = XCTEST_METHOD.search(line)
            if method and not is_annotated(lines, number - 1):
                problems.append(
                    f"{rel}:{number}: `{method.group(1)}` is named like an "
                    f"XCTest case but carries no @Test, and this file does not "
                    f"import XCTest. Nothing discovers it: it compiles and never "
                    f"runs. Add @Test, or rename it if it is a helper."
                )

        if os.path.basename(path).endswith("Tests.swift") and not declared_here:
            if test_count == 0:
                problems.append(
                    f"{rel}: a `*Tests.swift` file with no @Test in it and no "
                    f"XCTest suite. Either it holds tests nothing runs, or it is "
                    f"support code that should not be named `…Tests.swift`."
                )

    for key, reason in sorted(ALLOWED_XCTEST_SUITES.items()):
        if key not in seen_suites:
            problems.append(
                f"stale entry in ALLOWED_XCTEST_SUITES: {key[0]} no longer "
                f"declares `{key[1]}`. Granted for: {reason} — delete the entry "
                f"so the allowlist keeps meaning something."
            )

    if problems:
        print("Test-framework violations:\n", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print(f"\n{len(problems)} violation(s).", file=sys.stderr)
        return 1

    print(
        f"Test framework audit passed: {swift_testing_cases} @Test case(s) "
        f"across {swift_testing_files} Swift Testing file(s); "
        f"{xctest_suites} XCTest suite(s), {len(ALLOWED_XCTEST_SUITES)} recorded "
        f"as allowed."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
