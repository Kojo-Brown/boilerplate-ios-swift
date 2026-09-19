#!/usr/bin/env python3
"""Hold this package's String Catalogs to the checks Xcode performs for an app.

Phase 10 item 7. An app target gets a good deal of this for free: Xcode walks
the source, extracts every `Text("…")` into the catalog, marks an entry whose
string has gone as stale, and resolves lookups against `Bundle.main`, which is
where the catalog it just built happens to be. A Swift package gets none of it.
Nothing extracts, nothing goes stale, and — the part that actually bites —
`Text("home.title")` in a package resolves against `Bundle.main` too, where the
package's catalog is not. Foundation's documented fallback for a missing key is
to hand back the key, so the screen renders `home.title`, in every language
including the one the catalog was written in. No warning, no crash, and not
visible in a preview, because a preview and its catalog are in the same bundle.

So the loop is closed here instead, in four directions:

  1. **No user-facing literal.** A curated list of SwiftUI APIs — the ones whose
     first argument is a string somebody reads — must not be called with a bare
     literal outside preview code. That is the rule Xcode's extractor makes
     unnecessary for an app and that nothing enforces for a package.

  2. **Source and catalog agree, both ways.** Every key a `*Strings.swift` file
     looks up must exist in that target's catalog, and every key the catalog
     declares must be looked up by something. The second direction is the one
     that rots: a string removed from a screen leaves an entry a translator
     goes on being paid to translate.

  3. **The tests cover every key.** `LocalisationTests` and
     `FeatureLocalisationTests` assert that each resource resolves to something
     other than its own key, which is the assertion that fails if a `bundle:`
     argument is ever dropped. A key with no test is a key that check does not
     cover, so the lists have to match the catalogs exactly.

  4. **The catalog is well formed.** Every entry carries a comment (the only
     thing a translator sees beside the string), an `en` value (a symbolic key
     like `home.title` is not a fallback anybody wants rendered), and a format
     specifier in its key if and only if its value interpolates one.

Plus the two defects this item found in the code it was written against:

  5. **No plural assembled in Swift.** `"\\(n) block\\(n == 1 ? "" : "s")"` is
     English's rule written out, and English has the fewest categories to get
     wrong. It is also a sentence no translator ever sees, because it does not
     exist until runtime.

  6. **No `Layout` that ignores the reading direction.** SwiftUI mirrors its own
     containers and does *not* mirror a custom `Layout`: `placeSubviews` gets a
     `bounds` whose x grows rightwards in Arabic exactly as in English. A
     conformance that never reads `LayoutSubviews.layoutDirection` lays out
     backwards for a right-to-left reader, and the source looks right.

Every rule below was verified by reintroducing the defect it names and watching
this script fail on it. It runs on Linux, in the lint job, beside the Sendable,
module-boundary and accessibility audits — no toolchain, no simulator, and
runnable by the scheduled agent before it pushes.

Run it with `python3 Tools/assert-localisation.py`.
"""
from __future__ import annotations

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# target -> (source directory, catalog, accessor function, test files)
TARGETS = {
    "Core": (
        "Sources/Core",
        "Sources/Core/Resources/Localizable.xcstrings",
        "coreString",
        ["Tests/ViewModelTests/LocalisationTests.swift"],
    ),
    "Networking": (
        "Sources/Networking",
        "Sources/Networking/Resources/Localizable.xcstrings",
        "networkingString",
        ["Tests/ViewModelTests/LocalisationTests.swift"],
    ),
    "Features": (
        "Sources/Features",
        "Sources/Features/Resources/Localizable.xcstrings",
        "featureString",
        ["Tests/ViewModelTests/FeatureLocalisationTests.swift"],
    ),
}

# The APIs whose leading argument is a string a reader sees. `Text(verbatim:)`
# is deliberately absent: it exists to say "this is data, not prose", and the
# payload strings a scanner reads back are exactly that.
USER_FACING = [
    r"Text\(\s*\"",
    r"Label\(\s*\"",
    r"Button\(\s*\"",
    r"Section\(\s*\"",
    r"Toggle\(\s*\"",
    r"Picker\(\s*\"",
    r"TextField\(\s*\"",
    r"SecureField\(\s*\"",
    r"ProgressView\(\s*\"",
    r"LabeledContent\(\s*\"",
    r"ContentUnavailableView\(\s*\"",
    r"AppButton\(\s*\"",
    r"AppTextField\(\s*\"",
    r"\.navigationTitle\(\s*\"",
    r"\.accessibilityLabel\(\s*\"",
    r"\.accessibilityHint\(\s*\"",
    r"\.accessibilityValue\(\s*\"",
    r"\.accessibilityRotor\(\s*\"",
    r"accessibilityAction\(\s*named:\s*\"",
    r"prompt:\s*\"",
    r"doing:\s*\"",
]

# A count, then a conditional that adds or withholds an English suffix.
HAND_ROLLED_PLURAL = re.compile(r"""\?\s*"s?"\s*:\s*"s"|\?\s*"s"\s*:\s*"s?\"""")

# A resource built anywhere other than one of the three accessor functions.
LOOSE_RESOURCE = re.compile(r"LocalizedStringResource\(\s*[\"\\]")

LAYOUT_CONFORMANCE = re.compile(r"^(?:package |public )?struct (\w+): Layout\b", re.M)

PREVIEW_BOUNDARY = re.compile(r"^(?:// MARK: - Preview|#Preview)")

FORMAT_SPECIFIER = re.compile(r"%(?:lld|ld|d|@|lf|f)\b|%@")

INTERPOLATION = re.compile(r"\s*\\\([^()]*\)")


def swift_files(directory: str, shipped_only: bool = False) -> list[str]:
    """Every Swift file under `directory`.

    `shipped_only` drops the `Previews/` folders. They compile into the target
    but nothing in them reaches a reader: they are `PreviewProvider` catalogues
    and the dependency doubles that feed them, and their sample copy —
    "Sign In", "Row 1", "bad-email" — is there to exercise a layout. Declaring
    it in the catalog would put it in front of a translator, who would be paid
    to translate three states of a button nobody ships.

    The `#Preview` blocks inside ordinary files are dropped separately, by
    ``shipped_source``; this is the same exclusion for the files that are
    preview code from their first line.
    """
    found = []
    for base, _, names in os.walk(os.path.join(ROOT, directory)):
        if shipped_only and f"{os.sep}Previews" in base + os.sep:
            continue
        for name in sorted(names):
            if name.endswith(".swift"):
                found.append(os.path.join(base, name))
    return sorted(found)


def shipped_source(path: str) -> str:
    """The file with its comments and its preview code taken out.

    Previews are excluded because they are not shipped and are not read by
    anybody who did not write them: `AppButton("Sign In")` in a `#Preview` is a
    sample, and a sample in a catalog is an entry a translator is paid for.
    The boundary is the `// MARK: - Preview` heading or the first `#Preview`,
    whichever comes first, which is the shape every file in this package uses.

    Doc comments go with the ordinary ones, because half the `Text("…")` in
    `Sources/` are inside ```swift fences showing somebody how to call a
    component.
    """
    lines = []
    for line in open(path, encoding="utf-8").read().splitlines():
        if PREVIEW_BOUNDARY.match(line):
            break
        lines.append(strip_comment(line))
    return "\n".join(lines)


def strip_comment(line: str) -> str:
    """Drop a `//` comment, without being fooled by one inside a string."""
    in_string = False
    index = 0
    while index < len(line):
        char = line[index]
        if char == "\\" and in_string:
            index += 2
            continue
        if char == '"':
            in_string = not in_string
        elif char == "/" and not in_string and line[index + 1:index + 2] == "/":
            return line[:index]
        index += 1
    return line


def normalised(key: str) -> str:
    """A key with its argument reduced to a placeholder.

    A Swift key is written `"error.api.httpStatus \\(code)"` and the catalog
    holds `error.api.httpStatus %lld`, because `String.LocalizationValue` turns
    an interpolated `Int` into that specifier. Comparing the two means reducing
    both to the same shape.
    """
    without_interpolation = INTERPOLATION.sub(" <arg>", key)
    return FORMAT_SPECIFIER.sub("<arg>", without_interpolation).replace(" <arg>", " <arg>")


def load_catalog(relative: str, problems: list[str]) -> dict[str, dict]:
    path = os.path.join(ROOT, relative)
    if not os.path.exists(path):
        problems.append(f"{relative}: no catalog. Every target with a string needs one.")
        return {}
    document = json.load(open(path, encoding="utf-8"))
    if document.get("sourceLanguage") != "en":
        problems.append(f"{relative}: sourceLanguage must be 'en' to match Package.swift.")
    return document.get("strings", {})


def check_catalog_entries(relative: str, strings: dict[str, dict], problems: list[str]) -> None:
    for key, entry in sorted(strings.items()):
        where = f"{relative}: '{key}'"
        if not entry.get("comment"):
            problems.append(f"{where} has no comment. It is the only context a translator gets.")
        if entry.get("extractionState") != "manual":
            problems.append(
                f"{where} is not marked 'manual'. Nothing extracts strings from a "
                f"package, so every entry here is hand-written and must say so."
            )
        english = entry.get("localizations", {}).get("en")
        if not english:
            problems.append(f"{where} has no 'en' value, so it would render as its own key.")
            continue

        values = []
        if "stringUnit" in english:
            values.append(english["stringUnit"].get("value", ""))
        plural = english.get("variations", {}).get("plural")
        if plural:
            missing = {"one", "other"} - set(plural)
            if missing:
                problems.append(f"{where} is plural but has no {sorted(missing)} form.")
            values.extend(form.get("stringUnit", {}).get("value", "") for form in plural.values())
        if not values:
            problems.append(f"{where} has an 'en' entry with neither a value nor plural forms.")
            continue

        key_takes_argument = bool(FORMAT_SPECIFIER.search(key))
        value_takes_argument = any(FORMAT_SPECIFIER.search(value) for value in values)
        if key_takes_argument != value_takes_argument:
            problems.append(
                f"{where}: the key and its English value disagree about taking an "
                f"argument, so the interpolated value would be dropped or doubled."
            )
        if plural and not key_takes_argument:
            problems.append(f"{where} varies by plural but its key carries no count.")


def keys_declared_in(directory: str, accessor: str) -> dict[str, str]:
    """Every key a target looks up, mapped to where it was found."""
    pattern = re.compile(accessor + r"\(\s*\"([^\"]+)\"")
    found = {}
    for path in swift_files(directory, shipped_only=True):
        relative = os.path.relpath(path, ROOT)
        for key in pattern.findall(open(path, encoding="utf-8").read()):
            found[normalised(key)] = relative
    return found


def keys_tested_in(paths: list[str], prefixes: set[str]) -> set[str]:
    """The keys named in a suite's `everyString` table.

    Matched on the catalog's own keys rather than parsed out of the Swift,
    because the table is a list of pairs and the second half of each pair is
    the key verbatim.
    """
    tested = set()
    for relative in paths:
        text = open(os.path.join(ROOT, relative), encoding="utf-8").read()
        for literal in re.findall(r"\"([^\"]+)\"\s*\)\s*,", text):
            if literal in prefixes:
                tested.add(literal)
    return tested


def check_sources(directory: str, problems: list[str]) -> None:
    for path in swift_files(directory, shipped_only=True):
        relative = os.path.relpath(path, ROOT)
        shipped = shipped_source(path)
        raw = open(path, encoding="utf-8").read()

        for line_number, line in enumerate(shipped.splitlines(), start=1):
            for pattern in USER_FACING:
                if re.search(pattern, line):
                    problems.append(
                        f"{relative}:{line_number}: a string literal where a reader "
                        f"will see it. Declare it in the catalog and reach it through "
                        f"the target's strings namespace."
                    )
                    break
            if HAND_ROLLED_PLURAL.search(line):
                problems.append(
                    f"{relative}:{line_number}: a plural chosen in Swift. English has "
                    f"two forms and is the easy case; put the rule in the catalog's "
                    f"'variations.plural' block, where every language can answer it."
                )

        # Multi-line calls: the per-line pass above misses
        # `ContentUnavailableView(\n    "No Items",`.
        for pattern in USER_FACING:
            for match in re.finditer(pattern.replace(r"\s*", r"\s*\n?\s*"), shipped):
                line_number = shipped[: match.start()].count("\n") + 1
                already = any(f"{relative}:{line_number}:" in problem for problem in problems)
                if not already:
                    problems.append(
                        f"{relative}:{line_number}: a string literal where a reader "
                        f"will see it. Declare it in the catalog and reach it through "
                        f"the target's strings namespace."
                    )

        if LOOSE_RESOURCE.search(shipped) and not relative.endswith("Strings.swift"):
            problems.append(
                f"{relative}: builds a LocalizedStringResource outside the target's "
                f"strings file, which is the one place that passes 'bundle:'. Without "
                f"it the lookup goes to Bundle.main and resolves to the key."
            )

        for name in LAYOUT_CONFORMANCE.findall(raw):
            if "layoutDirection" not in raw:
                problems.append(
                    f"{relative}: '{name}' conforms to Layout and never reads "
                    f"layoutDirection. SwiftUI does not mirror a custom layout, so "
                    f"this one lays out left-to-right for every reader."
                )


def main() -> int:
    problems: list[str] = []
    counted = 0

    for target, (directory, catalog_path, accessor, test_paths) in TARGETS.items():
        strings = load_catalog(catalog_path, problems)
        counted += len(strings)
        check_catalog_entries(catalog_path, strings, problems)
        check_sources(directory, problems)

        declared = keys_declared_in(directory, accessor)
        catalogued = {normalised(key): key for key in strings}

        for key, where in sorted(declared.items()):
            if key not in catalogued:
                problems.append(
                    f"{where}: looks up '{key}', which {target}'s catalog does not "
                    f"declare. The lookup would resolve to the key."
                )
        for key, original in sorted(catalogued.items()):
            if key not in declared:
                problems.append(
                    f"{catalog_path}: '{original}' is declared and never looked up. A "
                    f"dead entry is a string a translator is still paid for."
                )

        tested = keys_tested_in(test_paths, set(strings))
        for key in sorted(set(strings) - tested):
            problems.append(
                f"{catalog_path}: '{key}' is in no resolution test, so nothing would "
                f"notice it resolving to its own key."
            )
        for key in sorted(tested - set(strings)):
            problems.append(f"{', '.join(test_paths)}: tests '{key}', which no catalog declares.")

    if problems:
        print("Localisation audit failures:\n", file=sys.stderr)
        for problem in sorted(set(problems)):
            print(f"  {problem}", file=sys.stderr)
        print(f"\n{len(set(problems))} problem(s).", file=sys.stderr)
        return 1

    print(f"Localisation audit passed across {counted} catalog entries in {len(TARGETS)} targets.")
    for target, (directory, _, _, _) in TARGETS.items():
        shipped = len(swift_files(directory, shipped_only=True))
        print(f"  {target:<12} {shipped} shipped source files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
