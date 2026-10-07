#!/usr/bin/env python3
"""Fail if the crash and hang reporting pipeline loses its guarantees.

Phase 11 item 7. MetricKit is a feature whose defects are invisible to every
other gate in this repository, for one structural reason: **no part of it can be
driven by a test.** `MXDiagnosticPayload`, `MXCrashDiagnostic`, `MXHangDiagnostic`,
`MXCallStackTree` and `MXMetaData` all have no public initialiser, and the
framework delivers payloads on a device, once a day, for the day before. So the
suite can exercise everything from `CrashReport` outward and nothing at all on
the far side of the projection — and the properties that decide whether this
pipeline works are not all on the testable side.

Worse, each of them fails *silently and in the same direction*: no crash reports.
Which is indistinguishable from an app nobody has crashed.

The four defects this exists to catch, each verified by reintroducing it:

  * **The write becomes asynchronous.** `MXMetricManagerSubscriber.didReceive` is
    the only delivery there will ever be for those payloads — no acknowledgement,
    no re-delivery, no way to ask again. Rewriting the callback as
    `Task { await pipeline.accept(...) }` compiles, passes every test, and loses a
    payload on any launch the system cuts short. Launch is when MetricKit
    delivers; launch is also when an app is most likely to be killed.

  * **A field that was deliberately dropped comes back.** `MXFrame.address` is a
    pointer into a process that no longer exists, `virtualMemoryRegionInfo` is a
    memory-map dump, `MXMetaData.regionFormat` is the user's region. Adding any of
    them is one line, it is invisible in a diff that is already about crash
    reporting, and the result is a privacy manifest that has quietly become
    untrue.

  * **MetricKit spreads.** Importing it anywhere else is how the untestable
    surface grows: a second file with `import MetricKit` is a second file nothing
    can exercise, and the seam stops being a seam.

  * **The uploader stops going through the app's transport.** A crash endpoint
    with a `URLSession` of its own is unpinned and unattested — the one request in
    the app an attacker in the middle could answer — and it looks identical in
    review to one that is not.

It also fails if `docs/crash-reporting.md` stops documenting what cannot be
tested here, because that page is the only record of it.

It is deliberately a script rather than a test: it needs no toolchain, no
resolved packages and no simulator, so it runs on Linux in the lint job, reports
even when the build is broken, and is one of the few gates the scheduled agent
can run before pushing.

Run it with `python3 Tools/assert-crash-reporting.py [repo-root]`.
"""
from __future__ import annotations

import os
import re
import sys

# MARK: - The files

CORE_DIR = os.path.join("Sources", "Core", "Diagnostics", "CrashReporting")
SUBSCRIBER = os.path.join(CORE_DIR, "MetricKitDiagnosticSubscriber.swift")
SPOOL = os.path.join(CORE_DIR, "CrashReportSpool.swift")
PIPELINE = os.path.join(CORE_DIR, "CrashReportPipeline.swift")
REPORT = os.path.join(CORE_DIR, "CrashReport.swift")
UPLOADER = os.path.join("Sources", "Networking", "Diagnostics", "APICrashReportUploader.swift")
CONTAINER = os.path.join("Sources", "App", "AppContainer.swift")
APP = os.path.join("Sources", "App", "BoilerplateApp.swift")
DOCS = os.path.join("docs", "crash-reporting.md")

REQUIRED = (SUBSCRIBER, SPOOL, PIPELINE, REPORT, UPLOADER, CONTAINER, APP, DOCS)

# MARK: - What must not come back
#
# Each of these is a field MetricKit offers, that the projection deliberately does
# not read, and whose return would make the privacy manifest untrue. Spelled with
# word boundaries so the paragraph in `StackFrame` explaining why `address` is
# dropped does not count as a use of it — comments are stripped before matching
# anyway, which is the belt to that braces.
DROPPED_FIELDS = {
    r"\.address\b": (
        "MXFrame.address is a load address in a process that no longer exists, so "
        "it symbolicates nothing without the ASLR slide — and it is a pointer out "
        "of somebody's address space."
    ),
    r"\bvirtualMemoryRegionInfo\b": (
        "virtualMemoryRegionInfo is a dump of the process's memory map and the "
        "largest field in a crash diagnostic."
    ),
    r"\bregionFormat\b": (
        "MXMetaData.regionFormat is the user's region. No crash has ever been "
        "fixed by knowing it."
    ),
    r"\bjsonRepresentation\s*\(": (
        "jsonRepresentation() hands over MetricKit's whole document, dropped "
        "fields included. The projection exists so that what leaves the device is "
        "chosen field by field."
    ),
    r"\bdictionaryRepresentation\s*\(": (
        "dictionaryRepresentation() is jsonRepresentation() in another costume."
    ),
}

# The marker that says a report's durability is synchronous.
SYNCHRONOUS_ACCEPT = re.compile(r"nonisolated\s+func\s+accept\s*\(")
ASYNC_ACCEPT = re.compile(r"func\s+accept\s*\([^)]*\)\s*async")

# A `Task` or a `Thread` between MetricKit's callback and the spool.
DEFERRED_WRITE = re.compile(r"Task\s*(?:\.detached)?\s*\{[^}]*accept\s*\(", re.DOTALL)


# MARK: - Reading Swift with the prose taken out


def read(path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def strip_comments(source: str) -> str:
    """Blanks `//` and `/* */`, keeping string literals and the line count.

    This repository documents its decisions at length and in prose, so a scanner
    that reads comments is a scanner that fails the paragraph explaining the rule
    it enforces. Newlines are preserved so a reported line number is the real one.
    """
    out: list[str] = []
    index, length, depth = 0, len(source), 0
    state = "code"

    while index < length:
        char = source[index]
        ahead2 = source[index:index + 2]
        ahead3 = source[index:index + 3]

        if state == "code":
            if ahead3 == '"""':
                state, index = "multiline", index + 3
                out.append(ahead3)
            elif char == '"':
                state, index = "string", index + 1
                out.append(char)
            elif ahead2 == "//":
                state, index = "line", index + 2
            elif ahead2 == "/*":
                state, depth, index = "block", 1, index + 2
            else:
                out.append(char)
                index += 1
            continue

        if state == "string":
            out.append(char)
            if char == "\\" and index + 1 < length:
                out.append(source[index + 1])
                index += 2
                continue
            if char in '"\n':
                state = "code"
            index += 1
            continue

        if state == "multiline":
            if ahead3 == '"""':
                state, index = "code", index + 3
                out.append(ahead3)
                continue
            out.append(char)
            index += 1
            continue

        if state == "line":
            if char == "\n":
                state = "code"
                out.append(char)
            index += 1
            continue

        # block
        if ahead2 == "/*":
            depth += 1
            index += 2
        elif ahead2 == "*/":
            depth -= 1
            index += 2
            if depth == 0:
                state = "code"
        else:
            if char == "\n":
                out.append(char)
            index += 1
    return "".join(out)


def code(repo: str, relative: str) -> str:
    return strip_comments(read(os.path.join(repo, relative)))


def swift_files(directory: str) -> list[str]:
    found: list[str] = []
    for root, _, names in os.walk(directory):
        found.extend(os.path.join(root, name) for name in names if name.endswith(".swift"))
    return sorted(found)


# MARK: - Rule 1: the ingest write is synchronous


def check_accept_is_synchronous(repo: str, problems: list[str]) -> None:
    """The one property the whole feature rests on.

    `accept` has to be callable, and complete, from inside a synchronous system
    callback. An `async` version of it makes `Task { ... }` the natural spelling at
    the call site, which returns before the write.
    """
    body = code(repo, PIPELINE)
    if ASYNC_ACCEPT.search(body):
        problems.append(
            f"{PIPELINE}: `accept` is async. MetricKit delivers a payload once, with no "
            f"acknowledgement and no re-delivery, so the spool write has to have happened by "
            f"the time its callback returns — see CrashReportSpooling."
        )
    if not SYNCHRONOUS_ACCEPT.search(body):
        problems.append(
            f"{PIPELINE}: no `nonisolated func accept(` found. The ingest path has to be "
            f"reachable synchronously from a nonisolated callback."
        )
    if "private var draining" not in body:
        problems.append(
            f"{PIPELINE}: the drain's reentrancy flag is gone. An actor releases its executor "
            f"at every await, so two drains interleave at the first upload, read the same spool, "
            f"and send every report twice."
        )


def check_spool_protocol_is_synchronous(repo: str, problems: list[str]) -> None:
    """Rule 2: the spool's requirements cannot become `async` either.

    Checked on the protocol as well as the pipeline, because the protocol is what
    a new implementation is written against: an `async` requirement would make
    every conformance asynchronous and the pipeline's synchronous `accept`
    impossible, one file away from where the guarantee is documented.
    """
    body = code(repo, SPOOL)
    for requirement in ("store", "stored", "discard"):
        if re.search(rf"func\s+{requirement}\s*\([^)]*\)[^\n]*\basync\b", body):
            problems.append(
                f"{SPOOL}: `{requirement}` is async. The spool is the durability guarantee and "
                f"it has to be reachable from a synchronous callback."
            )
    if "func store(_ report: CrashReport) throws" not in body:
        problems.append(
            f"{SPOOL}: no synchronous throwing `store(_:)`. That signature *is* the contract: "
            f"when it returns, the report is on disk."
        )


# MARK: - Rule 3: the fields that were dropped stay dropped


def check_dropped_fields(repo: str, problems: list[str]) -> None:
    for relative in (SUBSCRIBER, REPORT):
        body = code(repo, relative)
        for pattern, why in DROPPED_FIELDS.items():
            if re.search(pattern, body):
                problems.append(
                    f"{relative}: reads {pattern.strip(chr(92) + 'b()')}. {why} It is declared "
                    f"nowhere in the privacy manifests, so reading it makes them untrue."
                )


# MARK: - Rule 4: MetricKit stays behind one file


def check_metrickit_is_contained(repo: str, problems: list[str]) -> None:
    for directory in ("Sources", "Tests"):
        root = os.path.join(repo, directory)
        if not os.path.isdir(root):
            continue
        for path in swift_files(root):
            relative = os.path.relpath(path, repo)
            if relative == SUBSCRIBER:
                continue
            if re.search(r"^\s*import\s+MetricKit\b", strip_comments(read(path)), re.M):
                problems.append(
                    f"{relative}: imports MetricKit. Nothing MetricKit hands over can be "
                    f"constructed by a test, so every file that imports it is a file the suite "
                    f"cannot reach. It belongs in {SUBSCRIBER} and nowhere else."
                )


# MARK: - Rule 5: the projection holds no policy


def check_projection_holds_no_policy(repo: str, problems: list[str]) -> None:
    """The untestable file must not be the one deciding anything.

    Its bounds come from `CrashReportLimits`, its durability from the spool, its
    retry classification from the uploader. A literal bound here is a decision no
    test can reach.
    """
    body = code(repo, SUBSCRIBER)
    for bound in (
        "maxStacksPerReport",
        "maxFramesPerStack",
        "maxFrameDepth",
    ):
        if f"limits.{bound}" not in body:
            problems.append(
                f"{SUBSCRIBER}: does not apply `limits.{bound}`. Nothing MetricKit hands over is "
                f"bounded by anything this app controls, and a bound written as a literal here is "
                f"a bound no test can reach."
            )
    # The cap on the one free-form string is checked by name rather than by its
    # limit, because the way that cap breaks is a comparison against the wrong
    # number — which still mentions the limit. `CrashReportLimits.truncating` is
    # where it lives so that a test can hold it instead.
    if "limits.truncating(terminationReason:" not in body:
        problems.append(
            f"{SUBSCRIBER}: does not cap the termination reason through "
            f"`CrashReportLimits.truncating(terminationReason:)`. It is the one free-form string "
            f"that leaves the device, and a cap applied here is a cap no test can reach."
        )

    for forbidden, why in (
        (r"\bURLSession\b", "a session here would be an unpinned, unattested request"),
        (r"\bFileManager\b", "durability belongs to the spool, which is testable"),
        (r"\bAPIEndpoint\b", "nothing in Core may name the transport"),
    ):
        if re.search(forbidden, body):
            problems.append(f"{SUBSCRIBER}: names {forbidden}, and {why}.")


# MARK: - Rule 6: the upload goes through the app's transport


def check_uploader_uses_the_app_transport(repo: str, problems: list[str]) -> None:
    body = code(repo, UPLOADER)
    if "any APIClient" not in body:
        problems.append(
            f"{UPLOADER}: does not take an `any APIClient`. Going through the app's transport is "
            f"what makes the upload pinned, attested and keyed; a session of its own would be "
            f"the one request in the app an attacker in the middle could answer."
        )
    if re.search(r"\bURLSession\b", body):
        problems.append(
            f"{UPLOADER}: names URLSession. See Tools/assert-pinned-sessions.py — this request "
            f"goes over the app's pinned session or not at all."
        )
    if "requiresAuth: false" not in body:
        problems.append(
            f"{UPLOADER}: the report is not posted with `requiresAuth: false`. A crash can happen "
            f"before sign-in, during a sign-out, or with a revoked token, and those are the "
            f"launches most worth hearing about."
        )
    if "idempotencyKey:" not in body:
        problems.append(
            f"{UPLOADER}: the upload carries no idempotency key. It is retried across process "
            f"launches, and the failure that usually causes the retry — a lost response — is "
            f"indistinguishable from a report that never arrived."
        )
    if "IdempotencyKey(rawValue: report.digest)" not in body:
        problems.append(
            f"{UPLOADER}: the key is not the report's digest. A freshly minted key per attempt "
            f"costs a header and buys nothing, while reading as though duplicates were handled."
        )


# MARK: - Rule 7: the subscriber is registered and retained


def check_subscriber_is_retained(repo: str, problems: list[str]) -> None:
    """`MXMetricManager.add(_:)` does not retain its subscriber.

    One created and dropped in the same expression registers, deallocates, and is
    then indistinguishable at runtime from a device that has never crashed.
    """
    container = code(repo, CONTAINER)
    app = code(repo, APP)
    if "makeCrashReportSubscriber" not in container:
        problems.append(
            f"{CONTAINER}: no `makeCrashReportSubscriber()`. The composition root is where the "
            f"app decides that it reports its own crashes."
        )
    if "crashReporting" not in container:
        problems.append(f"{CONTAINER}: the container no longer holds a CrashReportPipeline.")
    if not re.search(r"let\s+crashReports:\s*MetricKitDiagnosticSubscriber", app):
        problems.append(
            f"{APP}: the subscriber is not held in a stored property. MXMetricManager does not "
            f"retain it, so one that is not held registers and is then deallocated — which looks "
            f"exactly like an app nobody has crashed."
        )
    if ".start()" not in app:
        problems.append(f"{APP}: nothing calls `start()`, so nothing is subscribed to MetricKit.")


# MARK: - Rule 8: the callback writes before it defers


def check_callback_writes_before_it_defers(repo: str, problems: list[str]) -> None:
    body = code(repo, SUBSCRIBER)
    match = re.search(r"func didReceive\(_ payloads: \[MXDiagnosticPayload\]\)[^{]*\{(.*?)\n    \}",
                      body, re.DOTALL)
    if not match:
        problems.append(
            f"{SUBSCRIBER}: no `didReceive(_:[MXDiagnosticPayload])`. Without it the app is "
            f"subscribed to MetricKit and throwing away everything it delivers."
        )
        return
    callback = match.group(1)
    if DEFERRED_WRITE.search(callback):
        problems.append(
            f"{SUBSCRIBER}: the spool write is inside a Task. That returns before the write, and "
            f"this callback is the only delivery those payloads will ever have."
        )
        return
    accept_at = callback.find("accept(")
    task_at = callback.find("Task")
    if accept_at < 0:
        problems.append(f"{SUBSCRIBER}: the callback never calls `accept(`, so nothing is spooled.")
        return
    if 0 <= task_at < accept_at:
        problems.append(
            f"{SUBSCRIBER}: a Task is started before the reports are spooled. The durable write "
            f"comes first; the upload is what is allowed to be late."
        )


# MARK: - Rule 9: the page keeps its gaps


def check_docs(repo: str, problems: list[str]) -> None:
    page = read(os.path.join(repo, DOCS))
    for term in ("MXDiagnosticPayload", "Idempotency", "spool"):
        if term not in page:
            problems.append(f"{DOCS}: does not mention {term}.")
    if not re.search(r"^#+\s*.*(limitation|not done|what is not|gap)", page, re.I | re.M):
        problems.append(
            f"{DOCS}: no limitations section. The projection is the one part of this feature "
            f"nothing here can execute, and this page is the only record of that."
        )


# MARK: - Entry point


def main() -> int:
    repo = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.dirname(
        os.path.dirname(os.path.abspath(__file__))
    )
    for relative in REQUIRED:
        if not os.path.isfile(os.path.join(repo, relative)):
            print(f"Crash reporting audit failed:\n\n  {relative}: not found.")
            return 1

    problems: list[str] = []
    check_accept_is_synchronous(repo, problems)
    check_spool_protocol_is_synchronous(repo, problems)
    check_dropped_fields(repo, problems)
    check_metrickit_is_contained(repo, problems)
    check_projection_holds_no_policy(repo, problems)
    check_uploader_uses_the_app_transport(repo, problems)
    check_subscriber_is_retained(repo, problems)
    check_callback_writes_before_it_defers(repo, problems)
    check_docs(repo, problems)

    if problems:
        print("Crash reporting audit failed:\n")
        for problem in problems:
            print(f"  {problem}")
        print(f"\n{len(problems)} problem(s).")
        return 1

    print("Crash reporting audit passed.")
    print("  synchronous spool, one MetricKit file, dropped fields still dropped,")
    print("  upload pinned and keyed by digest, subscriber retained")
    return 0


if __name__ == "__main__":
    sys.exit(main())
