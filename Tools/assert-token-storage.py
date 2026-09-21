#!/usr/bin/env python3
"""Fail if a credential is stored anywhere but the Keychain, or stored without
saying how it is protected.

Phase 11 item 1. CLAUDE.md states the rule in one line — "Tokens in Keychain
with access-control flags, never `UserDefaults`" — and until now nothing checked
it. Both halves are invisible to every other gate in this repo:

  * **`UserDefaults` compiles.** `UserDefaults.standard.set(token, forKey:)` is
    three words shorter than the Keychain call, needs no error handling, works
    in a preview, and writes the credential to a plist in the app container
    that any file-level backup carries off the device. Nothing about it looks
    wrong in review, and no test fails.

  * **An access policy is unobservable after the write.** `SecItemCopyMatching`
    does not hand back an item's `kSecAttrAccessControl`, and `SecAccessControl`
    has no public accessor for its constraints, so an item written with the
    weakest protection reads back exactly like one written with the strongest.
    The only place the policy is legible is the call site — which is why
    `KeychainStoring` has no write that omits it, and why this script checks
    that it stays that way.

Each rule below was verified by reintroducing the defect it names and watching
this script fail. It is deliberately a script rather than a test: it needs no
toolchain, no resolved packages and no simulator, so it runs on Linux in the
lint job, reports even when the build is broken, and is one of the few gates
the scheduled agent can run before pushing.

Run it with `python3 Tools/assert-token-storage.py [repo-root]`.
"""
from __future__ import annotations

import os
import re
import sys

# MARK: - What counts as a credential

# Substrings that make an identifier or a key credential-shaped. Matched
# case-insensitively against code with its comments removed, so the prose in
# `BackgroundRefreshLedger` explaining why a failure count is *not* one of these
# does not trip the rule it is describing.
#
# Deliberately absent: "auth" and "session". `URLSession`, `AuthorizationCode`
# and `SessionObserver` are all over this package, and a rule that cries wolf on
# them is a rule somebody switches off. Every credential this app actually holds
# is caught by "token", "secret" or "password".
CREDENTIAL_WORDS = (
    "token",
    "credential",
    "secret",
    "password",
    "passphrase",
    "apikey",
    "api_key",
    "bearer",
    "jwt",
)

# The defaults-backed stores. All three are a plist in the app container (or,
# for the ubiquitous store, in iCloud), readable by anything that can read the
# container and carried off the device by a file-level backup.
DEFAULTS_APIS = (
    "UserDefaults",
    "@AppStorage",
    "@SceneStorage",
    "NSUbiquitousKeyValueStore",
)

# Writing bytes somewhere the file system can hand back without a prompt.
PLAINTEXT_APIS = (
    ".write(to:",
    "NSKeyedArchiver",
    "FileManager.default.createFile",
    "createFile(atPath:",
)

# The one file allowed to name the account strings the token store owns.
TOKEN_KEY_OWNER = os.path.join("Sources", "Networking", "Transport", "TokenStore.swift")
TOKEN_KEY_PATTERN = re.compile(r'"com\.boilerplate\.(?:access|refresh|biometricRefresh)Token"')

KEYCHAIN_SOURCE = os.path.join("Sources", "Core", "Security", "KeychainWrapper.swift")
CONTAINER_SOURCE = os.path.join("Sources", "App", "AppContainer.swift")


# MARK: - Reading Swift with the prose taken out


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


def credential_words_in(text: str) -> list[str]:
    lowered = text.lower()
    return [word for word in CREDENTIAL_WORDS if word in lowered]


# MARK: - The rules


def check_defaults(path: str, relative: str, problems: list[str]) -> None:
    """Rule 1: no credential reaches a defaults-backed store."""
    for number, statement in statements(strip_comments(read(path))):
        if not any(api in statement for api in DEFAULTS_APIS):
            continue
        words = credential_words_in(statement)
        if words:
            problems.append(
                f"{relative}:{number}: a defaults-backed store is used in a statement naming "
                f"{', '.join(words)}. Credentials belong in the Keychain under a "
                f"KeychainAccessPolicy — see docs/security.md."
            )


def check_plaintext_writes(path: str, relative: str, problems: list[str]) -> None:
    """Rule 2: no credential is written to a file this app can read back."""
    for number, statement in statements(strip_comments(read(path))):
        if not any(api in statement for api in PLAINTEXT_APIS):
            continue
        words = credential_words_in(statement)
        if words:
            problems.append(
                f"{relative}:{number}: a file write in a statement naming {', '.join(words)}. "
                f"A file in the app container is not protected by the Keychain's access control."
            )


def check_token_keys(relative: str, lines: list[str], problems: list[str]) -> None:
    """Rule 3: the token account names live in the store that owns them."""
    if relative == TOKEN_KEY_OWNER:
        return
    for number, line in enumerate(lines, 1):
        if TOKEN_KEY_PATTERN.search(line):
            problems.append(
                f"{relative}:{number}: names one of TokenStore's Keychain accounts directly. "
                f"Go through TokenStore.Keys, so that what protects the item stays in one place."
            )


def check_write_signature(source: str, problems: list[str]) -> None:
    """Rule 4: `KeychainStoring` has no write that omits the policy."""
    match = re.search(r"package protocol KeychainStoring: Sendable \{(.*?)\n\}", source, re.DOTALL)
    if not match:
        problems.append(f"{KEYCHAIN_SOURCE}: no `package protocol KeychainStoring` found.")
        return

    writes = [line.strip() for line in match.group(1).splitlines() if line.strip().startswith("func set(")]
    if len(writes) != 1:
        problems.append(
            f"{KEYCHAIN_SOURCE}: KeychainStoring declares {len(writes)} write(s); expected exactly one. "
            f"An overload without a policy is how the weakest protection becomes the default."
        )
        return
    if "policy: KeychainAccessPolicy" not in writes[0]:
        problems.append(
            f"{KEYCHAIN_SOURCE}: the KeychainStoring write does not take a KeychainAccessPolicy: "
            f"{writes[0]}"
        )


def check_writes_name_a_policy(path: str, relative: str, problems: list[str]) -> None:
    """Rule 5: every Keychain write in the app says what protects the item."""
    for number, statement in statements(strip_comments(read(path))):
        if not re.search(r"\bkeychain\.set\(", statement):
            continue
        if "policy:" not in statement:
            problems.append(
                f"{relative}:{number}: a Keychain write with no policy: argument. "
                f"The call site is the only place the protection is legible."
            )


def check_container_names_the_unlock_policy(source: str, problems: list[str]) -> None:
    """Rule 6: the composition root still decides the biometric unlock."""
    for _, statement in statements(strip_comments(source)):
        if re.search(r"\bTokenStore\(", statement):
            if "biometricUnlock:" not in statement:
                problems.append(
                    f"{CONTAINER_SOURCE}: builds a TokenStore without naming a BiometricUnlockPolicy. "
                    f"Left to the default the app silently stops offering biometric unlock."
                )
            return
    problems.append(f"{CONTAINER_SOURCE}: no TokenStore is constructed here any more.")


def read(path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        return handle.read()


# MARK: - Entry point


def main() -> int:
    repo = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.dirname(
        os.path.dirname(os.path.abspath(__file__))
    )
    problems: list[str] = []
    scanned = 0

    for directory in ("Sources", "Tests"):
        root = os.path.join(repo, directory)
        if not os.path.isdir(root):
            problems.append(f"{directory}/: not found under {repo}.")
            continue
        for path in swift_files(root):
            relative = os.path.relpath(path, repo)
            scanned += 1
            check_defaults(path, relative, problems)
            check_plaintext_writes(path, relative, problems)
            if directory == "Sources":
                check_token_keys(relative, read(path).splitlines(), problems)
                check_writes_name_a_policy(path, relative, problems)

    keychain_path = os.path.join(repo, KEYCHAIN_SOURCE)
    if os.path.isfile(keychain_path):
        check_write_signature(read(keychain_path), problems)
    else:
        problems.append(f"{KEYCHAIN_SOURCE}: not found.")

    container_path = os.path.join(repo, CONTAINER_SOURCE)
    if os.path.isfile(container_path):
        check_container_names_the_unlock_policy(read(container_path), problems)
    else:
        problems.append(f"{CONTAINER_SOURCE}: not found.")

    if problems:
        print("Token storage audit failed:\n")
        for problem in problems:
            print(f"  {problem}")
        print(f"\n{len(problems)} problem(s) across {scanned} source files.")
        return 1

    print(f"Token storage audit passed across {scanned} source files.")
    print("  credentials: Keychain only, every write naming a KeychainAccessPolicy")
    return 0


if __name__ == "__main__":
    sys.exit(main())
