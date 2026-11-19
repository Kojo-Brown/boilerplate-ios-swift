#!/usr/bin/env python3
"""Fail if a protocol fake and the thing it replaces can drift apart unnoticed.

Phase 12 item 5 gave the network and persistence seams a differential contract
suite: one table of scenarios, run against the live implementation and against
the hand-written double, asserting the same outcomes of both. That suite is only
worth the lines it occupies for as long as three things stay true, and all three
are a one-line edit away from being false in a way no build and no test reports.

  * **A new conformer nobody decided the contract for.** Adding a third
    `APIClient` — a second double for one feature's tests, a recording
    decorator, a client that talks to a different host — compiles, and the
    contract suite goes on testing the two it knows about. The new type is then
    substituted for the transport in tests with nothing saying it behaves like
    it. Every conformer of an audited protocol must be named in `REGISTRY`
    below, as live, as a double, or as a decorator, with a reason.

  * **A stale entry.** The mirror image: a double that was deleted or renamed
    leaves its row behind, and the row is then a claim about a type that does
    not exist. An allowlist nobody prunes is a rubber stamp.

  * **A double that is no longer under contract.** The suite can be renamed,
    emptied, or have the double's name removed from it, and the remaining tests
    still pass. So each double names the suite that covers it, and the suite has
    to exist, hold at least one `@Test`, and mention the double by name.

It also checks the one structural fact the network contract rests on. The
status-to-outcome mapping used to live inside `URLSessionAPIClient` as a
`switch` on `statusCode`; it now lives in `APIResponseValidation`, and
`MockAPIClient.script(_:)` answers by calling it. That is what makes the
double's agreement with the transport structural rather than coincidental — so
both files have to go on referring to it, and the `200...299` boundary has to
stay in exactly one place. Re-inlining the switch into the transport would leave
the contract suite green (both halves would still agree, because the double
calls the shared copy) while the transport quietly stopped using it.

None of this is visible in a green CI run, which is the only reason this script
exists. It is syntactic, so it needs no toolchain, no resolved packages and no
simulator: it runs on Linux in the audits job, and it is one of the few gates
the scheduled agent can run locally before pushing.

The audited set is the two seams Phase 12 item 5 covers — `APIClient` and
`UserPersistenceService`. It is a registry rather than a sweep of every
`Mock*`/`Stub*`/`InMemory*` type in the package on purpose: the package has
twenty-odd doubles, most of them standing in for a service with no second
implementation to be differential against (there is no live `BarcodeScanning`
to compare `MockBarcodeScannerService` to off a device). Adding a seam here
means writing its contract suite first; `docs/test-doubles.md` says what that
takes.

Usage:  python3 Tools/assert-test-doubles.py [repo-root]
Exit:   0 when every audited double is registered and under contract, 1 otherwise.
"""
from __future__ import annotations

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# MARK: - The registry

SOURCES = "Sources"

# Where each contract suite lives, relative to the repo root.
NETWORK_SUITE = os.path.join("Tests", "ViewModelTests", "NetworkDoubleContractTests.swift")
PERSISTENCE_SUITE = os.path.join("Tests", "ViewModelTests", "PersistenceDoubleContractTests.swift")

# role -> what the role means, for the failure message.
ROLES = {
    "live": "the implementation the app ships",
    "double": "a hand-written stand-in used by tests and previews",
    "decorator": "wraps another conformer and adds a policy; not a stand-in",
}

# protocol -> {type name -> (role, declaring file, contract suite or None, reason)}
#
# `suite` is required for a `double` and must be None for anything else: a live
# implementation is not under contract *to* anything, it is what the contract
# describes.
REGISTRY: dict[str, dict[str, tuple[str, str, str | None, str]]] = {
    "APIClient": {
        "URLSessionAPIClient": (
            "live",
            os.path.join(SOURCES, "Networking", "Transport", "URLSessionAPIClient.swift"),
            None,
            "The transport. Owns the request building, the 401 refresh-and-retry, "
            "and the pinned session.",
        ),
        "MockAPIClient": (
            "double",
            os.path.join(SOURCES, "Networking", "Transport", "APIClient.swift"),
            NETWORK_SUITE,
            "Armed either with a handler returning outcomes, or with `script(_:)` "
            "taking status codes and bodies. The scripted half is the one under "
            "contract; see docs/test-doubles.md for which to reach for.",
        ),
    },
    "UserPersistenceService": {
        "SwiftDataUserPersistenceService": (
            "live",
            os.path.join(SOURCES, "Core", "Persistence", "UserPersistenceService.swift"),
            None,
            "SwiftData over a ModelContext, @MainActor because ModelContext is not Sendable.",
        ),
        "MockUserPersistenceService": (
            "double",
            os.path.join(SOURCES, "Core", "Persistence", "UserPersistenceService.swift"),
            PERSISTENCE_SUITE,
            "Dictionary-backed, with the confirmation stamps kept beside the rows "
            "so that staleness questions have the same answer as on the store.",
        ),
    },
}

# MARK: - The shared-mapping claim

SHARED_MAPPING = "APIResponseValidation"

MAPPING_SOURCE = os.path.join(SOURCES, "Networking", "Transport", "APIResponseValidation.swift")

# Both of these must go on calling the shared mapping rather than spelling the
# switch out again.
MAPPING_CALLERS = (
    os.path.join(SOURCES, "Networking", "Transport", "URLSessionAPIClient.swift"),
    os.path.join(SOURCES, "Networking", "Transport", "APIClient.swift"),
)

# The success range, which is the mapping's one magic literal. It belongs in the
# shared file, and specifically not in either of the two files that are supposed
# to be *calling* the shared file.
#
# The claim is deliberately that narrow. `AttestationService` also spells
# `200...299`, and that is not a duplicate of this mapping: it is a different
# client, against a different endpoint, throwing a different error vocabulary
# (`AttestationError.keyRejected`, not `APIError`). Folding it in here would
# make it throw the wrong errors. What must never come back is the copy that
# used to be inside `URLSessionAPIClient`, because the double would then agree
# with a mapping the transport had stopped using.
SUCCESS_RANGE = "200...299"

# MARK: - Scanning

DECLARATION = re.compile(
    r"^\s*(?:package\s+|public\s+|internal\s+|private\s+|fileprivate\s+)?"
    r"(?:final\s+)?(?:class|struct|actor|enum)\s+([A-Za-z_][A-Za-z0-9_]*)\s*"
    r"(?:<[^>]*>)?\s*:\s*([^{]+)\{"
)

TEST_ATTRIBUTE = re.compile(r"@Test\b")


def swift_files(root: str) -> list[str]:
    found = []
    for dirpath, _, names in os.walk(root):
        for name in names:
            if name.endswith(".swift"):
                found.append(os.path.join(dirpath, name))
    return sorted(found)


def conformers(repo: str, protocol: str) -> dict[str, str]:
    """Type name -> repo-relative file, for every type declaring `protocol`.

    The inheritance clause is split on commas so that `: Foo, APIClient` is
    found and `: APIClientRecorder` is not. Generic parameter lists are dropped
    by the pattern; a `where` clause is not, so it is stripped here.
    """
    found: dict[str, str] = {}
    for path in swift_files(os.path.join(repo, SOURCES)):
        relative = os.path.relpath(path, repo)
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                match = DECLARATION.match(line)
                if not match:
                    continue
                name, clause = match.group(1), match.group(2)
                clause = clause.split(" where ")[0]
                inherited = {part.strip() for part in clause.split(",")}
                if protocol in inherited:
                    found[name] = relative
    return found


# MARK: - The checks


def check_registry_against_tree(repo: str) -> list[str]:
    problems: list[str] = []

    for protocol, entries in REGISTRY.items():
        for name, (role, _, suite, _) in entries.items():
            if role not in ROLES:
                problems.append(
                    f"{protocol}: {name} is registered with the unknown role {role!r}; "
                    f"expected one of {', '.join(sorted(ROLES))}."
                )
            if role == "double" and suite is None:
                problems.append(
                    f"{protocol}: the double {name} names no contract suite. A double "
                    f"nothing holds to the live implementation is the thing this gate exists to catch."
                )
            if role != "double" and suite is not None:
                problems.append(
                    f"{protocol}: {name} is registered as {role} but names a contract suite. "
                    f"A contract describes the live implementation; only a double is held to it."
                )

        found = conformers(repo, protocol)

        if not found:
            problems.append(
                f"{protocol}: no type under {SOURCES}/ declares this protocol. Either the "
                f"protocol was renamed, in which case rename it here too, or the seam is gone "
                f"and its row belongs in neither this registry nor its contract suite."
            )
            continue

        for name, relative in sorted(found.items()):
            if name not in entries:
                problems.append(
                    f"{protocol}: {name} ({relative}) conforms to an audited protocol and is not "
                    f"in REGISTRY. Add it with its role — "
                    f"{'; '.join(f'{key} ({value})' for key, value in sorted(ROLES.items()))} — "
                    f"and, if it is a double, the contract suite that holds it to "
                    f"the live implementation."
                )
                continue
            declared = entries[name][1]
            if os.path.normpath(declared) != os.path.normpath(relative):
                problems.append(
                    f"{protocol}: {name} is registered as living in {declared} but was found in "
                    f"{relative}. Update the registry."
                )

        for name in sorted(entries):
            if name not in found:
                problems.append(
                    f"{protocol}: {name} is in REGISTRY but no type under {SOURCES}/ declares "
                    f"{protocol} under that name. A row describing a type that is gone is a "
                    f"rubber stamp — delete it, or correct the name it was renamed to."
                )

    return problems


def check_doubles_are_under_contract(repo: str) -> list[str]:
    problems: list[str] = []

    for protocol, entries in REGISTRY.items():
        for name, (role, _, suite, _) in sorted(entries.items()):
            if role != "double" or suite is None:
                continue

            path = os.path.join(repo, suite)
            if not os.path.isfile(path):
                problems.append(
                    f"{protocol}: the double {name} names {suite} as its contract suite, and "
                    f"that file does not exist."
                )
                continue

            with open(path, encoding="utf-8") as handle:
                body = handle.read()

            if not TEST_ATTRIBUTE.search(body):
                problems.append(
                    f"{suite} holds no @Test. It is registered as the contract suite for "
                    f"{name}, so an empty one is a double with nothing holding it to anything."
                )
            # A whole-identifier match. A substring one passes on
            # `MockUserPersistenceServiceRenamed`, which is exactly the rename
            # this check is supposed to notice.
            if not re.search(rf"\b{re.escape(name)}\b", body):
                problems.append(
                    f"{suite} never mentions {name}, which is registered as the double it holds "
                    f"to the live implementation. Either the suite stopped exercising the "
                    f"double, or the registry points at the wrong file."
                )

    return problems


def check_the_mapping_is_shared(repo: str) -> list[str]:
    problems: list[str] = []

    mapping_path = os.path.join(repo, MAPPING_SOURCE)
    if not os.path.isfile(mapping_path):
        return [
            f"{MAPPING_SOURCE}: not found. It holds the status-to-outcome mapping that the "
            f"transport and MockAPIClient.script(_:) share, which is what makes the network "
            f"double's agreement with the transport structural rather than coincidental."
        ]

    for caller in MAPPING_CALLERS:
        path = os.path.join(repo, caller)
        if not os.path.isfile(path):
            problems.append(f"{caller}: not found, and it is required to call {SHARED_MAPPING}.")
            continue
        with open(path, encoding="utf-8") as handle:
            body = handle.read()
        if f"{SHARED_MAPPING}." not in body:
            problems.append(
                f"{caller} no longer calls {SHARED_MAPPING}. The transport and the double map a "
                f"status code to an outcome by calling the same code; one of them doing it its "
                f"own way is a divergence the contract suite cannot see, because both halves "
                f"would still agree with whichever copy they each use."
            )

    with open(mapping_path, encoding="utf-8") as handle:
        if SUCCESS_RANGE not in handle.read():
            problems.append(
                f"{MAPPING_SOURCE} no longer spells the success range {SUCCESS_RANGE}. It is the "
                f"one place the 2xx boundary is decided for APIClient; a mapping that has stopped "
                f"saying where success ends is not the mapping the double was written against."
            )

    for caller in MAPPING_CALLERS:
        path = os.path.join(repo, caller)
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as handle:
            if SUCCESS_RANGE in handle.read():
                problems.append(
                    f"{caller} spells the success range {SUCCESS_RANGE} itself, and it is "
                    f"supposed to be calling {SHARED_MAPPING} for it. A second copy of the "
                    f"boundary is a second thing to get wrong, and the contract suite cannot see "
                    f"the divergence: both halves would go on agreeing with whichever copy each "
                    f"of them reads."
                )

    return problems


# MARK: - Entry point


def main() -> int:
    repo = sys.argv[1] if len(sys.argv) > 1 else REPO

    sources = os.path.join(repo, SOURCES)
    if not os.path.isdir(sources):
        print(f"Test-double audit failed:\n\n  {SOURCES}/: not found under {repo}.")
        return 1

    problems = (
        check_registry_against_tree(repo)
        + check_doubles_are_under_contract(repo)
        + check_the_mapping_is_shared(repo)
    )

    if problems:
        print("Test-double audit failed:\n")
        for problem in problems:
            print(f"  * {problem}\n")
        print("See docs/test-doubles.md for what each registry row claims.")
        return 1

    audited = sum(len(entries) for entries in REGISTRY.values())
    doubles = sum(
        1
        for entries in REGISTRY.values()
        for role, _, _, _ in entries.values()
        if role == "double"
    )
    print(
        f"{len(REGISTRY)} audited seam(s), {audited} registered conformer(s), "
        f"{doubles} of them doubles, each under a contract suite."
    )
    print("Test-double audit passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
