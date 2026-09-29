# Code signing

Signing is the one pipeline in this repository whose failure mode is not a red
build. A misconfigured signing job goes green — it uploads a build, the tester
gets the notification — while a distribution private key sits in a keychain that
outlived the runner, a personal Apple ID session cookie does the authenticating,
or a repository token has been written into `~/.gitconfig` and attached to every
request the job makes afterwards. None of that is visible in a diff, in a test
run, or in the deploy log.

So the arrangement below is not "match plus some secrets". It is a set of
decisions about *what cannot happen*, and `Tools/assert-signing-credentials.py`
is what keeps each of them true as the pipeline changes. That script runs in the
lint job on every pull request; it is the only gate in this repository that can
see any of this.

## What holds what

| Where | Holds | Read by |
| --- | --- | --- |
| App Store Connect | the API key's public half | — |
| The GitHub environment `testflight` | every credential below | `preflight` and `beta` in `.github/workflows/testflight-deploy.yml` |
| The match repository (`MATCH_GIT_URL`) | the distribution certificate and profiles, encrypted | `fastlane match`, read-only on CI |
| This repository | nothing | — |

That last row is the claim. There is no `.env`, no committed profile, no
certificate, and no default anywhere in `fastlane/` that stands in for a missing
credential — a credential with a fallback runs on the machine that has no secret
store, which is the only reason anybody writes one, and the value is then in git.

## The credentials

The list lives in `REQUIRED_CI_CREDENTIALS` in `fastlane/Fastfile`. Every one is
checked for presence *and shape* by the `preflight` job before a macOS runner is
started, because the alternative is discovering a typo twenty minutes into a
build.

### `ASC_API_KEY_ID`, `ASC_API_KEY_ISSUER_ID`, `ASC_API_KEY_CONTENT`

The App Store Connect API key — the only authentication path the lanes have.

1. App Store Connect → Users and Access → Integrations → App Store Connect API.
2. Create a key with the **App Manager** role. Developer is not enough to upload
   a build; Admin is more than this needs.
3. Download the `.p8`. **Apple serves it once.** There is no second download, so
   a key you failed to save is a key you revoke and replace.
4. Copy the Key ID and the Issuer ID from the same page.

`ASC_API_KEY_CONTENT` is the file **base64-encoded**, not pasted raw:

```sh
base64 -i AuthKey_XXXXXXXXXX.p8 | tr -d '\n'
```

The Fastfile passes `is_key_content_base64: true` to match. A PEM is multi-line,
and a multi-line secret survives a GitHub `env:` block but not a `.env` file, a
Jenkins credential binding, or anybody's copy-paste; base64 is one line
everywhere. Pasting the raw `.p8` is the single most common way this pipeline is
misconfigured, which is why the preflight decodes the value and looks for
`-----BEGIN PRIVATE KEY-----` before anything else runs.

Why a key rather than an Apple ID: fastlane takes the first credential it can
find, so a *missing* key does not fail — it promotes Apple ID and password
authentication, which on a two-factor account (i.e. every account since 2019)
only works unattended if a long-lived `FASTLANE_SESSION` cookie is pasted into
the secret store. That cookie is a full-privilege bearer token for a person's
account, it expires without warning, and it is exactly what this item exists to
rule out. The audit fails on any mention of it, and `fastlane/Appfile`
deliberately carries no `apple_id` placeholder, because a placeholder address is
enough to make that fallback the default path on any machine without the key.

### `MATCH_GIT_URL`

The git repository holding the encrypted certificate and profiles. Private, and
separate from this one: everyone who can read it can, with the passphrase,
sign as your team.

### `MATCH_GIT_BASIC_AUTHORIZATION`

Base64 of `user:token` for cloning that repository:

```sh
printf '%s' 'git:<your fine-grained PAT>' | base64 | tr -d '\n'
```

Use a token scoped to the certificates repository alone — a fine-grained PAT
with **Contents: read**, or a deploy key's equivalent. Read is sufficient
because match is read-only on CI.

Match reads this variable itself and uses it for its own clone only. It is
deliberately *not* named in `fastlane/Matchfile`: a value never assigned to a
variable there cannot be echoed by a lane or printed by `fastlane env`.

The predecessor of this file did it the other way, with

```sh
git config --global url."https://x-token:$TOKEN@github.com/".insteadOf "https://github.com/"
```

which writes the token in cleartext into `~/.gitconfig` and rewrites *every*
github.com URL for the rest of the job — `swift package resolve`, a tag push,
any script that clones anything. It also interpolated the secret into a `run:`
block, where it reaches the shell as literal text: one `set -x` from the log.
The audit fails on `insteadOf`, on `http.extraheader`, on a URL carrying inline
credentials, and on any `${{ secrets.* }}` inside a `run:` block.

### `MATCH_PASSWORD`

The passphrase the match repository is encrypted with. Generate it at random and
store it nowhere but the secret store and your team's password manager. Losing it
means `match nuke` and a fresh certificate; leaking it means the same, faster.

### Not credentials

`APPLE_TEAM_ID`, `APP_STORE_CONNECT_TEAM_ID`, `APP_BUNDLE_ID` and `SCHEME` are
configuration. The first two are kept as secrets out of habit rather than
necessity; the last two come from repository variables. `SLACK_URL` is a webhook
and is treated as a credential by the audit.

## Why match is read-only on CI

`sync_signing` passes `readonly: is_ci` and does not accept a lane option in
front of it. A CI job holding the repository passphrase and an API key with write
access will happily *create* a distribution certificate when it cannot find one —
and an Apple team may hold two, so the run that creates a third revokes one that
every other machine is still signing with. Read-only is the difference between a
job that consumes signing material and one that can destroy it.

`fastlane/Matchfile` sets the same floor for anyone running `fastlane match`
directly, via `FastlaneCore::Helper.ci?`. Not `ENV["CI"] ? true : false`, which
is true for `CI=false`, because that is a non-nil string.

Creating or renewing signing material is a deliberate act on a developer machine:

```sh
bundle exec fastlane match appstore          # readonly is false off CI
```

## Why `setup_ci`

`before_all` calls `setup_ci` when `is_ci`. It creates a throwaway keychain,
unlocks it for the length of the job, and points `MATCH_KEYCHAIN_NAME` and
`MATCH_KEYCHAIN_PASSWORD` at it. Without it match imports the distribution
private key into the **login** keychain, which on a GitHub-hosted runner needs an
interactive unlock it will never get, and on a self-hosted runner leaves a usable
signing identity behind after the job ends — available to the next job that lands
on that machine.

It is in `before_all` rather than inside `sync_signing` so that a lane added
later cannot forget it, and the audit checks that no `match(` call precedes it.

## Rotation and revocation

**Routine rotation — the API key, every 12 months.** Issue a new key, set the
three `ASC_API_KEY_*` secrets in one edit, run the workflow manually to confirm,
then revoke the old key in App Store Connect. Revoking first gives you a window
in which nothing can ship.

**Routine rotation — the distribution certificate, before it expires.** Apple
issues them for one year and gives no notice. On a developer machine:

```sh
bundle exec fastlane match nuke distribution   # revokes and clears the repo
bundle exec fastlane match appstore            # issues and stores a new one
```

Everything signed with the old certificate keeps working; TestFlight builds
already uploaded are unaffected. Do it with at least a week in hand, because
`match nuke` revokes *everyone's* distribution certificate at once and every
other machine has to re-run `match appstore` afterwards.

**On a leaked `MATCH_PASSWORD` or a leaked clone of the match repository.**
Assume the certificate is compromised, because it is. Rotate the passphrase and
the certificate together — `match nuke distribution`, a new random passphrase in
the secret store, then `match appstore` — and rotate
`MATCH_GIT_BASIC_AUTHORIZATION` as well, since the same disclosure usually
carries both.

**On a leaked `ASC_API_KEY_CONTENT`.** Revoke the key in App Store Connect
immediately; it is not tied to the certificate and needs no match work. A revoked
key fails every call, so the next deploy fails loudly rather than silently doing
the wrong thing.

**On a leaked `MATCH_GIT_BASIC_AUTHORIZATION`.** Revoke the token. If it was
scoped to the certificates repository with read access, as above, the exposure is
one encrypted repository whose passphrase the holder does not have; if it was a
broader token, treat every repository it could reach as exposed too. That
difference is the whole argument for scoping it.

**If a credential is ever committed to this repository**, rotating it comes
before any other work, including removing it from history. It is on GitHub's
servers, in every fork, and in every clone from the moment of the push.

## What has never run

The `beta` job has never executed and cannot as the repository stands. There is
no app target: `Package.swift` declares a library, there is no `.xcodeproj` or
`.xcworkspace`, and `build_app` has nothing to archive. The `SCHEME` and
`WORKSPACE` constants at the top of the Fastfile name things that do not exist
here.

So what is real today is the credential wiring and the audit over it — which is
the half of signing that a template gets wrong, and the half no other gate in
this repository can see. What an app target would still have to add:

* An Xcode project or workspace with an app target whose bundle identifier
  matches `APP_BUNDLE_ID`, and a real `SCHEME`.
* A first `bundle exec fastlane match appstore` on a developer machine, which is
  what puts anything in the match repository at all — CI is read-only and cannot
  bootstrap it.
* `Gemfile.lock`, which `.gitignore` currently excludes. `bundler-cache: true`
  resolves fastlane fresh on every run without one, so the gem that handles your
  certificates is whatever `~> 2.225` means that day.
