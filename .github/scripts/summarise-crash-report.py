#!/usr/bin/env python3
"""Print the useful parts of a macOS .ips crash report.

When the test process dies rather than failing an assertion, xcodebuild reports
every test that had not finished as "failing" and says nothing about why the
process went away. The crash report says, but dumping it raw does not help: one
thread's register state runs to tens of kilobytes and buries the two things that
identify the bug — the Swift runtime's fatal-error message, carried in `asi`, and
the faulting thread's symbolicated frames.

Usage: summarise-crash-report.py <report.ips>
"""

import json
import sys

FRAME_LIMIT = 25


def main(path: str) -> int:
    with open(path, encoding="utf-8", errors="replace") as handle:
        handle.readline()  # an .ips is a JSON header line, then the payload
        try:
            report = json.load(handle)
        except json.JSONDecodeError as error:
            print(f"could not parse {path}: {error}")
            return 0  # diagnostics must never fail the step on their own

    print("exception  :", json.dumps(report.get("exception", {})))
    print("termination:", json.dumps(report.get("termination", {})))

    # `asi` maps a thread id to the runtime messages logged before trapping.
    # For a Swift precondition failure this is the actual error text.
    asi = report.get("asi") or {}
    for thread, messages in asi.items():
        for message in messages:
            print(f"asi[{thread}] : {message}")
    if not asi:
        print("asi        : (none recorded)")

    images = report.get("usedImages", [])
    threads = report.get("threads", [])
    index = report.get("faultingThread", 0)
    if index >= len(threads):
        print("(no faulting thread recorded)")
        return 0

    print(f"\nfaulting thread {index}:")
    for position, frame in enumerate(threads[index].get("frames", [])[:FRAME_LIMIT]):
        image_index = frame.get("imageIndex", -1)
        image = images[image_index].get("name", "?") if 0 <= image_index < len(images) else "?"
        symbol = frame.get("symbol") or f"+{frame.get('imageOffset')}"
        source = ""
        if frame.get("sourceFile"):
            source = f"  ({frame['sourceFile']}:{frame.get('sourceLine')})"
        print(f"  {position:2}  {image:<28} {symbol}{source}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
