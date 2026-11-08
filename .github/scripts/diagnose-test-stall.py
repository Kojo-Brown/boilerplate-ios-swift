#!/usr/bin/env python3
"""Say whether a red test run is a failing test or a stalled host.

Phase 12 item 4. This repository has now spent three CI runs working out the
same thing by hand, and the answer was the same every time.

The package's suite contains tests that measure elapsed time and SwiftUI body
evaluations — `TimeoutTests.aSuccessDoesNotWaitOutTheBudget` asserts that a
successful operation does not wait out its deadline,
`HomeViewModelConcurrencyTests.stopLiveUpdatesHaltsGrowth` asserts that a
cancelled poller stops appending, `ViewIdentityTests` counts renders. On a
healthy runner they pass in milliseconds. On a runner whose host has stalled
they are the first things to break, and what `xcodebuild` prints is a list of
test names — which reads exactly like a regression in whatever the branch
happened to touch.

Three signatures separate the two, and all three are already in `test.log`:

  * **The two reporters disagree.** Swift Testing keeps its own tally and
    prints `Test run with N tests passed after X seconds`. `xcodebuild` keeps
    another and prints `Failing tests:`. A run where the harness saw every test
    pass and `xcodebuild` named one as failing is not a test that failed an
    assertion — nothing reported an issue to the harness.

  * **The clock disagrees with itself.** `IDETestOperationsObserverDebug: N
    elapsed` is wall-clock around the whole test phase; the harness's own
    figure is how long the tests took. A run that spends 238 seconds to execute
    5.7 seconds of tests spent 232 seconds not running them.

  * **Tests that cannot be slow report as slow.** A suite with a one-minute
    time limit tripping it on an assertion about a constant, or a batch of
    unrelated tests all reporting nearly the same multi-second duration, is a
    freeze rather than N independent regressions.

This is a diagnosis, never a gate: it reads a log, prints what it found, and
always exits 0. Nothing here can turn a red run green or a green run red, and
it deliberately does not try to decide whether to retry — that is a person's
call, and the point of this script is to give them the sentence they need to
make it.

It needs no toolchain and no simulator, so it is also runnable on the
scheduled agent's Linux box against an uploaded `test.log`:

    python3 .github/scripts/diagnose-test-stall.py test.log
"""

from __future__ import annotations

import re
import sys

# `✔ Test run with 120 tests passed after 5.695 seconds.`
RUN_TALLY = re.compile(
    r"Test run with (\d+) tests? (passed|failed) after ([\d.]+) seconds"
)

# `[MT] IDETestOperationsObserverDebug: 237.952 elapsed -- Testing started completed.`
OBSERVED_ELAPSED = re.compile(
    r"IDETestOperationsObserverDebug:\s+([\d.]+)\s+elapsed\s+--\s+Testing started completed"
)

# `✔ Test "…" passed after 0.212 seconds.` / `✘ Test foo() failed after …`
ONE_TEST = re.compile(r"Test (.+?) (passed|failed) after ([\d.]+) seconds")

# The block xcodebuild prints before `** TEST EXECUTE FAILED **`.
FAILING_HEADER = re.compile(r"^\s*Failing tests:\s*$")

# A test that takes this long, in a suite whose tests are milliseconds, is the
# freeze rather than the work.
SLOW_TEST_SECONDS = 30.0

# Below this, the gap between wall-clock and the harness's figure is build
# teardown, coverage export and simulator shutdown rather than a stall.
STALL_SECONDS = 60.0


def failing_test_names(lines: list[str]) -> list[str]:
    """The names under `Failing tests:`, which run until the first blank line."""
    names: list[str] = []
    for index, line in enumerate(lines):
        if not FAILING_HEADER.match(line):
            continue
        for candidate in lines[index + 1 :]:
            stripped = candidate.strip()
            if not stripped:
                break
            if stripped.startswith("**"):
                break
            names.append(stripped)
    # xcodebuild prints the block once per test bundle, so the same name can
    # arrive twice; order is worth keeping, duplicates are not.
    return list(dict.fromkeys(names))


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: diagnose-test-stall.py <test.log>", file=sys.stderr)
        return 0

    path = argv[1]
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError as error:
        print(f"Could not read {path}: {error}")
        return 0

    lines = text.split("\n")

    tally = RUN_TALLY.search(text)
    observed = OBSERVED_ELAPSED.search(text)
    failing = failing_test_names(lines)

    harness_total = int(tally.group(1)) if tally else None
    harness_verdict = tally.group(2) if tally else None
    harness_seconds = float(tally.group(3)) if tally else None
    observed_seconds = float(observed.group(1)) if observed else None

    print("What the two reporters said about this run:")
    if tally:
        print(
            f"  Swift Testing : {harness_total} tests {harness_verdict} "
            f"in {harness_seconds:.3f}s"
        )
    else:
        print("  Swift Testing : no run tally in the log (it may not have started)")
    if observed:
        print(f"  xcodebuild    : {observed_seconds:.3f}s of wall-clock around the phase")
    else:
        print("  xcodebuild    : no elapsed line in the log")
    print(
        "  xcodebuild    : "
        + (f"named {len(failing)} failing test(s): {', '.join(failing)}" if failing
           else "named no failing tests")
    )

    # Per line rather than over the whole text, because `Test run with 120
    # tests passed after 120.400 seconds` satisfies ONE_TEST as well — it
    # yielded a "slowest test" called "run with 120 tests" until this skipped
    # the tally line it belongs to.
    slow = sorted(
        (
            (float(match.group(3)), match.group(1))
            for line in lines
            if not RUN_TALLY.search(line)
            for match in [ONE_TEST.search(line)]
            if match and float(match.group(3)) >= SLOW_TEST_SECONDS
        ),
        reverse=True,
    )

    findings: list[str] = []

    if harness_verdict == "passed" and failing:
        findings.append(
            "The two reporters disagree: Swift Testing saw every test pass, and "
            "xcodebuild still named "
            f"{'one' if len(failing) == 1 else str(len(failing))} as failing. A "
            "test that fails an assertion reports that issue to the harness, so "
            "this is not one."
        )

    if observed_seconds is not None and harness_seconds is not None:
        unaccounted = observed_seconds - harness_seconds
        if unaccounted >= STALL_SECONDS:
            findings.append(
                f"The phase spent {unaccounted:.0f}s not running tests "
                f"({observed_seconds:.0f}s of wall-clock around {harness_seconds:.1f}s "
                "of test work). Build teardown and coverage export are seconds, not "
                "minutes."
            )

    if slow:
        findings.append(
            f"{len(slow)} test(s) reported {SLOW_TEST_SECONDS:.0f}s or more, the "
            f"slowest being {slow[0][1]} at {slow[0][0]:.1f}s. In this suite that is "
            "the host, not the test."
        )

    print()
    if findings:
        print("This looks like a stalled host rather than a failing test:")
        for finding in findings:
            print(f"  * {finding}")
        print()
        print(
            "Check the DiagnosticReports listing in the next step for crash reports "
            "from processes this repository does not own. Nothing here changes the "
            "job's result: the run is still red and must not be merged. Re-run it, "
            "and if the same named tests fail on a healthy runner, they are real."
        )
    else:
        print(
            "No stall signature found. Treat the named failures as real and fix "
            "them; do not re-run and hope."
        )

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
