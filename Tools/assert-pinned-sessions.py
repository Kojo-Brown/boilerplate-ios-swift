#!/usr/bin/env python3
"""Fail if anything in this app can reach the network on an unpinned session.

Phase 11 item 2. Certificate pinning has a failure mode no other gate in this
repository can see, and it is not "the pins are wrong" — it is "the pins are
never consulted":

  * **An unpinned session is not broken.** `URLSession.shared` resolves,
    connects, validates the chain against the system's anchors and returns the
    right bytes. It does that on every device, in every test, in every review.
    The only thing it does not do is refuse the one connection pinning was
    added to refuse, and that connection does not happen on anybody's desk. A
    session built without the delegate is therefore indistinguishable from one
    built with it, everywhere except in the incident.

  * **`URLSession.shared` cannot be pinned at all.** It takes no delegate.
    There is no way to add pinning to it later, no warning when it is used, and
    it is three characters shorter than the alternative — which is the entire
    story of how transport code ends up unpinned.

  * **The inverted check passes its own tests.** A delegate that matches a pin
    and returns `.useCredential` without first evaluating the chain has
    replaced the device's trust store with a list of two hashes: an expired
    certificate, a revoked one, or one issued for a different hostname is then
    accepted as long as the key matches. It is the most common way pinning is
    implemented wrongly, it is a two-line difference, and every happy-path test
    of it passes.

So this checks the three structural facts that make pinning unavoidable rather
than merely available: one place builds sessions, nothing reaches for the
shared one, and the transport cannot be constructed without being told which
session it is on.

Each rule below was verified by reintroducing the defect it names and watching
this script fail. It is deliberately a script rather than a test: it needs no
toolchain, no resolved packages and no simulator, so it runs on Linux in the
lint job, reports even when the build is broken, and is one of the few gates
the scheduled agent can run before pushing.

Run it with `python3 Tools/assert-pinned-sessions.py [repo-root]`.
"""
from __future__ import annotations

import os
import re
import sys

# MARK: - The one place a session may be built

# `URLSession(configuration:delegate:delegateQueue:)` is the only initialiser
# that can carry a pinning delegate, and this is the only file allowed to call
# it. Everything else asks this file for a session.
SESSION_FACTORY = os.path.join("Sources", "Networking", "Transport", "Pinning", "PinnedURLSession.swift")

# Where the transport lives, and where the composition root wires it up.
TRANSPORT_SOURCE = os.path.join("Sources", "Networking", "Transport", "URLSessionAPIClient.swift")
CONTAINER_SOURCE = os.path.join("Sources", "App", "AppContainer.swift")
DELEGATE_SOURCE = os.path.join("Sources", "Networking", "Transport", "Pinning", "CertificatePinningDelegate.swift")

# A `URLSession(...)` construction. Not `URLSessionConfiguration(`,
# `URLSessionAPIClient(` or `URLSessionDelegate` — hence the negative lookahead
# on anything that continues the identifier.
CONSTRUCTION = re.compile(r"\bURLSession\s*\(")

# The shared session, which takes no delegate and therefore cannot be pinned.
SHARED = re.compile(r"\bURLSession\s*\.\s*shared\b|\bsession\s*:\s*\.shared\b")


def strip_noise(line: str, in_block: bool) -> tuple[str, bool]:
    """Drop comments and string literals so a mention in prose is not a use."""
    out: list[str] = []
    index, length = 0, len(line)
    while index < length:
        if in_block:
            end = line.find("*/", index)
            if end == -1:
                return "".join(out), True
            in_block = False
            index = end + 2
            continue
        char = line[index]
        if char == "/" and index + 1 < length and line[index + 1] == "/":
            break
        if char == "/" and index + 1 < length and line[index + 1] == "*":
            in_block = True
            index += 2
            continue
        if char == '"':
            index += 1
            while index < length:
                if line[index] == "\\":
                    index += 2
                    continue
                if line[index] == '"':
                    index += 1
                    break
                index += 1
            out.append('""')
            continue
        out.append(char)
        index += 1
    return "".join(out), in_block


def code_lines(path: str) -> list[str]:
    lines, in_block = [], False
    for raw in open(path, encoding="utf-8").read().split("\n"):
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


def read(path: str) -> str:
    return open(path, encoding="utf-8").read()


# MARK: - Rule 1: one place builds sessions, and nobody reaches for the shared one


def check_session_construction(repo: str, problems: list[str]) -> int:
    scanned = 0
    for path in swift_files(os.path.join(repo, "Sources")):
        relative = os.path.relpath(path, repo)
        scanned += 1
        for number, code in enumerate(code_lines(path), 1):
            if CONSTRUCTION.search(code) and relative != SESSION_FACTORY:
                problems.append(
                    f"{relative}:{number}: builds a URLSession directly. "
                    f"Ask {SESSION_FACTORY} for a pinned one instead."
                )
            if SHARED.search(code):
                problems.append(
                    f"{relative}:{number}: uses URLSession.shared, which takes no delegate "
                    f"and therefore cannot be pinned."
                )
    return scanned


# MARK: - Rule 2: the transport cannot default its way out of a session


def check_transport_has_no_session_default(repo: str, problems: list[str]) -> None:
    path = os.path.join(repo, TRANSPORT_SOURCE)
    if not os.path.isfile(path):
        problems.append(f"{TRANSPORT_SOURCE}: not found.")
        return
    body = "\n".join(code_lines(path))
    if re.search(r"session\s*:\s*URLSession\s*=", body):
        problems.append(
            f"{TRANSPORT_SOURCE}: the session parameter has a default again. "
            f"A caller that omits it is a caller with no pinning."
        )
    if not re.search(r"session\s*:\s*URLSession\s*,", body):
        problems.append(
            f"{TRANSPORT_SOURCE}: no required `session: URLSession` parameter found."
        )


# MARK: - Rule 3: the composition root actually asks for a pinned session


def check_container_pins(repo: str, problems: list[str]) -> None:
    path = os.path.join(repo, CONTAINER_SOURCE)
    if not os.path.isfile(path):
        problems.append(f"{CONTAINER_SOURCE}: not found.")
        return
    body = "\n".join(code_lines(path))
    if "URLSession.pinned(" not in body:
        problems.append(
            f"{CONTAINER_SOURCE}: the live graph does not build a pinned session. "
            f"Every request this app makes goes through the one built here."
        )
    if "defaultPinningPolicy" not in body:
        problems.append(f"{CONTAINER_SOURCE}: no pinning policy is declared for the live graph.")


# MARK: - Rule 4: the chain is evaluated before its pins are trusted


def check_trust_is_evaluated_first(repo: str, problems: list[str]) -> None:
    path = os.path.join(repo, DELEGATE_SOURCE)
    if not os.path.isfile(path):
        problems.append(f"{DELEGATE_SOURCE}: not found.")
        return
    body = "\n".join(code_lines(path))
    trusted = body.find("evaluation.isTrusted")
    matched = body.find("return .pinned")
    if trusted == -1:
        problems.append(
            f"{DELEGATE_SOURCE}: nothing checks the system's own trust evaluation. "
            f"Pinning narrows what the system accepts; it never replaces it."
        )
    elif matched != -1 and trusted > matched:
        problems.append(
            f"{DELEGATE_SOURCE}: a pin match is accepted before the chain is evaluated. "
            f"That accepts an expired, revoked or wrong-hostname certificate carrying a pinned key."
        )


def main() -> int:
    repo = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    problems: list[str] = []

    sources = os.path.join(repo, "Sources")
    if not os.path.isdir(sources):
        print(f"Pinned-session audit failed:\n\n  Sources/: not found under {repo}.")
        return 1

    scanned = check_session_construction(repo, problems)
    check_transport_has_no_session_default(repo, problems)
    check_container_pins(repo, problems)
    check_trust_is_evaluated_first(repo, problems)

    if problems:
        print("Pinned-session audit failed:\n")
        for problem in problems:
            print(f"  {problem}")
        print(f"\n{len(problems)} problem(s) across {scanned} source files.")
        return 1

    print(f"Pinned-session audit passed across {scanned} source files.")
    print(f"  sessions: built only in {SESSION_FACTORY}, never URLSession.shared")
    print("  transport: no session default, so no caller can silently opt out of pinning")
    print("  delegate: the system's trust evaluation runs before any pin is accepted")
    return 0


if __name__ == "__main__":
    sys.exit(main())
