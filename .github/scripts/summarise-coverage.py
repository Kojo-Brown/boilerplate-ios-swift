#!/usr/bin/env python3
"""Turn an `xcrun xccov view --report --json` dump into a readable summary.

`-enableCodeCoverage YES` has been passed to the test run since the gates
workflow existed, but nothing ever read the result, so the numbers were measured
and thrown away. This prints them to the log and, when running under Actions,
writes a table to the job summary so the figure is visible without downloading
the .xcresult.

The report is a tree — targets, then files, then functions — and only the first
two levels are worth showing: a per-function table for this package runs to
hundreds of rows.

No threshold is enforced here. Adding one is a deliberate decision about a
number, not part of promoting a workflow, and a threshold invented alongside the
first measurement is a threshold fitted to whatever today happens to be.

Usage: summarise-coverage.py <coverage.json>
"""

import json
import os
import sys


def pct(value: float) -> str:
    return f"{value * 100:.2f}%"


def main(path: str) -> int:
    with open(path, encoding="utf-8") as handle:
        report = json.load(handle)

    covered = report.get("coveredLines", 0)
    executable = report.get("executableLines", 0)
    overall = report.get("lineCoverage", 0.0)

    rows = []
    for target in report.get("targets", []):
        # The test bundle's own coverage is not a quality signal — it reports how
        # much of the test code ran, which is ~100% by construction — but it is
        # left in the table rather than filtered, because deciding what counts as
        # "a test target" by name is exactly the kind of guess that goes stale.
        rows.append(
            (
                target.get("name", "(unnamed)"),
                target.get("lineCoverage", 0.0),
                target.get("coveredLines", 0),
                target.get("executableLines", 0),
            )
        )
    rows.sort(key=lambda row: row[1])

    print(f"Line coverage: {pct(overall)} ({covered}/{executable} executable lines)")
    for name, line_coverage, target_covered, target_executable in rows:
        print(f"  {pct(line_coverage):>8}  {name} ({target_covered}/{target_executable})")

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_path:
        return 0

    lines = [
        "## Code coverage",
        "",
        f"**{pct(overall)}** overall — {covered} of {executable} executable lines.",
        "",
        "| Target | Line coverage | Covered | Executable |",
        "| --- | ---: | ---: | ---: |",
    ]
    lines += [
        f"| `{name}` | {pct(line_coverage)} | {target_covered} | {target_executable} |"
        for name, line_coverage, target_covered, target_executable in rows
    ]
    with open(summary_path, "a", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")

    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1]))
