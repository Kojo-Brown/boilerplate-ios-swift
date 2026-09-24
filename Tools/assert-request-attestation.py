#!/usr/bin/env python3
"""Fail if a request can leave this app without going past the attestor, or if
an assertion stops saying what it is supposed to say.

Phase 11 item 3. App Attest has the same shape of failure mode as certificate
pinning and it is worse in one respect: pinning that is never reached refuses
nothing, which at least leaves the app working, whereas attestation that is
never reached leaves an app that *looks* attested — the type is wired, the
headers exist, the tests pass — and hands the server assertions that prove less
than it thinks. Three ways that happens, none of which any other gate sees:

  * **A second delivery path.** Every request this app sends goes through
    `send(attesting:)`. Add one more `session.data(for:)` anywhere in the
    transport — a HEAD probe, a multipart upload, the token refresh reverted to
    what it used to be — and that request is simply unattested. Nothing is red.

  * **A retry that copies the headers.** An App Attest assertion increments a
    counter inside the Secure Enclave, and a server doing replay detection
    refuses a counter it has already accepted. The 401 retry therefore has to
    re-attest, not copy; the copying version is shorter, compiles, and passes
    every test written against a server that does not check.

  * **A binding that quietly narrows.** The assertion signs a hash of the
    canonical client data and nothing else. Drop the body digest from that
    string and every signature still verifies — against a statement that no
    longer says anything about the body, which is where the money is.

Each rule below was verified by reintroducing the defect it names and watching
this script fail. It is a script rather than a test for the reason the other
five are: it needs no toolchain, no resolved packages and no simulator, so it
runs on Linux in the lint job, reports even when the build is broken, and is one
of the few gates the scheduled agent can run before pushing.

Run it with `python3 Tools/assert-request-attestation.py [repo-root]`.
"""
from __future__ import annotations

import os
import re
import sys

TRANSPORT_SOURCE = os.path.join("Sources", "Networking", "Transport", "URLSessionAPIClient.swift")
CONTAINER_SOURCE = os.path.join("Sources", "App", "AppContainer.swift")
ATTESTATION_DIR = os.path.join("Sources", "Networking", "Transport", "Attestation")
CLIENT_DATA_SOURCE = os.path.join(ATTESTATION_DIR, "AttestationClientData.swift")
SERVER_SOURCE = os.path.join(ATTESTATION_DIR, "AttestationService.swift")

# The fields the assertion has to be a statement about. Anything missing here is
# a binding that has silently become broader.
BOUND_FIELDS = ("format", "method", "path", "query", "bodyDigest", "challenge")

# A raw header name spelled anywhere but the one file that declares it.
HEADER_LITERAL = re.compile(r'"X-Attest-[A-Za-z-]*"')

# What actually puts bytes on the wire.
WIRE_CALL = re.compile(r"\bsession\s*\.\s*data\s*\(")


# MARK: - Reading Swift with the prose taken out


def strip_noise(line: str, in_block: bool) -> tuple[str, bool]:
    """Blanks comments, keeping the line's length and its string literals.

    String literals survive because the rules below look for header names and
    for `"attest/v1"`, both of which live in one.
    """
    out, index, length = [], 0, len(line)
    while index < length:
        if in_block:
            if line[index:index + 2] == "*/":
                in_block = False
                index += 2
            else:
                index += 1
            continue
        if line[index:index + 2] == "//":
            break
        if line[index:index + 2] == "/*":
            in_block = True
            index += 2
            continue
        if line[index] == '"':
            out.append('"')
            index += 1
            while index < length:
                out.append(line[index])
                if line[index] == "\\" and index + 1 < length:
                    out.append(line[index + 1])
                    index += 2
                    continue
                if line[index] == '"':
                    index += 1
                    break
                index += 1
            continue
        out.append(line[index])
        index += 1
    return "".join(out), in_block


def code_lines(path: str) -> list[str]:
    lines, in_block = [], False
    for raw in read(path).split("\n"):
        code, in_block = strip_noise(raw, in_block)
        lines.append(code)
    return lines


def code(path: str) -> str:
    return "\n".join(code_lines(path))


def read(path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def swift_files(directory: str) -> list[str]:
    found = []
    for root, _, names in os.walk(directory):
        found.extend(os.path.join(root, name) for name in names if name.endswith(".swift"))
    return sorted(found)


# MARK: - Rule 1: the transport cannot default its way out of an attestor


def check_transport_requires_an_attestor(repo: str, problems: list[str]) -> None:
    body = code(os.path.join(repo, TRANSPORT_SOURCE))
    if re.search(r"attestor\s*:\s*any RequestAttesting\s*=", body):
        problems.append(
            f"{TRANSPORT_SOURCE}: the attestor parameter has a default. A caller that omits "
            f"it is a caller sending unattested requests, and the diff shows nothing."
        )
    if not re.search(r"attestor\s*:\s*any RequestAttesting\s*,", body):
        problems.append(
            f"{TRANSPORT_SOURCE}: no required `attestor: any RequestAttesting` parameter found."
        )


# MARK: - Rule 2: one delivery path, and it is the attesting one


def check_one_delivery_path(repo: str, problems: list[str]) -> None:
    path = os.path.join(repo, TRANSPORT_SOURCE)
    hits = [number for number, line in enumerate(code_lines(path), 1) if WIRE_CALL.search(line)]
    if len(hits) != 1:
        where = ", ".join(f"line {number}" for number in hits) or "nowhere"
        problems.append(
            f"{TRANSPORT_SOURCE}: {len(hits)} calls put bytes on the wire ({where}); expected "
            f"exactly one, inside `send(attesting:)`. A second one is a request that skips "
            f"attestation entirely."
        )
    if "func send(attesting request: URLRequest)" not in code(path):
        problems.append(
            f"{TRANSPORT_SOURCE}: `send(attesting:)` is gone. Every delivery, the 401 retry and "
            f"the token refresh included, has to go through one place that attaches the assertion."
        )


# MARK: - Rule 3: the retry re-attests rather than copying


def check_retry_does_not_copy_headers(repo: str, problems: list[str]) -> None:
    body = code(os.path.join(repo, TRANSPORT_SOURCE))
    if "AttestationHeaderField" in body or HEADER_LITERAL.search(body):
        problems.append(
            f"{TRANSPORT_SOURCE}: names an attestation header field. The transport applies a "
            f"`RequestAttestation` and never touches the headers itself — a retry that sets them "
            f"by hand re-sends a spent assertion, which a server doing replay detection refuses."
        )


# MARK: - Rule 4: the header names live in one file


def check_header_names_live_in_one_place(repo: str, problems: list[str]) -> None:
    for directory in ("Sources", "Tests"):
        root = os.path.join(repo, directory)
        if not os.path.isdir(root):
            continue
        for path in swift_files(root):
            relative = os.path.relpath(path, repo)
            if relative == CLIENT_DATA_SOURCE:
                continue
            for number, line in enumerate(code_lines(path), 1):
                if HEADER_LITERAL.search(line):
                    problems.append(
                        f"{relative}:{number}: spells an attestation header out. Go through "
                        f"`AttestationHeaderField`, so the client and the audit agree on one "
                        f"spelling — a header set under one name and read under another looks "
                        f"exactly like attestation that is not switched on yet."
                    )


# MARK: - Rule 5: the assertion is a statement about the whole request


def check_client_data_binds_everything(repo: str, problems: list[str]) -> None:
    body = code(os.path.join(repo, CLIENT_DATA_SOURCE))
    match = re.search(r"var canonicalForm: String \{(.*?)\n    \}", body, re.DOTALL)
    if not match:
        problems.append(f"{CLIENT_DATA_SOURCE}: no `canonicalForm` to audit.")
        return
    canonical = match.group(1)
    for field in BOUND_FIELDS:
        if not re.search(rf"\b{field}\b", canonical):
            problems.append(
                f"{CLIENT_DATA_SOURCE}: `canonicalForm` no longer includes `{field}`. An "
                f"assertion that does not cover it is one an attacker can move to a request "
                f"where it differs."
            )
    if "AttestationClientData.format" not in canonical and "format," not in canonical:
        problems.append(
            f"{CLIENT_DATA_SOURCE}: the version marker is not in the signed bytes. A header "
            f"alone lets an attacker pick which format — and so which fields — is verified."
        )


# MARK: - Rule 6: attestation does not go through the client it attests


def check_attestation_does_not_use_the_client(repo: str, problems: list[str]) -> None:
    body = code(os.path.join(repo, SERVER_SOURCE))
    for name in ("APIClient", "APIEndpoint"):
        if re.search(rf"\b{name}\b", body):
            problems.append(
                f"{SERVER_SOURCE}: names `{name}`. The challenge and the key registration cannot "
                f"go through the client, because the client is what attaches attestation — a "
                f"challenge fetched through it needs a challenge of its own, and so on."
            )


# MARK: - Rule 7: the composition root states the enforcement


def check_container_states_enforcement(repo: str, problems: list[str]) -> None:
    body = code(os.path.join(repo, CONTAINER_SOURCE))
    match = re.search(r"AppAttestor\((.*?)\n        \)", body, re.DOTALL)
    if not match:
        problems.append(
            f"{CONTAINER_SOURCE}: no AppAttestor is constructed here any more, so nothing in "
            f"the app attests anything."
        )
        return
    if "enforcement:" not in match.group(1):
        problems.append(
            f"{CONTAINER_SOURCE}: builds an AppAttestor without naming an AttestationEnforcement. "
            f"Whether a request that cannot be attested is sent anyway is the composition root's "
            f"decision and nobody else's."
        )


# MARK: - Entry point


def main() -> int:
    repo = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.dirname(
        os.path.dirname(os.path.abspath(__file__))
    )
    problems: list[str] = []

    for relative in (TRANSPORT_SOURCE, CONTAINER_SOURCE, CLIENT_DATA_SOURCE, SERVER_SOURCE):
        if not os.path.isfile(os.path.join(repo, relative)):
            print(f"Request attestation audit failed:\n\n  {relative}: not found.")
            return 1

    check_transport_requires_an_attestor(repo, problems)
    check_one_delivery_path(repo, problems)
    check_retry_does_not_copy_headers(repo, problems)
    check_header_names_live_in_one_place(repo, problems)
    check_client_data_binds_everything(repo, problems)
    check_attestation_does_not_use_the_client(repo, problems)
    check_container_states_enforcement(repo, problems)

    if problems:
        print("Request attestation audit failed:\n")
        for problem in problems:
            print(f"  {problem}")
        print(f"\n{len(problems)} problem(s).")
        return 1

    print("Request attestation audit passed.")
    print("  one delivery path, re-attested on retry, bound to method/path/query/body/challenge")
    return 0


if __name__ == "__main__":
    sys.exit(main())
