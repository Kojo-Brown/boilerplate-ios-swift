#!/usr/bin/env python3
"""Fail on the three accessibility defects this package has actually shipped.

Phase 10 item 6 set out to check these at runtime, by hosting each control and
reading the accessibility tree UIKit publishes from it. That does not work in a
unit-test process, and the reason is worth writing down because it will come up
again: SwiftUI does not build its UIKit accessibility bridge unless an assistive
client is attached. `_UIHostingView.accessibilityElements` returns an *empty
array* — not nil, not a lazily-built tree — and the text is drawn into a
`CGDrawingView` that is not an element and vends nothing:

    _UIHostingView<...>  element=false elements=0 count=0 subviews=1
      PlatformContainer  element=false elements=nil count=0 subviews=1
        HostingScrollView element=false elements=nil count=0 subviews=2
          PlatformGroupContainer element=false elements=nil count=0
            CGDrawingView  element=false elements=nil count=0 subviews=0

That was read off a window with a real `UIWindowScene`, made key and visible,
fully laid out, on the iOS 18.5 simulator. It is a gate, not laziness, and no
arrangement of windows gets past it. Reading the published tree needs an
XCUITest target with a host app, which this package does not have — see
`docs/accessibility.md`.

So the runtime claim is replaced with a static one, and this file is honest
about the difference: it checks the *shape* of the three defects, in the source,
rather than what VoiceOver would say. That is less than was wanted and more than
nothing, and it has one property the runtime version would not have had — it
runs on Linux, in the lint job, alongside the module-boundary and Sendable
audits, which is where the scheduled agent can run it before pushing.

The rules, each of which is a bug this package shipped:

  1. A tap gesture VoiceOver cannot reach. `.onTapGesture` on a container
     publishes no trait, no action and no activation point, so the gesture is
     absent from the accessibility tree rather than hard to find. Every one must
     be paired with an `.accessibilityAction(named:)` offering the same thing.

  2. A control pinned in height. `.frame(maxWidth: .infinity)` followed by
     `.frame(height:)` is a view told to fill the width and forbidden to grow
     downwards — so its label is clipped through the middle at accessibility
     text sizes, while every preview at `.large` looks perfect. Use `minHeight`.

  3. An SF Symbol with nothing to call it. `Image(systemName:)` left in the
     tree is announced by the symbol's identifier — "xmark circle fill" — which
     is the asset's name, not an answer to what the control does. Each one is
     either decoration (`.accessibilityHidden(true)`), named
     (`.accessibilityLabel`), or inside a `Label`, which takes its name from its
     title.

Every exception is listed in `ALLOWED` with a reason, and every entry in
`ALLOWED` must still correspond to something in the tree. The second direction
matters as much as the first: an allowance whose code is gone is a rule quietly
weakened for a case that no longer exists.

Run it with `python3 Tools/assert-accessibility-audit.py`.
"""
from __future__ import annotations

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(REPO, "Sources")

# How far down a modifier chain a fix may sit. Chains in this package are
# written one modifier per line with comments between them, so this is generous
# on purpose: a false pass is a missing check, a false failure is a wasted CI
# round, and the rules below are narrow enough that the first is the rarer risk.
WINDOW = 10

TAP_GESTURE = re.compile(r"\.onTapGesture\b")
ACCESSIBILITY_ACTION = re.compile(r"\.accessibilityAction\(named:")
FILL_WIDTH = re.compile(r"\.frame\(maxWidth:\s*\.infinity")
PINNED_HEIGHT = re.compile(r"\.frame\(height:\s*[0-9]")
SYMBOL = re.compile(r"\bImage\(systemName:")
NAMED_OR_HIDDEN = re.compile(r"\.accessibilityHidden\(|\.accessibilityLabel\(")
INSIDE_LABEL = re.compile(r"\bLabel\(")

ALLOWED: dict[tuple[str, str], str] = {
    (
        "Sources/Features/Shared/Components/HeroTransition.swift",
        "onTapGesture",
    ): (
        "The scrim behind an expanded card. It is `.accessibilityHidden(true)` "
        "on the line above, because a full-screen dimming layer is not "
        "something to land on, and the dismissal it offers by tap is offered "
        "to VoiceOver as `.accessibilityAction(.escape)` on the card itself — "
        "which is the gesture VoiceOver already has for dismissing, rather "
        "than a named action a reader would have to discover. The other "
        "occurrence in this file is inside a `#Preview`."
    ),
}


def strip_noise(line: str, in_block: bool) -> tuple[str, bool]:
    """Drop comments so a rule written about code is not matched in prose."""
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
        out.append(ch)
        i += 1
    return "".join(out), in_block


def code_lines(path: str) -> list[str]:
    lines, in_block = [], False
    with open(path, encoding="utf-8") as handle:
        for raw in handle.read().split("\n"):
            code, in_block = strip_noise(raw, in_block)
            lines.append(code)
    return lines


def swift_files(root: str) -> list[str]:
    found = []
    for dirpath, _, names in os.walk(root):
        for name in sorted(names):
            if name.endswith(".swift"):
                found.append(os.path.join(dirpath, name))
    return sorted(found)


def follows(lines: list[str], index: int, pattern: re.Pattern[str]) -> bool:
    """Whether `pattern` appears on this line or the WINDOW lines after it."""
    return any(pattern.search(line) for line in lines[index:index + WINDOW + 1])


def precedes(lines: list[str], index: int, pattern: re.Pattern[str], back: int) -> bool:
    """Whether `pattern` appears on one of the `back` lines before this one."""
    return any(pattern.search(line) for line in lines[max(0, index - back):index])


def main() -> int:
    problems: list[str] = []
    seen: set[tuple[str, str]] = set()

    for path in swift_files(SOURCES):
        rel = os.path.relpath(path, REPO)
        lines = code_lines(path)

        for number, code in enumerate(lines, 1):
            index = number - 1

            if TAP_GESTURE.search(code):
                seen.add((rel, "onTapGesture"))
                if (rel, "onTapGesture") not in ALLOWED and not follows(
                    lines, index, ACCESSIBILITY_ACTION
                ):
                    problems.append(
                        f"{rel}:{number}: a tap gesture with no "
                        f".accessibilityAction(named:) beside it. VoiceOver cannot "
                        f"perform it and does not report that it exists."
                    )

            if PINNED_HEIGHT.search(code) and precedes(lines, index, FILL_WIDTH, 3):
                seen.add((rel, "pinnedHeight"))
                if (rel, "pinnedHeight") not in ALLOWED:
                    problems.append(
                        f"{rel}:{number}: a full-width control pinned to a fixed "
                        f"height. A fixed height is a ceiling as well as a floor, so "
                        f"the label is clipped at accessibility text sizes. Use "
                        f"minHeight, or scaledControlHeight()."
                    )

            if SYMBOL.search(code):
                seen.add((rel, "symbol"))
                named = follows(lines, index, NAMED_OR_HIDDEN)
                labelled = INSIDE_LABEL.search(code) or precedes(lines, index, INSIDE_LABEL, 3)
                if (rel, "symbol") not in ALLOWED and not named and not labelled:
                    problems.append(
                        f"{rel}:{number}: an SF Symbol that is neither hidden nor "
                        f"named. VoiceOver announces it by its identifier, which is "
                        f"the asset's name and not what the control does."
                    )

    for key in ALLOWED:
        if key not in seen:
            problems.append(
                f"Stale entry in ALLOWED: {key[0]} no longer contains a "
                f"{key[1]} occurrence, so the allowance is unused."
            )

    if problems:
        print("Accessibility audit failures:\n", file=sys.stderr)
        for problem in sorted(set(problems)):
            print(f"  {problem}", file=sys.stderr)
        print(f"\n{len(set(problems))} problem(s).", file=sys.stderr)
        return 1

    counted = len(swift_files(SOURCES))
    print(f"Accessibility audit passed across {counted} source files.")
    print(f"  {len(ALLOWED)} recorded exception(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
