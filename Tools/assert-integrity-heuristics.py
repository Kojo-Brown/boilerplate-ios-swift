#!/usr/bin/env python3
"""Fail if the jailbreak and tamper heuristics stop being heuristics.

Phase 11 item 4. Jailbreak detection has one failure mode that matters and it is
not "a check is wrong" — it is "a check is no longer connected to anything", and
every gate in this repo is blind to it. The code compiles, the tests pass, the
app launches, and the suite has quietly become decoration:

  * **A signal nothing raises.** `IntegritySignal` is an enum, and a case no
    longer produced by `DeviceIntegrityEvaluator` is a heuristic that exists in
    the documentation, in the log format and in the server's triage table, and
    nowhere in the app. Removing the branch that raises it is a one-line change
    and breaks no build.

  * **An evaluator that reads the device.** The evaluation is testable only
    because it is a pure function over a value: a jailbroken device cannot be
    brought into CI, so the half that decides what an observation *means* has to
    be reachable with a value a test writes down. One `Bundle.main` in that file
    and the whole thing is untestable again, and it is by far the most natural
    edit anybody will make to it.

  * **A mitigation that terminates.** `IntegrityResponse` deliberately has no
    case that refuses to run, because the check runs inside the process it is
    judging: on the device where it would matter the attacker owns the branch,
    and on every other device a false positive is a customer holding an app that
    will not open. A `case blocked` added in good faith six months from now
    reverses that decision silently.

  * **A probe that leaves a trace.** The published way to test for a writable
    filesystem is to create a file outside the container and delete it. The path
    where the delete fails is exactly the compromised device the check exists
    for, so this probe asks `access(2)` and writes nothing — a property nothing
    else can check.

  * **Two copies of the artefact list.** A second list is a list that drifts, and
    the one that drifts is always the one that stops matching modern jailbreaks.

Each rule below was verified by reintroducing the defect it names and watching
this script fail. It is deliberately a script rather than a test: it needs no
toolchain, no resolved packages and no simulator, so it runs on Linux in the
lint job, reports even when the build is broken, and is one of the few gates the
scheduled agent can run before pushing.

Run it with `python3 Tools/assert-integrity-heuristics.py [repo-root]`.
"""
from __future__ import annotations

import os
import re
import sys

# MARK: - The files this is about

SIGNAL_SOURCE = os.path.join("Sources", "Core", "Security", "Integrity", "IntegritySignal.swift")
EVALUATOR_SOURCE = os.path.join(
    "Sources", "Core", "Security", "Integrity", "DeviceIntegrityEvaluator.swift"
)
PROBE_SOURCE = os.path.join(
    "Sources", "Core", "Security", "Integrity", "SystemIntegrityProbe.swift"
)
POLICY_SOURCE = os.path.join("Sources", "Core", "Security", "Integrity", "IntegrityPolicy.swift")
CONTAINER_SOURCE = os.path.join("Sources", "App", "AppContainer.swift")
# Both halves of the test file. It was one file until it crossed SwiftLint's
# length ceiling, and rule 3 reads the pair rather than one of them, so that
# moving a suite between them is not a way to lose a heuristic's test.
TEST_SOURCES = (
    os.path.join("Tests", "ViewModelTests", "DeviceIntegrityTests.swift"),
    os.path.join("Tests", "ViewModelTests", "DeviceIntegrityPolicyTests.swift"),
)
THREAT_MODEL = os.path.join("docs", "threat-model.md")
INTEGRITY_DIR = os.path.join("Sources", "Core", "Security", "Integrity")

# The heading the threat model has to carry. The item asks for a *documented*
# threat model, and a page that lists the checks without stating what they cannot
# do is the marketing version — which is worse than no page, because it is the
# one somebody quotes in a security questionnaire.
REQUIRED_HEADING = "## What these heuristics cannot do"

# MARK: - What the evaluator may not name
#
# Anything that reads the running environment. The evaluator's whole value is
# that it does not, so this is the list of ways to accidentally give that up.
SYSTEM_APIS = (
    "FileManager",
    "Bundle.",
    "ProcessInfo",
    "UIApplication",
    "_dyld",
    "sysctl",
    "getpid",
    "access(",
    "stat(",
    "import Darwin",
    "import MachO",
    "targetEnvironment(",
)

# Ways to end the process, none of which belongs anywhere near a heuristic.
TERMINATION_APIS = (
    "fatalError",
    "preconditionFailure",
    "assertionFailure",
    "exit(",
    "abort(",
)

# Ways to put bytes on the filesystem. The probe reads and nothing else.
FILESYSTEM_WRITES = (
    "createFile",
    ".write(to:",
    "removeItem",
    "createDirectory",
    "FileHandle",
    "fopen",
    "mkdir",
    "unlink",
)

# Fragments that only appear in a jailbreak artefact path. One list, one file.
ARTEFACT_FRAGMENTS = (
    "/var/jb",
    "MobileSubstrate",
    "Cydia",
    "Sileo",
    "libhooker",
    "TweakInject",
)

# The two cases `IntegrityResponse` is allowed to have. See the docstring.
ALLOWED_RESPONSES = {"observe", "restrict"}

# The one function in the composition root that turns a report into the policy
# the token store is built with. Named here so rule 8 can insist the store is
# built from its result rather than from a policy written in place.
UNLOCK_RESOLVER = "unlockPolicy"

def swift_files(directory: str) -> list[str]:
    found = []
    for root, _, names in os.walk(directory):
        found.extend(os.path.join(root, name) for name in names if name.endswith(".swift"))
    return sorted(found)


def strip_comments(source: str) -> list[str]:
    """Returns the lines of `source` with comments blanked out and everything
    else — string literals included — left where it was.

    Line numbers are preserved, so a violation is still reported where it is.
    String literals survive on purpose: a key like `"authToken"` lives in one,
    and it is exactly what these rules look for.

    Two details are load-bearing, and both were found by getting them wrong.
    Comments have to go, because `BackgroundRefreshLedger` documents *why a
    failure count is in `UserDefaults` and tokens are not* one line above the
    `UserDefaults` it is describing — a scanner that reads prose fails this repo
    on the paragraph stating the rule. And string literals have to be understood
    rather than scanned, because `"https://api.example.com/v1"` contains `//`:
    treating that as a comment swallows the rest of the line, unbalances its
    brackets, and silently merges the remainder of the file into one statement.
    """
    out: list[str] = []
    line: list[str] = []
    index = 0
    length = len(source)
    state = "code"  # code | line_comment | block_comment | string | multiline

    while index < length:
        char = source[index]
        ahead = source[index:index + 3]

        if char == "\n":
            out.append("".join(line))
            line = []
            index += 1
            if state == "line_comment":
                state = "code"
            elif state in ("block_comment", "multiline"):
                pass
            elif state == "string":
                # An unterminated single-line string: the file would not
                # compile, so stop pretending to understand it.
                state = "code"
            continue

        if state == "code":
            if ahead == '\"\"\"':
                state = "multiline"
                line.append(ahead)
                index += 3
                continue
            if char == '"':
                state = "string"
                line.append(char)
                index += 1
                continue
            if source[index:index + 2] == "//":
                state = "line_comment"
                index += 2
                continue
            if source[index:index + 2] == "/*":
                state = "block_comment"
                index += 2
                continue
            line.append(char)
            index += 1
            continue

        if state == "string":
            line.append(char)
            if char == "\\" and index + 1 < length and source[index + 1] != "\n":
                line.append(source[index + 1])
                index += 2
                continue
            if char == '"':
                state = "code"
            index += 1
            continue

        if state == "multiline":
            if ahead == '\"\"\"':
                state = "code"
                line.append(ahead)
                index += 3
                continue
            line.append(char)
            index += 1
            continue

        if state == "block_comment":
            if source[index:index + 2] == "*/":
                state = "code"
                index += 2
                continue
            index += 1
            continue

        # line_comment: everything up to the newline is dropped.
        index += 1

    out.append("".join(line))
    return out




def statements(lines: list[str]) -> list[tuple[int, str]]:
    """Joins each line with the ones that continue it, so that a call split over
    four lines is read as the one call it is.

    A statement is taken to continue while its brackets are unbalanced. That is
    coarse — it knows nothing about strings containing brackets — and it is the
    right kind of coarse here: it can only ever join *more* text into the
    statement a rule is looking at, so it cannot hide a violation.
    """
    joined = []
    depth = 0
    start = 0
    current: list[str] = []
    for number, line in enumerate(lines, 1):
        if not current:
            start = number
        current.append(line.strip())
        depth += line.count("(") + line.count("[") - line.count(")") - line.count("]")
        if depth <= 0:
            joined.append((start, " ".join(part for part in current if part)))
            current = []
            depth = 0
    if current:
        joined.append((start, " ".join(part for part in current if part)))
    return joined


def read(repo: str, relative: str, problems: list[str]) -> str | None:
    path = os.path.join(repo, relative)
    if not os.path.isfile(path):
        problems.append(f"{relative}: not found.")
        return None
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def code_of(source: str) -> str:
    """The file with its prose removed, so a rule cannot be tripped by a comment
    explaining the thing it forbids — every one of these files argues at length
    about APIs it deliberately does not call."""
    return "\n".join(strip_comments(source))


# MARK: - The rules


def signal_cases(source: str, problems: list[str]) -> dict[str, str]:
    """The `IntegritySignal` cases, as {case name: wire name}."""
    body = re.search(
        r"package enum IntegritySignal[^{]*\{(.*)\n\}", code_of(source), re.DOTALL
    )
    if not body:
        problems.append(f"{SIGNAL_SOURCE}: no `package enum IntegritySignal` found.")
        return {}
    cases = dict(re.findall(r'\n\s*case\s+(\w+)\s*=\s*"([^"]+)"', body.group(1)))
    if not cases:
        problems.append(f"{SIGNAL_SOURCE}: IntegritySignal declares no cases with wire names.")
    return cases


def check_every_signal_is_raised(cases: dict[str, str], evaluator: str, problems: list[str]) -> None:
    """Rule 1: every signal is produced by the evaluator.

    A case nothing raises is a heuristic that exists in the log format, the
    documentation and the server's triage table, and nowhere in the app.
    """
    # Statements rather than lines: a `fire(` call whose argument sits on the
    # next line is still a raise, and a rule that could not see it would be a
    # rule that fails on formatting.
    joined = " ".join(
        re.sub(r"\s+", " ", statement) for _, statement in statements(strip_comments(evaluator))
    )
    for name in sorted(cases):
        if f"fire( .{name}" not in joined and f"fire(.{name}" not in joined:
            problems.append(
                f"{EVALUATOR_SOURCE}: nothing raises IntegritySignal.{name}. "
                f"A signal no observation can produce is a heuristic that does not exist."
            )


def check_every_signal_is_documented(cases: dict[str, str], page: str, problems: list[str]) -> None:
    """Rule 2: the threat model names every signal, by its wire name.

    The wire name rather than the Swift case, because that is the string a log
    line carries and the thing somebody triaging an alert has in hand.
    """
    for name, wire in sorted(cases.items()):
        if wire not in page:
            problems.append(
                f"{THREAT_MODEL}: does not document `{wire}` (IntegritySignal.{name}). "
                f"A signal nobody can look up is a signal nobody can triage."
            )
    if REQUIRED_HEADING not in page:
        problems.append(
            f"{THREAT_MODEL}: missing the `{REQUIRED_HEADING}` section. "
            f"A threat model that lists only what the checks catch is the marketing version."
        )


def check_every_signal_is_tested(cases: dict[str, str], tests: str, problems: list[str]) -> None:
    """Rule 3: every signal is named by the tests."""
    code = code_of(tests)
    for name in sorted(cases):
        # Word-bounded, because the case names share prefixes: a plain substring
        # search lets `.bundleIdentifierMismatch` be satisfied by a longer
        # identifier that merely starts the same way.
        if not re.search(rf"\.{re.escape(name)}\b", code):
            problems.append(
                f"{' or '.join(TEST_SOURCES)}: never names IntegritySignal.{name}. "
                f"Every heuristic gets a test that fires it and a test that does not."
            )


def check_evaluator_is_pure(evaluator: str, problems: list[str]) -> None:
    """Rule 4: the evaluator reads no part of the running environment.

    This is the rule that keeps any of this testable. The half that decides what
    an observation means has to be a pure function over a value, because the
    device state worth testing against is one CI cannot have.
    """
    lines = strip_comments(evaluator)
    for number, line in enumerate(lines, 1):
        for api in SYSTEM_APIS:
            if api in line:
                problems.append(
                    f"{EVALUATOR_SOURCE}:{number}: names `{api}`. The evaluator is a pure "
                    f"function over IntegrityObservations; reading the device here is what "
                    f"makes the evaluation untestable."
                )


def check_nothing_terminates(repo: str, problems: list[str]) -> None:
    """Rule 5: no heuristic can end the process, and no response says to.

    `IntegrityResponse` has no case that refuses to run, and that absence is the
    most important decision in this feature — `IntegrityResponse` itself carries
    the argument. This is what keeps it from being reversed by a well-meaning
    `case blocked` six months from now.
    """
    directory = os.path.join(repo, INTEGRITY_DIR)
    if not os.path.isdir(directory):
        problems.append(f"{INTEGRITY_DIR}/: not found.")
        return
    for path in swift_files(directory):
        relative = os.path.relpath(path, repo)
        with open(path, encoding="utf-8") as handle:
            lines = strip_comments(handle.read())
        for number, line in enumerate(lines, 1):
            for api in TERMINATION_APIS:
                if api in line:
                    problems.append(
                        f"{relative}:{number}: names `{api}`. A heuristic that can end the "
                        f"process turns a false positive into an app that will not open."
                    )


def check_response_cases(policy: str, problems: list[str]) -> None:
    """Rule 5, second half: the responses are the two that degrade."""
    body = re.search(
        r"package enum IntegrityResponse[^{]*\{(.*?)\n\s*package var description",
        code_of(policy),
        re.DOTALL,
    )
    if not body:
        problems.append(f"{POLICY_SOURCE}: no `package enum IntegrityResponse` found.")
        return
    declared = set(re.findall(r"\n\s*case\s+(\w+)", body.group(1)))
    unexpected = sorted(declared - ALLOWED_RESPONSES)
    if unexpected:
        problems.append(
            f"{POLICY_SOURCE}: IntegrityResponse declares {unexpected}, which is not one of "
            f"{sorted(ALLOWED_RESPONSES)}. Every response has to degrade — see the type's own "
            f"documentation for why refusing to run is both ineffective and expensive."
        )
    missing = sorted(ALLOWED_RESPONSES - declared)
    if missing:
        problems.append(f"{POLICY_SOURCE}: IntegrityResponse no longer declares {missing}.")


def check_probe_writes_nothing(probe: str, problems: list[str]) -> None:
    """Rule 6: the probe reads and nothing else.

    The published form of the writable-filesystem check creates a file outside
    the container and deletes it, which leaves evidence of the probe on the
    device and fails to clean up on exactly the compromised device it exists for.
    """
    lines = strip_comments(probe)
    for number, line in enumerate(lines, 1):
        for api in FILESYSTEM_WRITES:
            if api in line:
                problems.append(
                    f"{PROBE_SOURCE}:{number}: names `{api}`. The probe asks `access(2)` and "
                    f"writes nothing, so it cannot leave a file behind on the device it is "
                    f"probing."
                )


def check_one_artefact_list(repo: str, problems: list[str]) -> None:
    """Rule 7: `Sources/` names jailbreak artefacts in one file.

    A second list is a list that drifts, and the copy that drifts is always the
    one that stops knowing about the current generation of jailbreak.
    """
    root = os.path.join(repo, "Sources")
    if not os.path.isdir(root):
        problems.append("Sources/: not found.")
        return
    for path in swift_files(root):
        relative = os.path.relpath(path, repo)
        if relative == PROBE_SOURCE:
            continue
        with open(path, encoding="utf-8") as handle:
            lines = strip_comments(handle.read())
        for number, line in enumerate(lines, 1):
            for fragment in ARTEFACT_FRAGMENTS:
                if fragment in line:
                    problems.append(
                        f"{relative}:{number}: names the jailbreak artefact `{fragment}`. "
                        f"The list lives in {PROBE_SOURCE} and nowhere else."
                    )


def check_container_applies_it(container: str, problems: list[str]) -> None:
    """Rule 8: the composition root evaluates, reports, and acts.

    Three separate things, each of which can go missing on its own. An
    evaluation nobody reports is invisible; a report nobody acts on is a log
    line; and a mitigation computed and then not applied to the store is the
    one that looks completely finished in review.
    """
    code = code_of(container)
    required = {
        ".mitigations(for: integrity)":
            "the policy is never consulted, so no mitigation is ever computed",
        "report(.evaluated(":
            "the report never reaches the log, so a pass and a run that never happened "
            "look identical",
        "withholdsBiometricUnlockRecord":
            "the mitigation is computed and then not applied",
    }
    for fragment, consequence in required.items():
        if fragment not in code:
            problems.append(
                f"{CONTAINER_SOURCE}: does not contain `{fragment}` — {consequence}."
            )

    for _, statement in statements(strip_comments(container)):
        if not re.search(r"\bTokenStore\(", statement):
            continue
        check_unlock_argument(statement, code, problems)
        return
    problems.append(f"{CONTAINER_SOURCE}: no TokenStore is constructed here any more.")


def check_unlock_argument(statement: str, code: str, problems: list[str]) -> None:
    """Rule 8, the half that catches the regression that looks finished.

    `biometricUnlock: .deviceOwner` compiles, ships, and is what this file said
    before the heuristics existed. It is also what the file would say again after
    a merge resolved the wrong way — so the argument has to be a value the
    integrity report produced, not a policy named in place.
    """
    match = re.search(r"biometricUnlock:\s*([A-Za-z_.][\w.]*)", statement)
    if match is None:
        problems.append(
            f"{CONTAINER_SOURCE}: builds a TokenStore with no biometricUnlock: argument."
        )
        return
    argument = match.group(1)
    if argument.startswith("."):
        problems.append(
            f"{CONTAINER_SOURCE}: builds a TokenStore with a literal "
            f"`biometricUnlock: {argument}`. The policy has to come from the integrity "
            f"report, or the mitigation is computed and then discarded."
        )
        return
    if not re.search(rf"\blet\s+{re.escape(argument)}\s*=\s*[\w.]*{UNLOCK_RESOLVER}\(", code):
        problems.append(
            f"{CONTAINER_SOURCE}: `{argument}` is passed as biometricUnlock: but is not bound "
            f"from {UNLOCK_RESOLVER}(), which is the only thing that reads the integrity "
            f"mitigation."
        )


# MARK: - Entry point


def main() -> int:
    repo = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.dirname(
        os.path.dirname(os.path.abspath(__file__))
    )
    problems: list[str] = []

    signal_source = read(repo, SIGNAL_SOURCE, problems)
    evaluator = read(repo, EVALUATOR_SOURCE, problems)
    probe = read(repo, PROBE_SOURCE, problems)
    policy = read(repo, POLICY_SOURCE, problems)
    container = read(repo, CONTAINER_SOURCE, problems)
    tests = "\n".join(
        source for source in (read(repo, path, problems) for path in TEST_SOURCES)
        if source is not None
    )
    page = read(repo, THREAT_MODEL, problems)

    cases: dict[str, str] = {}
    if signal_source is not None:
        cases = signal_cases(signal_source, problems)

    if cases and evaluator is not None:
        check_every_signal_is_raised(cases, evaluator, problems)
    if cases and page is not None:
        check_every_signal_is_documented(cases, page, problems)
    if cases and tests:
        check_every_signal_is_tested(cases, tests, problems)
    if evaluator is not None:
        check_evaluator_is_pure(evaluator, problems)
    if probe is not None:
        check_probe_writes_nothing(probe, problems)
    if policy is not None:
        check_response_cases(policy, problems)
    if container is not None:
        check_container_applies_it(container, problems)

    check_nothing_terminates(repo, problems)
    check_one_artefact_list(repo, problems)

    if problems:
        print("Device integrity audit failed:\n")
        for problem in problems:
            print(f"  {problem}")
        print(f"\n{len(problems)} problem(s).")
        return 1

    print(f"Device integrity audit passed across {len(cases)} heuristic(s):")
    for name, wire in sorted(cases.items()):
        print(f"  {wire} — raised, documented, tested")
    print("  evaluator: pure; probe: read-only; responses: degrade only")
    return 0


if __name__ == "__main__":
    sys.exit(main())
