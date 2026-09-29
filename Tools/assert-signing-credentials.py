#!/usr/bin/env python3
"""Fail if code signing can reach a credential from anywhere but the CI secret
store, or if it can quietly stop needing one.

Phase 11 item 5. Signing is the one pipeline in this repository whose failure
mode is not a red build. A misconfigured signing job goes *green* — it uploads a
build, the tester gets the notification — while a distribution private key sits
in a keychain that outlived the runner, a personal Apple ID session cookie does
the authenticating, or a repository token has been written into `~/.gitconfig`
and attached to every request the job makes afterwards. Nothing about any of
that is visible in a diff, in a test run, or in the deploy log.

Four shapes of it, each verified by reintroducing the defect and watching this
script fail:

  * **A credential with a fallback.** A `MATCH_PASSWORD` read with an `||`
    default runs everywhere, including on the machine that has no secret store,
    which is the only reason anybody writes one. The default is then in git.
    This paragraph used to spell such a default out as an example and
    GitGuardian flagged the paragraph, which is the rule working from the other
    direction: a scanner cannot tell an illustration from the real thing, so
    neither this file nor any other in the repository writes one down.

  * **A credential smuggled through the shell.** The workflow this replaces ran
    `git config --global url."https://x-token:${{ secrets.MATCH_GIT_TOKEN }}@…"
    .insteadOf "https://github.com/"`. That interpolates the token into a `run:`
    block as literal text — one `set -x` away from the log — writes it in
    cleartext to `~/.gitconfig`, and rewrites *every* github.com URL for the
    rest of the job. Match reads `MATCH_GIT_BASIC_AUTHORIZATION` itself and uses
    it for one clone.

  * **An authentication path that is not the API key.** Fastlane takes the first
    credential it can find, so a missing `ASC_API_KEY_*` does not fail — it
    promotes Apple ID + password, which on a 2FA account means a long-lived
    `FASTLANE_SESSION` cookie for a *person's* account pasted into the secret
    store. An `apple_id` placeholder in the Appfile is enough to make that the
    default path.

  * **A match that can write.** A CI job holding the repository passphrase and an
    API key with write access will create a distribution certificate when it
    cannot find one. A team may hold two, so the run that creates a third revokes
    one every other machine is still signing with. `readonly` on CI is the
    difference between a job that consumes signing material and one that can
    destroy it.

And one rule that is not about a leak: the required-credential list exists in
three places — `REQUIRED_CI_CREDENTIALS` in the Fastfile, the preflight step's
`env:` block, and the `required=(…)` array it loops over — and they have to
agree. Drift in one direction is a preflight that passes a store missing a
credential the lane needs; in the other, a job that refuses to start over a
credential nothing reads.

It is deliberately a script rather than a test: it needs no toolchain, no
resolved packages and no simulator, so it runs on Linux in the lint job, reports
even when the build is broken, and is one of the few gates the scheduled agent
can run before pushing. Nothing else in this repository can check any of it —
the deploy workflow has never executed and cannot until there is an app target
to archive.

Run it with `python3 Tools/assert-signing-credentials.py [repo-root]`.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys

FASTFILE = os.path.join("fastlane", "Fastfile")
MATCHFILE = os.path.join("fastlane", "Matchfile")
APPFILE = os.path.join("fastlane", "Appfile")
DEPLOY_WORKFLOW = os.path.join(".github", "workflows", "testflight-deploy.yml")
SIGNING_DOC = os.path.join("docs", "code-signing.md")

WORKFLOW_DIR = os.path.join(".github", "workflows")

# The step whose `env:` block and `required=(…)` array have to agree with the
# Fastfile. Matched on the step's `name:`, because a workflow's job and step
# order is not something this script should pin.
PREFLIGHT_STEP = "Assert every signing credential is present and well formed"
DEPLOY_STEP = "Run Fastlane beta lane"

# What makes an environment variable name credential-shaped. Used to decide
# which workflow inputs must come from `secrets.` rather than from `vars.` or a
# literal — a team id is configuration, a key is not.
#
# Deliberately absent: "key" on its own, which would catch `MATCH_KEYCHAIN_NAME`
# and `cache-key`, and "url", which would catch `MATCH_GIT_URL`. `MATCH_GIT_URL`
# is covered by name below instead, because a private certificates repository's
# address is worth keeping out of a public log even though it is not itself a
# credential.
CREDENTIAL_WORDS = (
    "PASSWORD",
    "PASSPHRASE",
    "SECRET",
    "TOKEN",
    "API_KEY",
    "APIKEY",
    "AUTHORIZATION",
    "CREDENTIAL",
    "SLACK_URL",
    "MATCH_GIT_URL",
    "SESSION",
)

# Authentication paths that are not the App Store Connect API key. Each of these
# is fastlane reaching for a person's Apple ID instead of the team's key.
FORBIDDEN_AUTH_ENV = (
    "FASTLANE_PASSWORD",
    "FASTLANE_SESSION",
    "FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD",
    "DELIVER_PASSWORD",
    "MATCH_USERNAME",
)

# Ways a workflow can hand a credential to every later git operation instead of
# to the one command that needs it.
GIT_CREDENTIAL_SMUGGLING = (
    ("insteadOf", "rewrites every matching URL for the whole job, with the token in ~/.gitconfig"),
    ("http.extraheader", "attaches the header to every request the job makes"),
    ("credential.helper store", "writes the credential to disk in cleartext"),
)

# Signing material that must never be tracked, whatever `.gitignore` says today.
SECRET_FILE_SUFFIXES = (".p12", ".cer", ".certSigningRequest", ".mobileprovision", ".p8", ".keystore", ".jks")

# `.gitignore` has to keep ignoring them, so the next `git add -A` on a machine
# that has run `match` locally does not stage a certificate.
REQUIRED_GITIGNORE_PATTERNS = ("*.p12", "*.cer", "*.mobileprovision")


# MARK: - A very small YAML reader
#
# Enough of the format to read `env:` mappings and `run:` bodies out of a
# workflow, and nothing more. PyYAML is not in the standard library and is not
# guaranteed on a runner image, and every other audit in this repository is
# stdlib-only for the same reason.


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _block_lines(lines: list[str], start: int) -> list[str]:
    """The lines strictly more indented than `lines[start]`, up to the dedent."""
    base = _indent(lines[start])
    out: list[str] = []
    for line in lines[start + 1 :]:
        if not line.strip():
            out.append(line)
            continue
        if _indent(line) <= base:
            break
        out.append(line)
    return out


def step_env(text: str, step_name: str) -> dict[str, str] | None:
    """The `env:` mapping of the step whose `name:` is `step_name`."""
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if re.match(r"^\s*-?\s*name:\s*%s\s*$" % re.escape(step_name), line):
            body = _block_lines(lines, index)
            # The step's own keys sit at the same indent as its `name:`, so read
            # the step body starting from the line after `- name:`.
            for offset, candidate in enumerate(body):
                if candidate.strip() == "env:":
                    env: dict[str, str] = {}
                    for entry in _block_lines(body, offset):
                        match = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_-]*):\s*(.*?)\s*$", entry)
                        if match:
                            env[match.group(1)] = match.group(2)
                    return env
            return {}
    return None


def run_blocks(text: str) -> list[str]:
    """Every `run:` body in a workflow, as one string each."""
    lines = text.splitlines()
    blocks: list[str] = []
    for index, line in enumerate(lines):
        match = re.match(r"^\s*run:\s*(\S.*)?$", line)
        if not match:
            continue
        first = match.group(1) or ""
        if first in ("|", ">", "|-", ">-", "|+", ">+"):
            first = ""
        blocks.append("\n".join([first] + _block_lines(lines, index)))
    return blocks


def read(repo: str, relative: str) -> str | None:
    path = os.path.join(repo, relative)
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def is_credential_name(name: str) -> bool:
    upper = name.upper()
    return any(word in upper for word in CREDENTIAL_WORDS)


# MARK: - Rule 1: the required list agrees in all three places


def check_required_list_agrees(fastfile: str, workflow: str, problems: list[str]) -> set[str]:
    match = re.search(r"REQUIRED_CI_CREDENTIALS\s*=\s*%w\[(.*?)\]", _without_comments(fastfile), re.S)
    if not match:
        problems.append(
            f"{FASTFILE}: no `REQUIRED_CI_CREDENTIALS = %w[…]`. That list is the only "
            f"place the signing lanes say what they need; without it a missing "
            f"credential becomes a fallback authentication path rather than a failure."
        )
        return set()
    declared = set(match.group(1).split())

    env = step_env(workflow, PREFLIGHT_STEP)
    if env is None:
        problems.append(
            f"{DEPLOY_WORKFLOW}: no step named {PREFLIGHT_STEP!r}. Without the preflight, "
            f"a missing secret is discovered by a macOS job twenty minutes in."
        )
        return declared
    checked_env = set(env)

    array = re.search(r"required=\(\s*(.*?)\)", workflow, re.S)
    if not array:
        problems.append(f"{DEPLOY_WORKFLOW}: the preflight has no `required=(…)` array to loop over.")
        return declared
    checked_loop = {name for name in array.group(1).split() if re.fullmatch(r"[A-Z0-9_]+", name)}

    for label, found in (("the preflight step's env:", checked_env), ("the preflight's required=() array", checked_loop)):
        for name in sorted(declared - found):
            problems.append(
                f"{DEPLOY_WORKFLOW}: {name} is in REQUIRED_CI_CREDENTIALS but not in {label}. "
                f"The lane needs it and the preflight would let a store without it through."
            )
        for name in sorted(found - declared):
            problems.append(
                f"{DEPLOY_WORKFLOW}: {name} is in {label} but not in REQUIRED_CI_CREDENTIALS. "
                f"The deploy job refuses to start over a credential no lane reads."
            )

    return declared


# MARK: - Rule 2: the deploy job is wired from the secret store


def check_deploy_env_comes_from_secrets(workflow: str, required: set[str], problems: list[str]) -> None:
    env = step_env(workflow, DEPLOY_STEP)
    if env is None:
        problems.append(f"{DEPLOY_WORKFLOW}: no step named {DEPLOY_STEP!r}.")
        return

    for name in sorted(required - set(env)):
        problems.append(
            f"{DEPLOY_WORKFLOW}: {DEPLOY_STEP!r} does not pass {name}. The preflight "
            f"checks for it and the lane never receives it."
        )

    for name, value in sorted(env.items()):
        if not is_credential_name(name):
            continue
        if re.fullmatch(r"\$\{\{\s*secrets\.[A-Za-z0-9_]+\s*\}\}", value):
            continue
        source = "a repository variable" if "vars." in value else "a literal"
        problems.append(
            f"{DEPLOY_WORKFLOW}: {name} is set from {source} ({value}). Credentials come "
            f"from the secret store only — `vars.` and literals are readable by anyone "
            f"who can read the repository, and neither is masked in the log."
        )


# MARK: - Rule 3: no secret reaches a shell


def check_no_secret_in_run(repo: str, problems: list[str]) -> int:
    directory = os.path.join(repo, WORKFLOW_DIR)
    if not os.path.isdir(directory):
        problems.append(f"{WORKFLOW_DIR}/: not found.")
        return 0

    scanned = 0
    for entry in sorted(os.listdir(directory)):
        if not entry.endswith((".yml", ".yaml")):
            continue
        scanned += 1
        with open(os.path.join(directory, entry), encoding="utf-8") as handle:
            text = handle.read()
        for block in run_blocks(text):
            for reference in re.findall(r"\$\{\{\s*secrets\.([A-Za-z0-9_]+)\s*\}\}", block):
                problems.append(
                    f"{WORKFLOW_DIR}/{entry}: secrets.{reference} is interpolated into a `run:` "
                    f"block. The value is substituted into the script before the shell sees it, "
                    f"so a trace, a shell error echoing the line, or a command that logs its own "
                    f"arguments prints it. Pass it through `env:` and read it as a variable."
                )
            for needle, why in GIT_CREDENTIAL_SMUGGLING:
                if needle in block:
                    problems.append(
                        f"{WORKFLOW_DIR}/{entry}: `{needle}` in a `run:` block — it {why}. "
                        f"Match reads MATCH_GIT_BASIC_AUTHORIZATION from the environment and "
                        f"uses it for its own clone only."
                    )
            for hit in re.findall(r"https://[^\s\"']*:[^\s\"'/@]*@", block):
                problems.append(
                    f"{WORKFLOW_DIR}/{entry}: a URL carrying inline credentials ({hit}…). "
                    f"git writes it into its config and into the reflog."
                )
    return scanned


# MARK: - Rule 4: setup_ci precedes match, and match is read-only on CI


def check_keychain_and_readonly(fastfile: str, matchfile: str, problems: list[str]) -> None:
    # Commented out is not configured: `# setup_ci if is_ci` leaves the login
    # keychain exactly as exposed as deleting the line does.
    fastfile = _without_comments(fastfile)
    matchfile = _without_comments(matchfile) if matchfile is not None else None

    setup = fastfile.find("setup_ci")
    if setup == -1:
        problems.append(
            f"{FASTFILE}: no `setup_ci`. On a hosted runner match then imports the "
            f"distribution private key into the *login* keychain, which needs an "
            f"interactive unlock it will never get — and on a self-hosted runner leaves "
            f"a usable signing identity behind after the job ends."
        )
    else:
        for call in re.finditer(r"^\s*match\(", fastfile, re.M):
            if call.start() < setup:
                line_number = fastfile[: call.start()].count("\n") + 1
                problems.append(
                    f"{FASTFILE}:{line_number}: a `match(` call runs before `setup_ci`, "
                    f"so it has no throwaway keychain to import into."
                )

    readonly_args = re.findall(r"readonly:\s*([^\s,)]+)", fastfile)
    if not readonly_args:
        problems.append(
            f"{FASTFILE}: `match` is invoked without `readonly:`. A writable match on CI "
            f"creates a distribution certificate when it cannot find one, and a team may "
            f"hold two — so the run that creates a third revokes one that every other "
            f"machine is still signing with."
        )
    for argument in readonly_args:
        if argument != "is_ci":
            problems.append(
                f"{FASTFILE}: `readonly: {argument}` — it must be `is_ci`, with no lane "
                f"option in front of it. The only reason to pass anything else is to let "
                f"CI create signing material, which is what this rule exists to prevent."
            )

    if matchfile is not None:
        match_readonly = re.search(r"^\s*readonly\((.*)\)\s*$", matchfile, re.M)
        if not match_readonly:
            problems.append(f"{MATCHFILE}: no `readonly(…)`, so a direct `fastlane match` has no floor.")
        elif match_readonly.group(1).strip() != "FastlaneCore::Helper.ci?":
            problems.append(
                f"{MATCHFILE}: `readonly({match_readonly.group(1).strip()})` — use "
                f"`FastlaneCore::Helper.ci?`. A Matchfile is evaluated by the configuration "
                f"DSL, where the `is_ci` action does not exist, and the obvious substitute "
                f"`ENV[\"CI\"] ? true : false` is true for `CI=false`, since that is a "
                f"non-nil string."
            )


# MARK: - Rule 5: the API key is the only way in


def _without_comments(text: str) -> str:
    """Whole-line comments blanked, not removed.

    Ruby and YAML both comment with `#`, and the files this audits argue at
    length about the very constructs these rules forbid — a check reading the
    prose would fail on the paragraph explaining why, and would pass a defect
    somebody had merely commented out. Blanking rather than deleting keeps every
    line number and byte offset pointing at the real file.
    """
    return "\n".join("" if line.lstrip().startswith("#") else line for line in text.splitlines())


def check_no_apple_id_auth(repo: str, problems: list[str]) -> None:
    for relative in (FASTFILE, MATCHFILE, APPFILE, DEPLOY_WORKFLOW):
        text = read(repo, relative)
        if text is None:
            continue
        code = _without_comments(text)
        for name in FORBIDDEN_AUTH_ENV:
            if name in code:
                problems.append(
                    f"{relative}: names {name}. That is Apple ID authentication — on a "
                    f"two-factor account it only works unattended with a long-lived session "
                    f"cookie for a person's account in the secret store. The App Store "
                    f"Connect API key is the supported path and the one the lanes use."
                )

    appfile = read(repo, APPFILE)
    if appfile is not None:
        for line in appfile.splitlines():
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            if re.match(r"^apple_id\(.*\|\|", stripped) or re.match(r'^apple_id\(\s*"', stripped):
                problems.append(
                    f"{APPFILE}: `apple_id` has a default. An Apple ID here is not inert — "
                    f"the actions that accept one fall back to password or session "
                    f"authentication when the API key is missing, so a placeholder address "
                    f"makes that fallback the default path on any machine without the key."
                )

    matchfile = read(repo, MATCHFILE)
    if matchfile is not None and re.search(r"^\s*username\(", matchfile, re.M):
        problems.append(
            f"{MATCHFILE}: `username(…)`. Match authenticates with the API key the Fastfile "
            f"passes it; a username here is the Apple ID fallback wearing a different name."
        )


# MARK: - Rule 6: no credential has a local default


def check_no_credential_fallbacks(repo: str, problems: list[str]) -> int:
    scanned = 0
    for relative in (FASTFILE, MATCHFILE, APPFILE):
        text = read(repo, relative)
        if text is None:
            problems.append(f"{relative}: not found.")
            continue
        scanned += 1
        for line_number, line in enumerate(text.splitlines(), start=1):
            if line.strip().startswith("#"):
                continue
            for name, fallback in re.findall(r'ENV\[\s*"([A-Z0-9_]+)"\s*\]\s*\|\|\s*(\S+)', line):
                if is_credential_name(name):
                    problems.append(
                        f"{relative}:{line_number}: {name} falls back to {fallback}. A credential "
                        f"with a default runs on the machine that has no secret store, which is "
                        f"the only reason anybody writes one — and the value is then in git."
                    )
    return scanned


# MARK: - Rule 7: no signing material is tracked


def check_no_tracked_secrets(repo: str, problems: list[str]) -> None:
    try:
        listing = subprocess.run(
            ["git", "-C", repo, "ls-files", "-z"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        problems.append(f"could not list tracked files ({error}); the signing-material check did not run.")
        return

    for path in listing.split("\0"):
        if path and path.lower().endswith(SECRET_FILE_SUFFIXES):
            problems.append(
                f"{path}: signing material is tracked in git. Certificates and profiles come "
                f"from the match repository; a private key committed here is a rotation, not "
                f"a revert."
            )

    gitignore = read(repo, ".gitignore") or ""
    ignored = {line.strip() for line in gitignore.splitlines()}
    for pattern in REQUIRED_GITIGNORE_PATTERNS:
        if pattern not in ignored:
            problems.append(
                f".gitignore: no `{pattern}` rule. `match` leaves these in the working tree "
                f"on a developer's machine, where the next `git add -A` stages them."
            )


# MARK: - Rule 8: the secret store is documented


def check_documented(repo: str, required: set[str], problems: list[str]) -> None:
    doc = read(repo, SIGNING_DOC)
    if doc is None:
        problems.append(
            f"{SIGNING_DOC}: not found. A secret store nobody can reconstruct is a "
            f"single point of failure with no runbook: the certificate expires in a year "
            f"whether or not anyone wrote down where it came from."
        )
        return
    for name in sorted(required):
        if name not in doc:
            problems.append(f"{SIGNING_DOC}: does not document {name}, which the lanes require.")
    if not re.search(r"^#+ .*(rotat|revok)", doc, re.M | re.I):
        problems.append(
            f"{SIGNING_DOC}: no rotation or revocation section. Every credential here "
            f"expires or leaks eventually, and the procedure is the half of 'credentials "
            f"from the secret store' that a list of names does not cover."
        )


def main() -> int:
    repo = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    problems: list[str] = []

    fastfile = read(repo, FASTFILE)
    workflow = read(repo, DEPLOY_WORKFLOW)
    matchfile = read(repo, MATCHFILE)

    if fastfile is None:
        print(f"Signing-credential audit failed:\n\n  {FASTFILE}: not found under {repo}.")
        return 1
    if workflow is None:
        print(
            f"Signing-credential audit failed:\n\n  {DEPLOY_WORKFLOW}: not found. The deploy "
            f"workflow is where the secret store is wired to the lanes; a template outside "
            f"`.github/workflows/` is not a pipeline."
        )
        return 1

    required = check_required_list_agrees(fastfile, workflow, problems)
    check_deploy_env_comes_from_secrets(workflow, required, problems)
    workflows = check_no_secret_in_run(repo, problems)
    check_keychain_and_readonly(fastfile, matchfile, problems)
    check_no_apple_id_auth(repo, problems)
    fastlane_files = check_no_credential_fallbacks(repo, problems)
    check_no_tracked_secrets(repo, problems)
    check_documented(repo, required, problems)

    if problems:
        print("Signing-credential audit failed:\n")
        for problem in problems:
            print(f"  {problem}")
        print(f"\n{len(problems)} problem(s).")
        return 1

    print(
        f"Signing-credential audit passed across {fastlane_files} fastlane file(s) "
        f"and {workflows} workflow(s)."
    )
    print(f"  credentials: {len(required)} required, agreeing in the Fastfile and both preflight lists")
    print("  source: every credential-shaped input comes from secrets., never vars. or a literal")
    print("  shell: no secret is interpolated into a run: block, and nothing writes one to git config")
    print("  keychain: setup_ci precedes every match, and match is read-only on CI")
    print("  auth: the App Store Connect API key is the only path — no Apple ID, password or session")
    print(f"  docs: {SIGNING_DOC} documents each credential and how to rotate it")
    return 0


if __name__ == "__main__":
    sys.exit(main())
