#!/usr/bin/env python3
"""Fail if a test double has stopped being held to its live implementation.

Phase 12 item 5. `docs/solid.md` states the problem in one sentence: the doubles
in this package "are two independent readings of a contract that is written down
nowhere". Finding 3 was what that costs — `save(user:)` inserted in the real
store and upserted in its double, so saving one user twice left two rows on
device and one entry under test, and nothing failed. The repair came with a pin
covering one method of nine.

The contract files are that contract, written down and executed: every case runs
against the live implementation *and* against the double, so a divergence fails
instead of waiting to be noticed. This script is what keeps them that way,
because all four ways they stop working compile, run, and report success:

  * A protocol grows a requirement and no contract case mentions it. The new
    method is then specified by whichever implementation a test happens to
    reach, which is exactly the state finding 3 came out of.
  * A contract case loses its `arguments:` and runs against one side. It still
    passes, still reads as a contract case, and now asserts nothing about the
    double at all.
  * A divergence pin is deleted. The pins are inverted tests — each fails when
    the divergence it describes is *repaired* — so deleting one is how a known
    defect becomes an unknown one. The table below is checked in both
    directions: a pin that is gone fails, and so does an entry whose test no
    longer exists.
  * The "live" side stops being live. A network contract whose live half is
    driven by `MockAPIClient` is two doubles agreeing with each other, which is
    worse than one double, because it reads as evidence.

Syntactic, like the other audits: no toolchain, no resolved packages and no
simulator, so it runs on Linux in the audits job and on the scheduled agent's
box. Each rule below was checked against the defect it names before it was
wired in.

Usage:  python3 Tools/assert-test-doubles.py [repo-root]
Exit:   0 when every contract still runs against both sides, 1 otherwise.
"""
from __future__ import annotations

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DOC = os.path.join("docs", "test-doubles.md")

TESTS = os.path.join("Tests", "ViewModelTests")


class Contract:
    """One seam held to its contract: the protocol, the two sides, the file."""

    def __init__(
        self,
        protocol: str,
        protocol_source: str,
        live: str,
        double: str,
        contract_file: str,
        enum_name: str,
        enum_cases: tuple[str, ...],
        banned: tuple[str, ...] = (),
    ) -> None:
        self.protocol = protocol
        self.protocol_source = protocol_source
        self.live = live
        self.double = double
        self.contract_file = contract_file
        self.enum_name = enum_name
        self.enum_cases = enum_cases
        # Types that must *not* appear in this contract file, with the reason
        # they would make it a weaker claim than it looks.
        self.banned = banned


CONTRACTS: tuple[Contract, ...] = (
    Contract(
        protocol="UserRepository",
        protocol_source=os.path.join("Sources", "Networking", "Repositories", "UserRepository.swift"),
        live="LiveUserRepository",
        double="MockUserRepository",
        contract_file=os.path.join(TESTS, "UserRepositoryContractTests.swift"),
        enum_name="RepositoryUnderContract",
        enum_cases=("liveOverFakeServer", "handWrittenDouble"),
        # The live half of this contract has to be the live stack. Substituting
        # the client is what `MockAPIClient` is for and it is the wrong seam
        # here: it replaces request building, header attachment, status mapping
        # and decoding — everything the contract is trying to hold the double
        # against. See the note at the top of `FakeUserAPI`.
        banned=("MockAPIClient",),
    ),
    Contract(
        protocol="UserPersistenceService",
        protocol_source=os.path.join("Sources", "Core", "Persistence", "UserPersistenceService.swift"),
        live="SwiftDataUserPersistenceService",
        double="MockUserPersistenceService",
        contract_file=os.path.join(TESTS, "UserPersistenceContractTests.swift"),
        enum_name="StoreUnderContract",
        enum_cases=("liveSwiftData", "handWrittenDouble"),
    ),
)

# The pins for what a double and its live implementation do *not* share.
#
# Keyed by contract file, then by the test function's name, and the value is why
# the divergence stands. Each one is an inverted test: it fails when the
# divergence is repaired, which is what makes the repair and the edit to
# docs/test-doubles.md land together.
#
# Checked in both directions. An entry whose test is gone fails, and a
# non-parameterised `@Test` in a contract file that is not listed here fails —
# because a contract case that quietly stopped running against both sides looks
# exactly like a divergence pin.
DIVERGENCES: dict[str, dict[str, str]] = {
    os.path.join(TESTS, "UserRepositoryContractTests.swift"): {
        "deleteLeavesTheDoubleAnsweringFetches": (
            "MockUserRepository holds no state for a delete to remove, so a flow driven "
            "through it cannot observe that the account is gone. Repairing it needs an "
            "error vocabulary the double does not have — docs/solid.md finding 4."
        ),
        "aNoContentDeleteFailsOnlyAgainstTheLiveStack": (
            "LiveUserRepository.deleteAccount() asks for EmptyResponse and an empty 204 "
            "body is not valid JSON, so a correct server produces APIError.decodingFailed. "
            "The fix is a transport that can discard a body; that is the transport's item."
        ),
        "anEditAdvancesTheRevisionOnlyLive": (
            "User.version is the server's counter. The double derives its answer locally, "
            "so an edit comes back at the same revision. Not repairable in the double: "
            "inventing an increment would be a claim about a server nobody configured."
        ),
        "aRedeliveredEditIsOneWrite": (
            "One edit redelivered is one write, and the two implementations record it in "
            "places a shared case cannot reach — the server's ledger, and updateKeys."
        ),
    },
    os.path.join(TESTS, "UserPersistenceContractTests.swift"): {},
}

# Every `@Test` is found by this, including the multi-line spellings, so a case
# cannot escape rule 3 by wrapping its arguments.
TEST_ATTRIBUTE = re.compile(r"@Test\b")
FUNC_NAME = re.compile(r"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")
PROTOCOL_REQUIREMENT = re.compile(r"^\s*func\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")
SUPPRESSIONS = ("withKnownIssue", ".disabled(", ".bug(")


def read(path: str) -> str:
    with open(os.path.join(REPO, path), encoding="utf-8") as handle:
        return handle.read()


def attribute_and_function(lines: list[str], index: int) -> tuple[str, str | None, int]:
    """The whole `@Test(...)` attribute from `index`, and the name it decorates.

    The attribute is gathered until its parentheses balance rather than read as
    one line, because a case whose arguments are wrapped over three lines is
    still a case and must not escape rule 3 that way. The function name is the
    first `func` at or after the attribute's last line.
    """
    text = ""
    position = index
    while position < len(lines):
        text += lines[position] + "\n"
        position += 1
        if text.count("(") == text.count(")"):
            break

    name = None
    for lookahead in range(position - 1, min(position + 5, len(lines))):
        match = FUNC_NAME.search(lines[lookahead])
        if match:
            name = match.group(1)
            break
    return text, name, position


def protocol_requirements(source: str, protocol: str) -> list[str]:
    """The method names declared in `protocol`'s own body.

    The body is taken from the declaration to the closing brace in column zero,
    which is how every protocol in this package is written. Extensions below it
    are deliberately excluded: a method with a default implementation is not a
    requirement a conformer has to answer.
    """
    lines = source.split("\n")
    start = None
    for index, line in enumerate(lines):
        if re.match(rf"^\s*(package |public )?protocol {protocol}\b", line):
            start = index
            break
    if start is None:
        return []

    requirements: list[str] = []
    for line in lines[start + 1:]:
        if line.startswith("}"):
            break
        match = PROTOCOL_REQUIREMENT.match(line)
        if match:
            requirements.append(match.group(1))
    return requirements


def check(contract: Contract, problems: list[str]) -> int:
    """Rules 1, 2, 3, 5, 6 and 7 for one seam. Returns the case count."""
    path = contract.contract_file
    if not os.path.exists(os.path.join(REPO, path)):
        problems.append(
            f"{path}: missing. {contract.protocol} is listed as contracted, so its "
            f"contract has to be somewhere a test runner can find it."
        )
        return 0

    source = read(path)
    lines = source.split("\n")

    # Rule 1 — the implementations enum, with exactly the pinned cases.
    #
    # Read off the enum's own body rather than off the file, in both directions.
    # Searching the whole file would be satisfied by the name appearing in a
    # comment, which is precisely what commenting a case out leaves behind.
    enum_body = re.search(
        rf"enum {contract.enum_name}\b[^{{]*{{(.*?)\n}}", source, re.DOTALL
    )
    if enum_body is None:
        problems.append(
            f"{path}: no `enum {contract.enum_name}` declared. Rule 3 reads the case "
            f"arguments off it, so renaming it turns rule 3 off."
        )
    else:
        in_enum = set(re.findall(r"^\s*case ([A-Za-z_][A-Za-z0-9_]*)", enum_body.group(1), re.MULTILINE))
        for case in contract.enum_cases:
            if case not in in_enum:
                problems.append(
                    f"{path}: `{contract.enum_name}` no longer declares `case {case}`. The "
                    f"contract runs once per case, so a dropped case is a side that "
                    f"stopped being tested."
                )
        for extra in sorted(in_enum - set(contract.enum_cases)):
            problems.append(
                f"{path}: `{contract.enum_name}` declares `case {extra}`, which this audit "
                f"has never heard of. Add it here with what it runs against."
            )

    # Rule 5 — both sides still exist, under the names this audit pins.
    for role, type_name in (("live implementation", contract.live), ("double", contract.double)):
        if not re.search(rf"\b(struct|final class|class|actor)\s+{type_name}\b", read(contract.protocol_source)):
            problems.append(
                f"{contract.protocol_source}: no declaration of `{type_name}`, the "
                f"{role} this audit pins for {contract.protocol}."
            )
        # A construction, not a mention. Every one of these files names both
        # sides in its prose, so searching for the bare name would be satisfied
        # by a contract that had stopped building one of them.
        if not re.search(rf"\b{type_name}\s*\(", source):
            problems.append(
                f"{path}: never constructs `{type_name}`, the {role} for "
                f"{contract.protocol}. A contract that does not build both sides is not "
                f"a contract."
            )

    # Rule 2 — every requirement of the protocol is exercised.
    requirements = protocol_requirements(read(contract.protocol_source), contract.protocol)
    if not requirements:
        problems.append(
            f"{contract.protocol_source}: could not read any requirement off "
            f"`protocol {contract.protocol}`. Rule 2 is off until this parses."
        )
    for requirement in sorted(set(requirements)):
        if not re.search(rf"\.{requirement}\b", source):
            problems.append(
                f"{path}: `{contract.protocol}.{requirement}` is a requirement no contract "
                f"case calls. It is specified by whichever implementation a test happens "
                f"to reach, which is how docs/solid.md finding 3 happened."
            )

    # Rule 6 — nothing is suppressed.
    for number, line in enumerate(lines, start=1):
        for suppression in SUPPRESSIONS:
            if suppression in line:
                problems.append(
                    f"{path}:{number}: `{suppression}` in a contract file. A suppressed "
                    f"contract case is a double nothing holds to anything."
                )
        if re.match(r"^\s*//\s*@Test\b", line):
            problems.append(
                f"{path}:{number}: a commented-out `@Test`. Delete it or fix it; a case "
                f"parked in a comment is a case that cannot fail."
            )

    # Rule 7 — the live side is the live stack.
    for banned in contract.banned:
        if re.search(rf"\b{banned}\b", source):
            problems.append(
                f"{path}: names `{banned}`. The live half of this contract has to be the "
                f"live stack — two doubles agreeing with each other reads as evidence and "
                f"is not."
            )

    # Rule 3 — every case runs against both sides, or is a recorded divergence.
    expected_divergences = DIVERGENCES.get(path, {})
    found_divergences: set[str] = set()
    cases = 0
    index = 0
    while index < len(lines):
        if not TEST_ATTRIBUTE.search(lines[index]):
            index += 1
            continue
        attribute, name, nxt = attribute_and_function(lines, index)
        index = max(nxt, index + 1)
        cases += 1
        if name is None:
            problems.append(f"{path}: a `@Test` that decorates no function.")
            continue
        parameterised = f"{contract.enum_name}.allCases" in attribute
        if parameterised:
            continue
        if name in expected_divergences:
            found_divergences.add(name)
            continue
        problems.append(
            f"{path}: `{name}` is a `@Test` that runs against one implementation. Either "
            f"give it `arguments: {contract.enum_name}.allCases`, or record it in "
            f"DIVERGENCES with why the two sides cannot agree."
        )

    # Rule 4, first direction — a pin that is gone.
    for name, reason in sorted(expected_divergences.items()):
        if name not in found_divergences:
            problems.append(
                f"{path}: no `@Test` named `{name}`, recorded in DIVERGENCES as: {reason} "
                f"A divergence whose pin is gone is a known defect that just became an "
                f"unknown one."
            )

    return cases


def check_documentation(problems: list[str]) -> None:
    """Rule 4, second direction: every divergence is written down for a reader."""
    if not os.path.exists(os.path.join(REPO, DOC)):
        problems.append(f"{DOC}: missing. The divergences are recorded there.")
        return
    doc = read(DOC)
    for path, divergences in sorted(DIVERGENCES.items()):
        for name in sorted(divergences):
            if name not in doc:
                problems.append(
                    f"{DOC}: does not mention `{name}`, pinned in {path}. A pin a reader "
                    f"cannot find is a defect recorded only in a test name."
                )


def main(argv: list[str]) -> int:
    global REPO
    if len(argv) > 1:
        REPO = os.path.abspath(argv[1])

    problems: list[str] = []
    cases = 0
    for contract in CONTRACTS:
        cases += check(contract, problems)
    check_documentation(problems)

    if problems:
        print("Test-double contract violations:\n", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print(f"\n{len(problems)} violation(s).", file=sys.stderr)
        return 1

    pins = sum(len(entries) for entries in DIVERGENCES.values())
    print(
        f"Test-double audit passed: {len(CONTRACTS)} seam(s) under contract, "
        f"{cases} case(s), {pins} recorded divergence(s)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
