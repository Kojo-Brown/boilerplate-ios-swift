#!/usr/bin/env python3
"""Hold the UI test host and its journey to the things that cannot fail loudly.

Phase 12 item 4. An XCUITest is the only kind of test in this repository whose
failures are mostly *not* assertions: a query against an identifier nothing
carries, a launch argument the app does not recognise, a skipped test nobody
notices. Each of those is a suite that runs, goes green, and establishes
nothing — and none of them is visible to the compiler, because the app and the
test bundle share no module. XCUITest is black-box by construction; `Sources/`
and `UITestHost/UITests/` agree by convention, and this is the file that makes
the convention checkable.

The rules, each one a failure mode this arrangement actually has:

  1. **The two identifier lists are the same list.** `AccessibilityID` is
     declared twice — `package` in `Core` for the views, and again in the test
     bundle, which is an Xcode target and cannot see `package` declarations in
     a SwiftPM one. A drifted copy compiles on both sides.

  2. **Every declared identifier is applied by a view.** A constant no view
     carries is a query that can only ever time out, and a timeout reads
     exactly like a regression in the screen it was looking at.

  3. **The launch argument matches.** `UITestLaunch.argument` and
     `UITestApplication.launchArgument` are the same string in two files. A
     mismatch is the worst outcome in this file, because it is silent *and*
     plausible: the app launches with the live dependency graph, the journey
     reaches for a network it does not have, and the suite reports as a flake.

  4. **No sleeps.** A `sleep` in a UI test is a wait tuned until it passed on
     one machine. Every wait in the bundle is a `waitForExistence` against the
     thing the previous step was supposed to produce.

  5. **The host's `Info.plist` permits the background task the app registers.**
     `BoilerplateApp`'s scene carries `.backgroundTask(.appRefresh(…))`, and
     that registration *raises* for an identifier missing from
     `BGTaskSchedulerPermittedIdentifiers`. The host would not finish
     launching, and every test would report the same unexplained failure.

  6. **The host's bundle identifier is the one the app expects.**
     `AppContainer.expectedBundleIdentifier` is what the integrity baseline
     compares against; a host under another identifier is a host the app can
     decide is tampered with.

  7. **Every `-skip-testing:` in CI names a test that exists**, and each of the
     two layout tests is skipped by at least one matrix leg and run by at least
     one. `xcodebuild` ignores an unknown `-skip-testing:` identifier, which
     fails safe — the test runs anyway — but a layout test skipped by *every*
     leg is an assertion nothing in CI performs.

  8. **The matrix is a matrix**, and it does not cancel its own legs: at least
     two distinct devices and `fail-fast: false`.

  9. **A suite that searches and then reaches for the toolbar dismisses the
     search in between.** An engaged `.searchable` field replaces the
     navigation bar's contents, so `HomeView`'s `ToolbarItem` is not in the
     published tree at all while one is open — not hidden, not unidentified,
     absent. A query for it then times out, and a timeout reads as a broken
     toolbar rather than as a bar showing something else; three runs of this
     job and one wrong change to the app went into that reading. This checks the call
     is present, not that it is in the right place: ordering is the test's own
     business and a Swift source order is not an execution order, so a
     misplaced call still fails on the simulator — with the bar's subtree in
     the message, which is what makes that failure readable.

 10. **Each leg's `skip` and `expect` are the two layout tests, one each.**
     `expect` is what the workflow's post-run step greps the test log for, and
     it is the only thing standing between this job and the one way it can
     report success having established nothing: `xcodebuild` exits 0 for a run
     that executed no tests. A leg whose `expect` is also its `skip` would
     assert that the test it skipped had run, which can only fail; a leg with
     no `expect` at all would check nothing.

It reads source, a plist and a workflow file with the standard library only, so
it runs on Linux in the audits job beside the others — which is where the
scheduled agent can run it, since it can run none of the gates that need Xcode.

Run it with `python3 Tools/assert-ui-test-journey.py`.
"""
from __future__ import annotations

import os
import plistlib
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

APP_IDENTIFIERS = os.path.join("Sources", "Core", "Accessibility", "AccessibilityID.swift")
TEST_IDENTIFIERS = os.path.join("UITestHost", "UITests", "Support", "AccessibilityID.swift")
LAUNCH_SEAM = os.path.join("Sources", "App", "UITestLaunch.swift")
TEST_APPLICATION = os.path.join("UITestHost", "UITests", "Support", "UITestApplication.swift")
CONTAINER = os.path.join("Sources", "App", "AppContainer.swift")
HOST_PLIST = os.path.join("UITestHost", "Host", "Info.plist")
PROJECT_SPEC = os.path.join("UITestHost", "project.yml")
WORKFLOW = os.path.join(".github", "workflows", "ci.yml")
SOURCES = os.path.join("Sources")
UI_TESTS = os.path.join("UITestHost", "UITests")

# `enum Login {` / `package enum Login {`, and the constants inside one.
NAMESPACE = re.compile(r"^\s*(?:package\s+)?enum\s+(\w+)\s*\{")
CONSTANT = re.compile(r"^\s*(?:package\s+)?static\s+let\s+(\w+)\s*=\s*\"([^\"]+)\"")

APPLIED = re.compile(r"\.accessibilityIdentifier\(\s*AccessibilityID\.(\w+)\.(\w+)\s*\)")
ARGUMENT = re.compile(r"(?:launchArgument|argument)\s*=\s*\"([^\"]+)\"")
REFRESH_IDENTIFIER = re.compile(r"backgroundRefreshIdentifier\s*=\s*\"([^\"]+)\"")
EXPECTED_BUNDLE = re.compile(r"expectedBundleIdentifier\s*=\s*\"([^\"]+)\"")
SPEC_BUNDLE = re.compile(r"^\s*PRODUCT_BUNDLE_IDENTIFIER:\s*(\S+)\s*$", re.MULTILINE)
SLEEP = re.compile(r"\b(?:Thread\.sleep|usleep|nanosleep)\b|(?<![\w.])sleep\s*\(")
TEST_FUNCTION = re.compile(r"^\s*func\s+(test\w+)\s*\(", re.MULTILINE)
SKIP_LINE = re.compile(r"^\s*skip:\s*(\S+)\s*$", re.MULTILINE)
EXPECT_LINE = re.compile(r"^\s*expect:\s*(\S+)\s*$", re.MULTILINE)
DEVICE_LINE = re.compile(r"^\s*- device:\s*(.+?)\s*$", re.MULTILINE)
# Rule 9's three calls, as a test writes them against `HomeScreen`. Matched on
# the method rather than on a receiver name, because the receiver is `home` in
# one step and `HomeScreen(app: app)` in the next.
SEARCH_CALL = re.compile(r"\.search\(for:")
TOOLBAR_CALL = re.compile(r"\.openSettings\(")
DISMISS_CALL = re.compile(r"\.dismissSearch\(")

# The two tests the matrix divides between its legs.
LAYOUT_TESTS = {
    "testHomeResolvesTheListLayoutOnACompactWidth",
    "testHomeResolvesTheGridLayoutOnARegularWidth",
}


def read(relative: str) -> str:
    with open(os.path.join(ROOT, relative), encoding="utf-8") as handle:
        return handle.read()


def swift_files(relative_root: str) -> list[str]:
    found: list[str] = []
    for base, _, names in os.walk(os.path.join(ROOT, relative_root)):
        for name in sorted(names):
            if name.endswith(".swift"):
                found.append(os.path.relpath(os.path.join(base, name), ROOT))
    return sorted(found)


def declared_identifiers(relative: str) -> dict[str, str]:
    """`{"Login.emailField": "login.emailField"}` for one of the two copies.

    The outermost `enum AccessibilityID` is skipped so that the keys are the
    screen-and-constant pairs a view writes at the call site, which is what
    rule 2 has to look for.
    """
    namespace = ""
    out: dict[str, str] = {}
    for line in read(relative).split("\n"):
        found = NAMESPACE.match(line)
        if found:
            name = found.group(1)
            namespace = "" if name == "AccessibilityID" else name
            continue
        constant = CONSTANT.match(line)
        if constant and namespace:
            out[f"{namespace}.{constant.group(1)}"] = constant.group(2)
    return out


def main() -> int:
    problems: list[str] = []

    # 1. The two lists are the same list.
    app_ids = declared_identifiers(APP_IDENTIFIERS)
    test_ids = declared_identifiers(TEST_IDENTIFIERS)
    if not app_ids:
        problems.append(f"{APP_IDENTIFIERS}: no identifiers found; the audit cannot check anything.")
    for key in sorted(set(app_ids) | set(test_ids)):
        in_app, in_test = app_ids.get(key), test_ids.get(key)
        if in_app is None:
            problems.append(
                f"{TEST_IDENTIFIERS}: declares AccessibilityID.{key}, which the app does not. "
                "A test querying it waits out its timeout against an element that cannot exist."
            )
        elif in_test is None:
            problems.append(
                f"{TEST_IDENTIFIERS}: does not declare AccessibilityID.{key}, which the app does. "
                "The two copies have to stay the same list."
            )
        elif in_app != in_test:
            problems.append(
                f"AccessibilityID.{key} is \"{in_app}\" in the app and \"{in_test}\" in the test "
                "bundle. One of the two is a query that will never match."
            )

    # 2. Every declared identifier is applied by a view.
    applied: set[str] = set()
    for path in swift_files(SOURCES):
        for namespace, constant in APPLIED.findall(read(path)):
            applied.add(f"{namespace}.{constant}")
    for key in sorted(app_ids):
        if key not in applied:
            problems.append(
                f"{APP_IDENTIFIERS}: AccessibilityID.{key} is declared and no view in Sources/ "
                "applies it. A query for it can only ever time out, which reads as a broken screen "
                "rather than as a missing modifier."
            )

    # 3. The launch argument matches.
    seam = ARGUMENT.findall(read(LAUNCH_SEAM))
    harness = ARGUMENT.findall(read(TEST_APPLICATION))
    if not seam or not harness:
        problems.append(
            f"Could not find the launch argument in {LAUNCH_SEAM} and {TEST_APPLICATION}; "
            "the audit cannot check that the app and the suite agree on it."
        )
    elif seam[0] != harness[0]:
        problems.append(
            f"The launch argument is \"{seam[0]}\" in {LAUNCH_SEAM} and \"{harness[0]}\" in "
            f"{TEST_APPLICATION}. The app would launch with the live dependency graph and the "
            "journey would reach for the network."
        )
    elif seam[0].startswith("-"):
        problems.append(
            f"The launch argument \"{seam[0]}\" begins with a dash, so UserDefaults reads it as a "
            "key and takes the next argument as its value. Use a bare token."
        )

    # 4. No sleeps in the suite.
    for path in swift_files(UI_TESTS):
        for number, line in enumerate(read(path).split("\n"), start=1):
            code = line.split("//", 1)[0]
            if SLEEP.search(code):
                problems.append(
                    f"{path}:{number}: a sleep in a UI test is a wait tuned until it passed once. "
                    "Wait for the element the previous step was supposed to produce."
                )

    # 5. The host permits the background task the app registers.
    with open(os.path.join(ROOT, HOST_PLIST), "rb") as handle:
        host_info = plistlib.load(handle)
    refresh = REFRESH_IDENTIFIER.search(read(CONTAINER))
    if not refresh:
        problems.append(f"{CONTAINER}: could not read backgroundRefreshIdentifier.")
    else:
        permitted = host_info.get("BGTaskSchedulerPermittedIdentifiers", [])
        if refresh.group(1) not in permitted:
            problems.append(
                f"{HOST_PLIST}: BGTaskSchedulerPermittedIdentifiers is {permitted!r} and does not "
                f"contain \"{refresh.group(1)}\", which BoilerplateApp's scene registers. "
                "The registration raises, so the host does not finish launching."
            )
        if "fetch" not in host_info.get("UIBackgroundModes", []):
            problems.append(
                f"{HOST_PLIST}: UIBackgroundModes must contain \"fetch\" for an app that schedules "
                "a BGAppRefreshTask."
            )

    # 6. The host's bundle identifier is the one the app expects.
    expected = EXPECTED_BUNDLE.search(read(CONTAINER))
    spec_bundles = SPEC_BUNDLE.findall(read(PROJECT_SPEC))
    if not expected:
        problems.append(f"{CONTAINER}: could not read expectedBundleIdentifier.")
    elif expected.group(1) not in spec_bundles:
        problems.append(
            f"{PROJECT_SPEC}: no target declares PRODUCT_BUNDLE_IDENTIFIER "
            f"\"{expected.group(1)}\", which is AppContainer.expectedBundleIdentifier. The host "
            "would run under an identifier the app's own integrity baseline rejects."
        )

    # 7. and 8. The matrix, and what each leg skips.
    workflow = read(WORKFLOW)
    ui_test_names: set[str] = set()
    for path in swift_files(UI_TESTS):
        ui_test_names.update(TEST_FUNCTION.findall(read(path)))
    skipped = SKIP_LINE.findall(workflow)
    devices = DEVICE_LINE.findall(workflow)

    if not skipped:
        problems.append(
            f"{WORKFLOW}: the ui-test matrix declares no `skip:`, so every leg runs both layout "
            "tests and one of them must fail."
        )
    for identifier in skipped:
        name = identifier.rsplit("/", 1)[-1]
        if name not in ui_test_names:
            problems.append(
                f"{WORKFLOW}: -skip-testing:{identifier} names \"{name}\", which is not a test in "
                f"{UI_TESTS}. xcodebuild ignores an unknown identifier, so that leg runs a test it "
                "was meant to skip."
            )
    # One `skip:` per leg, in order, so the two directions below can be asked
    # per leg rather than of the set: "some leg skips this" and "some leg does
    # not" are both needed, and a set loses the second.
    per_leg = [identifier.rsplit("/", 1)[-1] for identifier in skipped]
    for name in sorted(LAYOUT_TESTS):
        if name not in ui_test_names:
            problems.append(f"{UI_TESTS}: the layout test \"{name}\" is gone; update this audit.")
            continue
        if name not in per_leg:
            problems.append(
                f"{WORKFLOW}: no matrix leg skips \"{name}\", so it runs on every device and "
                "cannot pass on all of them — the layouts are exclusive."
            )
        if per_leg and all(skipped_name == name for skipped_name in per_leg):
            problems.append(
                f"{WORKFLOW}: every leg skips \"{name}\", so nothing in CI ever asserts it."
            )

    # 9. A suite that searches and then opens the toolbar dismisses the search.
    for path in swift_files(UI_TESTS):
        body = read(path)
        if SEARCH_CALL.search(body) and TOOLBAR_CALL.search(body) and not DISMISS_CALL.search(body):
            problems.append(
                f"{path}: searches and then opens the Home toolbar menu without calling "
                "dismissSearch(). An engaged .searchable field replaces the navigation bar's "
                "contents, so the ToolbarItem is not in the published tree while one is open and "
                "the query can only time out."
            )

    # 10. Each leg skips one layout test and expects the other.
    expected = EXPECT_LINE.findall(workflow)
    if len(expected) != len(skipped):
        problems.append(
            f"{WORKFLOW}: the ui-test matrix has {len(skipped)} `skip:` and {len(expected)} "
            "`expect:`. Every leg needs both — `expect` is what the post-run step greps the test "
            "log for, and a leg without one cannot tell a run that executed nothing from a pass."
        )
    else:
        for index, (skip_id, expect_id) in enumerate(zip(skipped, expected)):
            skip_name = skip_id.rsplit("/", 1)[-1]
            expect_name = expect_id.rsplit("/", 1)[-1]
            if expect_name not in ui_test_names:
                problems.append(
                    f"{WORKFLOW}: leg {index + 1} expects \"{expect_name}\", which is not a test "
                    f"in {UI_TESTS}. The post-run grep would fail every run of that leg."
                )
            if {skip_name, expect_name} != LAYOUT_TESTS:
                problems.append(
                    f"{WORKFLOW}: leg {index + 1} skips \"{skip_name}\" and expects "
                    f"\"{expect_name}\"; the two have to be the two layout tests, one each. A leg "
                    "that expects what it skipped asserts that a skipped test ran."
                )

    if len(set(devices)) < 2:
        problems.append(
            f"{WORKFLOW}: the ui-test matrix names {len(set(devices))} device(s). A journey run on "
            "one simulator is not a matrix, and the grid branch of HomeView needs a regular width."
        )
    if not re.search(r"^\s*fail-fast:\s*false\s*$", workflow, re.MULTILINE):
        problems.append(
            f"{WORKFLOW}: the ui-test matrix must set `fail-fast: false`. Cancelling the siblings "
            "on the first red leg hides whether the others would have passed, which is the only "
            "thing a matrix is for."
        )

    if problems:
        print("UI test journey audit failed:\n")
        for problem in problems:
            print(f"  {problem}\n")
        print(f"{len(problems)} problem(s).")
        return 1

    print("UI test journey audit passed.")
    print(f"  {len(app_ids)} identifiers declared twice and applied in Sources/,")
    print(f"  launch argument agreed, no sleeps across {len(swift_files(UI_TESTS))} suite files,")
    print(f"  host plist permits the refresh task, matrix covers {len(set(devices))} devices,")
    print(f"  and each of its {len(expected)} legs expects the layout test it does not skip")
    return 0


if __name__ == "__main__":
    sys.exit(main())
