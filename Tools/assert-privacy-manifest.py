#!/usr/bin/env python3
"""Fail if a privacy manifest stops describing the code it ships beside.

Phase 11 item 6. A privacy manifest is a document that makes claims about a
binary, and nothing in a normal build checks the two against each other. That
gives it a failure mode none of the other gates in this repository can see, and
it is not "the manifest is malformed" — a malformed manifest is caught at upload.
It is **the manifest and the code drifting apart**, in either direction:

  * **A required-reason API arrives with no declaration behind it.** One
    `@AppStorage` on a view, one `attributesOfItem(atPath:)` in a cache sweep,
    one `ProcessInfo.processInfo.systemUptime` in a stopwatch. Each compiles,
    passes the suite, runs on a device, ships through TestFlight — and comes
    back as an `ITMS-91053` notice against a build somebody is trying to
    release, weeks after the line was written, naming an API nobody remembers
    adding.

  * **A declaration outlives the code that justified it.** Delete the last
    `UserDefaults` call and the entry stays, which is a false statement in the
    app's privacy report and a row in the App Store listing saying this app
    reads something it does not read. Nothing fails. Nobody notices, because
    over-declaring is not an upload error.

So the central rule here is an *equality*, not a floor: for every target, the
set of required-reason API categories its source actually reaches equals the set
its manifest declares. Both drifts fail.

The second rule is about where a manifest has to be. These four live in SwiftPM
resource bundles, which is right for a package and is not what an upload is
checked against: a SwiftPM target links statically, so `Core`'s `UserDefaults`
calls are symbols in the *app's* executable while the manifest sits in a bundle
beside it. `Tools/app-template/PrivacyInfo.xcprivacy` is the copy for the app
bundle's root, and it has to stay the exact union of the four — a superset is
checked in both directions, because a template that declares more than the
package uses is the same false statement one file further out.

Each rule below was verified by reintroducing the defect it names and watching
this script fail. It is deliberately a script rather than a test: it needs no
toolchain, no resolved packages and no simulator, so it runs on Linux in the
lint job, reports even when the build is broken, and is one of the few gates the
scheduled agent can run before pushing.

What it does **not** check, and cannot: whether the collected-data rows are
*true*. "This app sends your email address for app functionality" is a claim
about intent and about a server, and no scanner reads either. The proxy it does
check is that the targets which put a request body on the wire are exactly the
targets declaring collected data, so a module that starts talking to the server
cannot keep a manifest saying it collects nothing. `PrivacyManifestTests` covers
the other half this cannot reach — that the files are actually *in* the bundles.

Run it with `python3 Tools/assert-privacy-manifest.py [repo-root]`.
"""
from __future__ import annotations

import os
import plistlib
import re
import sys

# MARK: - The package

# Target name -> (source directory, manifest path relative to the repo root).
TARGETS = {
    "Core": ("Sources/Core", "Sources/Core/Resources/PrivacyInfo.xcprivacy"),
    "Networking": ("Sources/Networking", "Sources/Networking/Resources/PrivacyInfo.xcprivacy"),
    "Features": ("Sources/Features", "Sources/Features/Resources/PrivacyInfo.xcprivacy"),
    "BoilerplateiOSSwift": ("Sources/App", "Sources/App/Resources/PrivacyInfo.xcprivacy"),
}

APP_TEMPLATE = "Tools/app-template/PrivacyInfo.xcprivacy"
DOCS = "docs/privacy-manifest.md"

TOP_LEVEL_KEYS = {
    "NSPrivacyTracking": bool,
    "NSPrivacyTrackingDomains": list,
    "NSPrivacyCollectedDataTypes": list,
    "NSPrivacyAccessedAPITypes": list,
}

# MARK: - Apple's vocabulary
#
# Hard-coded rather than fetched, because a gate that reaches the network is a
# gate that goes red when a CDN does. The cost is that a category Apple adds
# later reads here as an unknown string and fails — which is the safe direction:
# an unrecognised declaration is reviewed by a person rather than waved through.

# Category -> the reason codes Apple documents for it.
REASON_CODES = {
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"DDA9.1", "C617.1", "3B52.1", "0A2A.1"},
    "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1", "8FFB.1", "3D61.1"},
    "NSPrivacyAccessedAPICategoryDiskSpace": {"85F4.1", "E174.1", "7D9E.1", "B728.1"},
    "NSPrivacyAccessedAPICategoryActiveKeyboards": {"3EC4.1", "54BD.1"},
    "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1", "1C8F.1", "C56D.1", "AC6B.1"},
}

# Category -> the Swift spellings that reach it.
#
# Each pattern is matched against source with its comments removed, so the
# paragraph in `BackgroundRefreshLedger` explaining *why* a failure count lives
# in `UserDefaults` does not count as a use of it — and the entry in
# `AppAttestor`'s documentation explaining why the key identifier does *not* go
# there does not make the composition root look like a defaults reader.
#
# `\bUserDefaults\b` and not `UserDefaults`: `UserDefaultsBackgroundRefreshLedger`
# is a type name, `Sources/App` names it to build the graph, and naming a type is
# not calling the API it wraps. The word boundary is what keeps the composition
# root out of this.
API_PATTERNS = {
    "NSPrivacyAccessedAPICategoryUserDefaults": (
        r"\bUserDefaults\b",
        r"@AppStorage\b",
        r"@SceneStorage\b",
    ),
    "NSPrivacyAccessedAPICategoryFileTimestamp": (
        r"\.creationDate\b",
        r"\.modificationDate\b",
        r"\bfileModificationDate\b",
        r"\bcontentModificationDateKey\b",
        r"\bcreationDateKey\b",
        r"\battributesOfItem\s*\(",
        r"\bgetattrlist(?:bulk|at)?\s*\(",
        r"\bfgetattrlist\s*\(",
        r"\b(?:f|l)?stat\s*\(",
        r"\bfstatat\s*\(",
    ),
    "NSPrivacyAccessedAPICategorySystemBootTime": (
        r"\bsystemUptime\b",
        r"\bmach_absolute_time\s*\(",
        r"\bmach_continuous_time\s*\(",
    ),
    "NSPrivacyAccessedAPICategoryDiskSpace": (
        r"\bvolumeAvailableCapacity(?:ForImportantUsage|ForOpportunisticUsage)?Key\b",
        r"\bvolumeTotalCapacityKey\b",
        r"\bsystemFreeSize\b",
        r"\bsystemSize\b",
        r"\b(?:f)?statfs\s*\(",
        r"\b(?:f)?statvfs\s*\(",
    ),
    "NSPrivacyAccessedAPICategoryActiveKeyboards": (
        r"\bactiveInputModes\b",
    ),
}

COLLECTED_DATA_TYPES = {
    "NSPrivacyCollectedDataTypeName",
    "NSPrivacyCollectedDataTypeEmailAddress",
    "NSPrivacyCollectedDataTypePhoneNumber",
    "NSPrivacyCollectedDataTypePhysicalAddress",
    "NSPrivacyCollectedDataTypeOtherContactInfo",
    "NSPrivacyCollectedDataTypeHealth",
    "NSPrivacyCollectedDataTypeFitness",
    "NSPrivacyCollectedDataTypePaymentInfo",
    "NSPrivacyCollectedDataTypeCreditInfo",
    "NSPrivacyCollectedDataTypeOtherFinancialInfo",
    "NSPrivacyCollectedDataTypePreciseLocation",
    "NSPrivacyCollectedDataTypeCoarseLocation",
    "NSPrivacyCollectedDataTypeSensitiveInfo",
    "NSPrivacyCollectedDataTypeContacts",
    "NSPrivacyCollectedDataTypeEmailsOrTextMessages",
    "NSPrivacyCollectedDataTypePhotosorVideos",
    "NSPrivacyCollectedDataTypeAudioData",
    "NSPrivacyCollectedDataTypeGameplayContent",
    "NSPrivacyCollectedDataTypeCustomerSupport",
    "NSPrivacyCollectedDataTypeOtherUserContent",
    "NSPrivacyCollectedDataTypeBrowsingHistory",
    "NSPrivacyCollectedDataTypeSearchHistory",
    "NSPrivacyCollectedDataTypeUserID",
    "NSPrivacyCollectedDataTypeDeviceID",
    "NSPrivacyCollectedDataTypePurchaseHistory",
    "NSPrivacyCollectedDataTypeProductInteraction",
    "NSPrivacyCollectedDataTypeAdvertisingData",
    "NSPrivacyCollectedDataTypeOtherUsageData",
    "NSPrivacyCollectedDataTypeCrashData",
    "NSPrivacyCollectedDataTypePerformanceData",
    "NSPrivacyCollectedDataTypeOtherDiagnosticData",
    "NSPrivacyCollectedDataTypeEnvironmentScanning",
    "NSPrivacyCollectedDataTypeHands",
    "NSPrivacyCollectedDataTypeHead",
    "NSPrivacyCollectedDataTypeOtherDataTypes",
}

COLLECTED_PURPOSES = {
    "NSPrivacyCollectedDataTypePurposeThirdPartyAdvertising",
    "NSPrivacyCollectedDataTypePurposeDeveloperAdvertising",
    "NSPrivacyCollectedDataTypePurposeAnalytics",
    "NSPrivacyCollectedDataTypePurposeProductPersonalization",
    "NSPrivacyCollectedDataTypePurposeAppFunctionality",
    "NSPrivacyCollectedDataTypePurposeOther",
}

# A request body leaving the device. `httpBody\s*=` and not `httpBody`, because
# `AttestationClientData` *reads* the body to hash it into the signed bytes, and
# hashing a body is not sending one.
TRANSMITS = (
    re.compile(r"\bAPIEndpoint\.(?:post|put|patch)\s*\("),
    re.compile(r"\bhttpBody\s*="),
)

# An App Group suite is a different reason code from an app-private one: the
# values are reachable by every extension in the group. A literal suite name is
# the only form this can be sure about — `UserDefaults(suiteName: suiteName)`
# takes whatever the caller passes, and today every caller passes `nil`.
LITERAL_SUITE = re.compile(r"\bUserDefaults\s*\(\s*suiteName:\s*\"")
APP_GROUP_REASON = "1C8F.1"


# MARK: - Reading Swift with the prose taken out


def swift_files(directory: str) -> list[str]:
    found: list[str] = []
    for root, _, names in os.walk(directory):
        found.extend(os.path.join(root, name) for name in names if name.endswith(".swift"))
    return sorted(found)


def strip_comments(source: str) -> str:
    """Returns `source` with comments blanked out and string literals kept.

    String literals stay because a required-reason API can be named in one —
    `"NSPrivacyAccessedAPICategoryUserDefaults"` is not the point, but a key
    passed as a literal is how half of these APIs are reached. Comments go
    because this repository documents its decisions in prose at length, and a
    scanner that reads prose fails the file explaining the rule it enforces.
    """
    out: list[str] = []
    index = 0
    length = len(source)
    state = "code"  # code | line_comment | block_comment | string | multiline
    depth = 0  # nesting for /* ... /* ... */ ... */, which Swift allows

    while index < length:
        char = source[index]
        ahead3 = source[index:index + 3]
        ahead2 = source[index:index + 2]

        if state == "code":
            if ahead3 == '"""':
                state = "multiline"
                out.append(ahead3)
                index += 3
                continue
            if char == '"':
                state = "string"
                out.append(char)
                index += 1
                continue
            if ahead2 == "//":
                state = "line_comment"
                index += 2
                continue
            if ahead2 == "/*":
                state = "block_comment"
                depth = 1
                index += 2
                continue
            out.append(char)
            index += 1
            continue

        if state == "string":
            out.append(char)
            if char == "\\" and index + 1 < length:
                out.append(source[index + 1])
                index += 2
                continue
            if char == '"' or char == "\n":
                # A newline inside a single-line literal means the file would
                # not compile; stop pretending to understand it.
                state = "code"
            index += 1
            continue

        if state == "multiline":
            if ahead3 == '"""':
                state = "code"
                out.append(ahead3)
                index += 3
                continue
            out.append(char)
            index += 1
            continue

        if state == "line_comment":
            if char == "\n":
                state = "code"
                out.append(char)
            index += 1
            continue

        # block_comment
        if ahead2 == "/*":
            depth += 1
            index += 2
            continue
        if ahead2 == "*/":
            depth -= 1
            index += 2
            if depth == 0:
                state = "code"
            continue
        if char == "\n":
            out.append(char)
        index += 1

    return "".join(out)


def read(path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def code_of(directory: str) -> str:
    return "\n".join(strip_comments(read(path)) for path in swift_files(directory))


# MARK: - The rules


def load_manifest(repo: str, relative: str, problems: list[str]) -> dict | None:
    """Rule 1: every manifest is a plist dictionary carrying all four keys."""
    path = os.path.join(repo, relative)
    if not os.path.isfile(path):
        problems.append(f"{relative}: no privacy manifest here. Every target ships one.")
        return None
    try:
        with open(path, "rb") as handle:
            manifest = plistlib.load(handle)
    except Exception as error:  # noqa: BLE001 — the message is the useful part
        problems.append(f"{relative}: does not parse as a property list: {error}")
        return None
    if not isinstance(manifest, dict):
        problems.append(f"{relative}: the root is {type(manifest).__name__}, not a dictionary.")
        return None

    for key, kind in TOP_LEVEL_KEYS.items():
        if key not in manifest:
            problems.append(
                f"{relative}: no {key}. An absent key and an empty one mean the same thing to "
                f"Apple's tooling and different things to a reader; declare it empty instead."
            )
        elif not isinstance(manifest[key], kind):
            problems.append(
                f"{relative}: {key} is {type(manifest[key]).__name__}, expected {kind.__name__}."
            )
    for key in sorted(set(manifest) - set(TOP_LEVEL_KEYS)):
        problems.append(f"{relative}: unknown top-level key {key}.")
    return manifest


def declared_categories(relative: str, manifest: dict, problems: list[str]) -> dict[str, set[str]]:
    """Rule 2: every accessed-API entry names a real category and real reasons."""
    found: dict[str, set[str]] = {}
    for index, entry in enumerate(manifest.get("NSPrivacyAccessedAPITypes", [])):
        where = f"{relative}: NSPrivacyAccessedAPITypes[{index}]"
        if not isinstance(entry, dict):
            problems.append(f"{where}: not a dictionary.")
            continue
        category = entry.get("NSPrivacyAccessedAPIType")
        reasons = entry.get("NSPrivacyAccessedAPITypeReasons")
        if not isinstance(category, str) or category not in REASON_CODES:
            problems.append(f"{where}: {category!r} is not one of Apple's API categories.")
            continue
        if category in found:
            problems.append(f"{where}: {category} is declared twice. Merge the reason lists.")
        if not isinstance(reasons, list) or not reasons:
            problems.append(
                f"{where}: {category} carries no reasons. A category with an empty reason "
                f"list is rejected at upload."
            )
            found.setdefault(category, set())
            continue
        unknown = [code for code in reasons if code not in REASON_CODES[category]]
        if unknown:
            problems.append(
                f"{where}: {unknown} are not reason codes Apple documents for {category}. "
                f"Valid: {sorted(REASON_CODES[category])}."
            )
        found[category] = set(reasons)
    return found


def declared_data_types(relative: str, manifest: dict, problems: list[str]) -> set[str]:
    """Rule 3: every collected-data entry is complete and uses Apple's vocabulary."""
    found: set[str] = set()
    tracks = manifest.get("NSPrivacyTracking") is True
    for index, entry in enumerate(manifest.get("NSPrivacyCollectedDataTypes", [])):
        where = f"{relative}: NSPrivacyCollectedDataTypes[{index}]"
        if not isinstance(entry, dict):
            problems.append(f"{where}: not a dictionary.")
            continue
        kind = entry.get("NSPrivacyCollectedDataType")
        if not isinstance(kind, str) or kind not in COLLECTED_DATA_TYPES:
            problems.append(f"{where}: {kind!r} is not one of Apple's collected data types.")
            continue
        if kind in found:
            problems.append(f"{where}: {kind} is declared twice. Merge the purposes.")
        found.add(kind)

        for flag in ("NSPrivacyCollectedDataTypeLinked", "NSPrivacyCollectedDataTypeTracking"):
            if not isinstance(entry.get(flag), bool):
                problems.append(f"{where}: {flag} is missing or not a boolean.")

        purposes = entry.get("NSPrivacyCollectedDataTypePurposes")
        if not isinstance(purposes, list) or not purposes:
            problems.append(f"{where}: no purposes. Every collected type states at least one.")
        else:
            unknown = [p for p in purposes if p not in COLLECTED_PURPOSES]
            if unknown:
                problems.append(f"{where}: {unknown} are not purposes Apple documents.")

        if entry.get("NSPrivacyCollectedDataTypeTracking") is True and not tracks:
            problems.append(
                f"{where}: {kind} is marked as used for tracking while NSPrivacyTracking is "
                f"false. One of the two is wrong."
            )
    return found


def check_tracking(relative: str, manifest: dict, problems: list[str]) -> None:
    """Rule 4: the tracking flag and the domain list agree with each other.

    The asymmetry is deliberate and it is iOS's, not this script's: once the
    user has denied tracking, a connection to a domain in this list is *refused*
    at runtime. So a domain declared while tracking is off is a statement with
    no mechanism behind it, and tracking declared with no domain is a mechanism
    with nothing listed — the second being the one that fails in production, as
    a request that silently stops working on somebody else's device.
    """
    tracks = manifest.get("NSPrivacyTracking")
    domains = manifest.get("NSPrivacyTrackingDomains")
    if not isinstance(tracks, bool) or not isinstance(domains, list):
        return
    if tracks and not domains:
        problems.append(
            f"{relative}: NSPrivacyTracking is true and NSPrivacyTrackingDomains is empty. "
            f"Every domain reached for tracking has to be listed or iOS will not call it."
        )
    if not tracks and domains:
        problems.append(
            f"{relative}: NSPrivacyTrackingDomains lists {domains} while NSPrivacyTracking is "
            f"false. A tracking domain with tracking switched off describes nothing."
        )


def check_api_usage(
    repo: str,
    target: str,
    directory: str,
    relative: str,
    declared: dict[str, set[str]],
    problems: list[str],
) -> None:
    """Rule 5: declared categories equal used categories, in both directions."""
    code = code_of(os.path.join(repo, directory))
    used = {
        category
        for category, patterns in API_PATTERNS.items()
        if any(re.search(pattern, code) for pattern in patterns)
    }

    for category in sorted(used - set(declared)):
        matched = [p for p in API_PATTERNS[category] if re.search(p, code)]
        problems.append(
            f"{relative}: {target} reaches {category} ({', '.join(matched)}) and the manifest "
            f"does not declare it. This is the shape that returns as an ITMS-91053 notice "
            f"against a build somebody is trying to release."
        )
    for category in sorted(set(declared) - used):
        problems.append(
            f"{relative}: declares {category}, which nothing in {directory} reaches any more. "
            f"A declaration that outlived its code is a false statement in the privacy report."
        )

    if LITERAL_SUITE.search(code) and APP_GROUP_REASON not in declared.get(
        "NSPrivacyAccessedAPICategoryUserDefaults", set()
    ):
        problems.append(
            f"{relative}: {target} opens a named UserDefaults suite, which is an App Group "
            f"store rather than an app-private one, so it needs {APP_GROUP_REASON} beside "
            f"CA92.1."
        )


def check_transmission(
    repo: str,
    target: str,
    directory: str,
    relative: str,
    data_types: set[str],
    problems: list[str],
) -> None:
    """Rule 6: the targets that put a body on the wire are the ones declaring
    collected data.

    This is a proxy and is the best one available here. Whether "email address,
    for app functionality" is *true* is a claim about intent and about a server,
    and no scanner reads either. What a scanner can see is a module that started
    sending request bodies while its manifest still says it collects nothing,
    which is the drift that actually happens.
    """
    code = code_of(os.path.join(repo, directory))
    transmits = any(pattern.search(code) for pattern in TRANSMITS)
    if transmits and not data_types:
        problems.append(
            f"{relative}: {target} sends request bodies and declares no collected data type. "
            f"Say what is in them, or route the call through a target that does."
        )
    if data_types and not transmits:
        problems.append(
            f"{relative}: declares {sorted(data_types)} while nothing in {directory} sends a "
            f"request body any more."
        )


def check_app_template(
    repo: str,
    categories: dict[str, set[str]],
    data_types: set[str],
    problems: list[str],
) -> None:
    """Rule 7: the app-bundle template is exactly the union of the four.

    Both directions, and the second is not pedantry. A template that declares
    more than the package uses is the same false statement as a stale target
    manifest, one file further out — and it is the file an adopter copies, so it
    is the one that ends up in the App Store listing.
    """
    manifest = load_manifest(repo, APP_TEMPLATE, problems)
    if manifest is None:
        return
    check_tracking(APP_TEMPLATE, manifest, problems)
    template_categories = declared_categories(APP_TEMPLATE, manifest, problems)
    template_types = declared_data_types(APP_TEMPLATE, manifest, problems)

    for category, reasons in sorted(categories.items()):
        missing = reasons - template_categories.get(category, set())
        if category not in template_categories:
            problems.append(
                f"{APP_TEMPLATE}: the package reaches {category} and the app template does not "
                f"declare it. A SwiftPM target links statically, so that call is a symbol in "
                f"the app's own binary — see docs/privacy-manifest.md."
            )
        elif missing:
            problems.append(
                f"{APP_TEMPLATE}: {category} is missing the reason(s) {sorted(missing)} that a "
                f"target manifest declares."
            )
    for category in sorted(set(template_categories) - set(categories)):
        problems.append(
            f"{APP_TEMPLATE}: declares {category}, which no target in this package reaches. "
            f"The template is the union of the four, not a wishlist."
        )

    for kind in sorted(data_types - template_types):
        problems.append(f"{APP_TEMPLATE}: no entry for {kind}, which a target manifest declares.")
    for kind in sorted(template_types - data_types):
        problems.append(
            f"{APP_TEMPLATE}: declares {kind}, which no target in this package declares."
        )


def check_package_ships_them(repo: str, problems: list[str]) -> None:
    """Rule 8: every target that carries a manifest has a `resources:` rule.

    Without one the file is a correct document that reaches no bundle, which is
    invisible to every other check here — this script reads the repository, not
    the build — and means the privacy report is assembled without it.
    """
    manifest = read(os.path.join(repo, "Package.swift"))
    for block in re.finditer(
        r"\.target\(\s*name:\s*\"([^\"]+)\"(.*?)\n        \)", manifest, re.S
    ):
        name, body = block.group(1), block.group(2)
        if name not in TARGETS:
            continue
        if not re.search(r"resources:\s*\[", body):
            problems.append(
                f"Package.swift: target {name} declares no resources, so its "
                f"PrivacyInfo.xcprivacy reaches no bundle."
            )


def check_docs(repo: str, categories: dict[str, set[str]], data_types: set[str],
               problems: list[str]) -> None:
    """Rule 9: the page documents every declaration, and keeps its gaps.

    The same rule the threat model has, for the same reason: a privacy page
    listing only the comfortable half is the marketing version, and the gaps
    here are the part an adopter has to act on — this package has no app target,
    so the manifest that an upload is actually checked against is one they have
    to place themselves.
    """
    path = os.path.join(repo, DOCS)
    if not os.path.isfile(path):
        problems.append(f"{DOCS}: not found. The declarations need a page explaining them.")
        return
    page = read(path)
    for category in sorted(categories):
        if category not in page:
            problems.append(f"{DOCS}: does not mention {category}, which the package declares.")
    for kind in sorted(data_types):
        if kind not in page:
            problems.append(f"{DOCS}: does not mention {kind}, which the package declares.")
    if not re.search(r"^#+\s*.*(limitation|not done|gap)", page, re.I | re.M):
        problems.append(
            f"{DOCS}: no limitations section. What this cannot check is the part a reader "
            f"needs most."
        )


# MARK: - Entry point


def main() -> int:
    repo = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.dirname(
        os.path.dirname(os.path.abspath(__file__))
    )
    problems: list[str] = []

    union_categories: dict[str, set[str]] = {}
    union_data_types: set[str] = set()

    for target, (directory, relative) in sorted(TARGETS.items()):
        source = os.path.join(repo, directory)
        if not os.path.isdir(source):
            problems.append(f"{directory}/: not found under {repo}.")
            continue
        manifest = load_manifest(repo, relative, problems)
        if manifest is None:
            continue
        check_tracking(relative, manifest, problems)
        categories = declared_categories(relative, manifest, problems)
        data_types = declared_data_types(relative, manifest, problems)
        check_api_usage(repo, target, directory, relative, categories, problems)
        check_transmission(repo, target, directory, relative, data_types, problems)

        for category, reasons in categories.items():
            union_categories.setdefault(category, set()).update(reasons)
        union_data_types |= data_types

    check_app_template(repo, union_categories, union_data_types, problems)
    check_package_ships_them(repo, problems)
    check_docs(repo, union_categories, union_data_types, problems)

    if problems:
        print("Privacy manifest audit failed:\n")
        for problem in problems:
            print(f"  {problem}")
        print(f"\n{len(problems)} problem(s).")
        return 1

    print(f"Privacy manifest audit passed across {len(TARGETS)} targets and the app template.")
    for category, reasons in sorted(union_categories.items()):
        print(f"  {category}: {', '.join(sorted(reasons))}")
    print(f"  collected: {', '.join(sorted(union_data_types)) or 'nothing'}")
    print("  tracking: no, in every manifest, with no tracking domains")
    return 0


if __name__ == "__main__":
    sys.exit(main())
