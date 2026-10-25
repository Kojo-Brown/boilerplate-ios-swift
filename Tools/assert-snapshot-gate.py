#!/usr/bin/env python3
"""Fail if the snapshot diff gate is not in a state that can fail.

Phase 12 item 3 added a snapshot suite: seventeen committed PNGs, a renderer,
a pixel comparison, and a CI job that runs them. Everything in that sentence is
checked by the suite itself except the part that matters most — the *committed
state* — and a snapshot gate has an unusually quiet way of switching itself off.

  * **Record mode left on.** A run that records writes the pixels it has just
    rendered over the pixels it was supposed to be checking, and then passes.
    Every case. Forever. Nothing about the run looks different: the job is
    green, the test names scroll past, and the only evidence is a diff in a
    directory of binary files that reviewers skim. The switch is a file, which
    is what lets this script answer "is it on *right now*" rather than only
    "who is allowed to turn it on".
  * **An orphaned golden.** Rename or delete a subject and its PNG stays
    behind, comparing against nothing. The gate still passes, with one fewer
    thing held still than the directory suggests.
  * **A subject with no golden.** The mirror image, and the one that at least
    fails — but only on a machine with a simulator, which the scheduled agent
    that maintains this repository is not.
  * **A gate nothing runs.** This repository has shipped exactly that before:
    `workflow-templates/ios-ci.yml` carried a SwiftLint step that printed
    "skipping" and exited 0 (see the note at the top of `.github/workflows/
    ci.yml`). A test target no CI job names is the same defect in a newer file.
  * **A golden that is not an image.** A truncated write or an LFS pointer
    committed by accident decodes to nothing, and "no recorded snapshot" reads
    like a first run rather than like a corrupted one.

The inventory check is deliberately split in two, because neither half can see
the other's side. This script compares the *directory* against the inventory in
`environment.json`; it runs on Linux, needs no toolchain, no resolved packages
and no simulator. `SnapshotGateTests.environmentIsRecorded` compares that same
inventory against `SnapshotCase.all`; only a compiled test can. Together they
tie the files on disk to the catalogue in the source. Either one alone is a
rubber stamp.

Three rules read workflow YAML as text rather than parsing it, because PyYAML
is not in the standard library and this script is meant to run anywhere python3
does. They therefore check for exact spellings, named in the failure messages:
a legitimate reformat of those lines fails this script, which is the right
direction for a check on a gate.

Usage:  python3 Tools/assert-snapshot-gate.py [repo-root]
Exit:   0 when the gate is in a state that can fail, 1 otherwise.
"""
from __future__ import annotations

import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

TESTS = os.path.join("Tests", "SnapshotTests")
GOLDENS = os.path.join(TESTS, "__Snapshots__")
CATALOGUE = os.path.join(TESTS, "SnapshotCatalogue.swift")
RENDERER = os.path.join(TESTS, "SnapshotRenderer.swift")
STORE = os.path.join(TESTS, "SnapshotStore.swift")
CI = os.path.join(".github", "workflows", "ci.yml")
RECORD = os.path.join(".github", "workflows", "record-snapshots.yml")
DOCS = os.path.join("docs", "snapshot-testing.md")
GITIGNORE = ".gitignore"

ENVIRONMENT = "environment.json"
# The directory is documentation plus evidence; nothing else belongs in it.
ALLOWED_NON_IMAGES = {"README.md", ENVIRONMENT}

# The failure artifacts a local run writes. Gitignored, because the one thing
# worse than no diff image is a stale one committed beside the goldens.
FAILURE_DIRECTORY = "SnapshotFailures"

# The record switch: a file at the repository root whose presence turns the
# suite from checking the goldens into overwriting them. A file rather than an
# environment variable because nothing else reaches a test bundle inside a
# simulator (see `SnapshotStore.isRecording`), and the happy consequence is that
# this script can check the switch's state rather than only who sets it.
RECORD_SWITCH = ".snapshot-record"

# `SnapshotAppearance.fileNameSuffix` leaves the standard type size out of a
# file name, so `<subject>.<scheme>` means the standard size and
# `<subject>.<scheme>.<size>` means any other.
ELIDED_TYPE_SIZE = "standard"

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"

# `case foo = "bar"`, or `case foo` whose raw value is its own name.
ENUM_CASE = re.compile(r"^\s*case\s+(\w+)\s*(?:=\s*\"([^\"]+)\")?\s*$")


def read(path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def without_comments(text: str) -> str:
    """YAML with whole-line comments dropped.

    So that the rules below read what a workflow *does* rather than what its
    comments say about it — this file's own name appears in several of those
    comments, and a check that could not tell the two apart would fail on the
    documentation it asked for.
    """
    return "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )


def enum_raw_values(source: str, name: str) -> list[str]:
    """The raw values of a `String`-backed enum, in declaration order.

    Brace counting rather than a single regex, because every one of these enums
    carries doc comments with braces in them and computed properties below the
    cases.
    """
    opening = re.search(rf"enum\s+{name}\s*:\s*String[^{{]*{{", source)
    if not opening:
        return []
    depth = 0
    values: list[str] = []
    for line in source[opening.end() - 1:].splitlines():
        stripped = line.split("//", 1)[0]
        if depth == 1:
            found = ENUM_CASE.match(stripped)
            if found:
                values.append(found.group(2) or found.group(1))
        depth += stripped.count("{") - stripped.count("}")
        if depth == 0:
            break
    return values


def check_directory(root: str, problems: list[str]) -> list[str]:
    """Rule 1: the goldens directory holds images, a manifest and a readme.

    Returns the image names, without the extension.
    """
    directory = os.path.join(root, GOLDENS)
    if not os.path.isdir(directory):
        problems.append(
            f"{GOLDENS}: not a directory. The gate compares against recorded "
            f"images; with none committed it fails every case, which is not a "
            f"gate either. See docs/snapshot-testing.md for the record lane."
        )
        return []

    names: list[str] = []
    for entry in sorted(os.listdir(directory)):
        path = os.path.join(directory, entry)
        if os.path.isdir(path):
            problems.append(f"{GOLDENS}/{entry}: a subdirectory. The goldens are one flat list.")
            continue
        if entry.endswith(".png"):
            names.append(entry[: -len(".png")])
            continue
        if entry not in ALLOWED_NON_IMAGES:
            problems.append(
                f"{GOLDENS}/{entry}: not a golden, not the manifest and not the "
                f"readme. Anything else here is either a stray failure artifact "
                f"or a recording somebody renamed by hand."
            )
    return names


def check_images(root: str, names: list[str], problems: list[str]) -> None:
    """Rule 2: every golden is a non-empty PNG."""
    for name in names:
        path = os.path.join(root, GOLDENS, f"{name}.png")
        with open(path, "rb") as handle:
            head = handle.read(len(PNG_MAGIC))
        if head != PNG_MAGIC:
            problems.append(
                f"{GOLDENS}/{name}.png: not a PNG. A golden that cannot be "
                f"decoded reports as 'never recorded', which reads like a first "
                f"run rather than like a truncated write or an LFS pointer."
            )


def check_manifest(root: str, names: list[str], problems: list[str]) -> None:
    """Rules 3 and 4: the manifest is complete, and it is the directory.

    The inventory is the half of the gate's bookkeeping that is visible from a
    machine with no simulator — see the module docstring.
    """
    path = os.path.join(root, GOLDENS, ENVIRONMENT)
    if not os.path.isfile(path):
        problems.append(
            f"{GOLDENS}/{ENVIRONMENT}: missing. The goldens then carry no "
            f"provenance, so a failing comparison cannot say whether the "
            f"runtime moved or the code did, and the diff job has no runtime "
            f"to ask for."
        )
        return
    try:
        manifest = json.loads(read(path))
    except json.JSONDecodeError as error:
        problems.append(f"{GOLDENS}/{ENVIRONMENT}: not valid JSON ({error}).")
        return

    for key in ("iosVersion", "renderer"):
        value = manifest.get(key)
        if not isinstance(value, str) or not value.strip():
            problems.append(f"{GOLDENS}/{ENVIRONMENT}: {key} must be a non-empty string.")
    scale = manifest.get("scale")
    if not isinstance(scale, (int, float)) or isinstance(scale, bool) or scale <= 0:
        problems.append(f"{GOLDENS}/{ENVIRONMENT}: scale must be a positive number.")

    inventory = manifest.get("cases")
    if not isinstance(inventory, list) or not all(isinstance(item, str) for item in inventory):
        problems.append(
            f"{GOLDENS}/{ENVIRONMENT}: cases must be the list of golden file "
            f"names the catalogue declares. Without it this script can only "
            f"check that the directory is tidy, not that it is complete."
        )
        return

    recorded = set(inventory)
    present = set(names)
    for orphan in sorted(present - recorded):
        problems.append(
            f"{GOLDENS}/{orphan}.png: recorded, but not in the manifest's "
            f"inventory — nothing compares against it. A renamed or deleted "
            f"subject leaves exactly this behind, and the suite goes on passing "
            f"with one fewer thing held still."
        )
    for missing in sorted(recorded - present):
        problems.append(
            f"{GOLDENS}/{missing}.png: in the manifest's inventory and not on "
            f"disk. Re-record, and commit the image."
        )


def check_names(root: str, names: list[str], problems: list[str]) -> None:
    """Rule 5: every golden's name decomposes into things the code declares."""
    subjects = set(enum_raw_values(read(os.path.join(root, CATALOGUE)), "SnapshotSubject"))
    renderer = read(os.path.join(root, RENDERER))
    schemes = set(enum_raw_values(renderer, "SnapshotScheme"))
    sizes = set(enum_raw_values(renderer, "SnapshotTypeSize"))

    if not subjects or not schemes or not sizes:
        problems.append(
            f"{CATALOGUE} / {RENDERER}: could not read the subject, scheme and "
            f"type-size vocabularies out of the source, so the file names below "
            f"cannot be checked against anything."
        )
        return
    if ELIDED_TYPE_SIZE not in sizes:
        problems.append(
            f"{RENDERER}: SnapshotTypeSize no longer has a `{ELIDED_TYPE_SIZE}` "
            f"case. It is the one a golden's file name leaves out, so this "
            f"script and `SnapshotAppearance.fileNameSuffix` have stopped "
            f"agreeing about what a name means."
        )

    used_subjects: set[str] = set()
    for name in sorted(names):
        parts = name.split(".")
        if len(parts) not in (2, 3) or parts[0] not in subjects or parts[1] not in schemes:
            problems.append(
                f"{GOLDENS}/{name}.png: not a name the catalogue can produce. "
                f"Expected <subject>.<scheme>[.<type size>] with a subject from "
                f"SnapshotSubject and a scheme from SnapshotScheme."
            )
            continue
        if len(parts) == 3 and (parts[2] not in sizes or parts[2] == ELIDED_TYPE_SIZE):
            problems.append(
                f"{GOLDENS}/{name}.png: `{parts[2]}` is not a type size a file "
                f"name can carry. The standard size is spelled by leaving it out."
            )
            continue
        used_subjects.add(parts[0])

    for subject in sorted(subjects - used_subjects):
        problems.append(
            f"{CATALOGUE}: subject `{subject}` has no recorded golden, so the "
            f"gate holds nothing still for it. Record it — and look at the "
            f"image, because a subject that renders blank records just as well "
            f"as one that renders."
        )


def check_record_switch(root: str, problems: list[str]) -> None:
    """Rule 6: record mode is off, one place decides it, and CI is not it.

    The first of these is the only rule here that is about *now* rather than
    about the committed state, and it is the most useful one: a working copy
    with the switch left on records over its goldens on every run and passes.
    """
    if os.path.exists(os.path.join(root, RECORD_SWITCH)):
        problems.append(
            f"{RECORD_SWITCH} exists, so the suite is in record mode: it will "
            f"overwrite every golden it was meant to compare against, and pass. "
            f"Delete it. It is gitignored, so this is a leftover from a local "
            f"recording rather than something committed."
        )

    readers = []
    for base, directories, files in os.walk(os.path.join(root, TESTS)):
        directories[:] = [name for name in directories if name != "__Snapshots__"]
        for name in sorted(files):
            if name.endswith(".swift") and f'"{RECORD_SWITCH}"' in read(os.path.join(base, name)):
                readers.append(os.path.relpath(os.path.join(base, name), root))
    if readers != [STORE]:
        problems.append(
            f"{RECORD_SWITCH} is named in {readers or 'no file'}; it must be "
            f"named in exactly one place, {STORE}. A second switch is how a run "
            f"ends up recording in the job that was supposed to be verifying, "
            f"and a gate that records always passes."
        )

    if RECORD_SWITCH in without_comments(read(os.path.join(root, CI))):
        problems.append(
            f"{CI}: names {RECORD_SWITCH}. The diff gate must never run in "
            f"record mode: it would overwrite the images it is comparing "
            f"against and then report success."
        )
    # The exact spelling, not the name anywhere in the file: the lane also
    # deletes the switch afterwards and explains it in a comment, so "names it"
    # is satisfied by a lane that no longer turns it on.
    if f"touch {RECORD_SWITCH}" not in without_comments(read(os.path.join(root, RECORD))):
        problems.append(
            f"{RECORD}: has no `touch {RECORD_SWITCH}` step, so the record lane "
            f"records nothing and the gate can only ever be bootstrapped by "
            f"hand on a Mac."
        )


def check_ci_wiring(root: str, problems: list[str]) -> None:
    """Rule 7: something runs the gate, and the main suite does not."""
    workflow = without_comments(read(os.path.join(root, CI)))
    if "-only-testing:SnapshotTests" not in workflow:
        problems.append(
            f"{CI}: no job runs `-only-testing:SnapshotTests`. A test target "
            f"nothing runs is this repository's oldest CI defect in a newer "
            f"file: the gate is present, committed, documented, and never once "
            f"consulted."
        )
    if "-skip-testing:SnapshotTests" not in workflow:
        problems.append(
            f"{CI}: the main test job does not skip SnapshotTests. The gate "
            f"needs the runtime its goldens were recorded on; that job takes "
            f"the newest one the SDK can drive, so a runtime bump on the runner "
            f"image would report as a failure of the whole suite."
        )


def check_record_lane_safety(root: str, problems: list[str]) -> None:
    """Rule 8: the lane that can push commits cannot push them to `main`."""
    workflow = without_comments(read(os.path.join(root, RECORD)))
    if "branches: ['snapshots/**']" not in workflow:
        problems.append(
            f"{RECORD}: the push trigger is not `branches: ['snapshots/**']`. "
            f"This workflow has `contents: write` and commits to the ref it ran "
            f"on, so the set of refs that can trigger it is the whole of what "
            f"bounds it."
        )
    if "github.ref_name == 'main'" not in workflow:
        problems.append(
            f"{RECORD}: nothing refuses to record on the default branch. A "
            f"`workflow_dispatch` can name any ref, including main."
        )


def check_gitignore(root: str, problems: list[str]) -> None:
    """Rule 9: neither the switch nor a failure artifact can be committed."""
    ignored = read(os.path.join(root, GITIGNORE)).splitlines()
    if not any(line.strip() == RECORD_SWITCH for line in ignored):
        problems.append(
            f"{GITIGNORE}: does not ignore {RECORD_SWITCH}. Committing the "
            f"record switch would put every later run into record mode, which "
            f"is the one failure of a snapshot gate that reports success."
        )
    if not any(line.strip().rstrip("/") == FAILURE_DIRECTORY for line in ignored):
        problems.append(
            f"{GITIGNORE}: does not ignore {FAILURE_DIRECTORY}/. A failing run "
            f"writes the recorded image, the rendered one and their overlay "
            f"there, and a committed `actual.png` beside the goldens is how one "
            f"of them gets mistaken for the other."
        )


def check_docs(root: str, names: list[str], problems: list[str]) -> None:
    """Rule 10: the page documents every subject the gate holds still."""
    path = os.path.join(root, DOCS)
    if not os.path.isfile(path):
        problems.append(
            f"{DOCS}: not found. A directory of binary files needs a page "
            f"saying what each one is of, how to re-record it, and what to look "
            f"at before trusting the result."
        )
        return
    page = read(path)
    subjects = sorted({name.split(".")[0] for name in names})
    for subject in subjects:
        if subject not in page:
            problems.append(
                f"{DOCS}: does not mention `{subject}`, which has a recorded "
                f"golden. The page is the only place a reader can find out what "
                f"a snapshot is a picture of."
            )


def main(argv: list[str]) -> int:
    root = os.path.abspath(argv[1]) if len(argv) > 1 else REPO
    problems: list[str] = []

    names = check_directory(root, problems)
    check_images(root, names, problems)
    check_manifest(root, names, problems)
    check_names(root, names, problems)
    check_record_switch(root, problems)
    check_ci_wiring(root, problems)
    check_record_lane_safety(root, problems)
    check_gitignore(root, problems)
    check_docs(root, names, problems)

    if problems:
        print("Snapshot gate violations:\n", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print(f"\n{len(problems)} violation(s).", file=sys.stderr)
        return 1

    print(
        f"Snapshot gate audit passed: {len(names)} recorded golden(s), "
        f"inventory and directory agree, record mode is off, and CI runs the "
        f"gate."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
