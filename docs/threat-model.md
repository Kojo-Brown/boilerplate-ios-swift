# Jailbreak and tamper heuristics, and the threat model they belong to

Phase 11 item 4: *Jailbreak and tamper heuristics with a documented threat
model.*

The threat model is not an appendix to the heuristics. It is the part that
decides whether they are worth shipping, what they may be allowed to do, and —
most of all — what the app must **not** do with them. Written the other way
round, this feature reliably becomes an app that refuses to launch on somebody's
legitimate phone while the attacker it was aimed at edits one conditional out of
a binary they decrypted last week.

So this page starts with the limits, because everything else follows from them.

## What these heuristics cannot do

**They cannot detect a device that is hiding from them.** Every check runs
inside the process it is judging, using APIs that a resident hooking framework
has already replaced. `access(2)` can be answered. `sysctl` can be answered. The
dyld image list can be filtered. A jailbreak whose author cared about detection
— which is all of the widely used ones, and the explicit purpose of tweaks like
Shadow and Choicy — presents a device that passes every check here. There is no
in-process test that distinguishes that device from an untouched one, and
`IntegrityPosture.noSignals` is named the way it is because of that: it means
"every heuristic that could run came back negative", not "this device is clean".

**They cannot survive being patched out.** The strongest signal in this file is
still a branch in a binary. On a device where the attacker has the binary, the
check is a `cmp` they can invert. This is the reason the mitigation is small: a
mechanism that can be removed should not be load-bearing.

**They cannot be trusted by a server on their own.** A client reporting "I am
fine" is a client saying what it was told to say. A report is worth something
only when the channel carrying it proves what produced it, which is what App
Attest is for — see `docs/app-attest.md`. That is the half that can actually act
on this, and it is not built yet; see *Not done* below.

**They cannot be calibrated from here.** Nobody has run these against a
population of real installs, so the false-positive rate of every signal below is
an argument rather than a measurement. That is a second reason the shipped
mitigation is one whose false positive costs a password entry.

## What they are worth anyway

They raise the cost of the casual case, which is most of the volume: an
off-the-shelf repackage, a tweak someone installed without thinking about this
app, a cracked build passed around a forum, an automated scraper running on a
jailbroken farm. None of those is trying to evade detection specifically, and all
of them are visible here.

And they turn "our app runs on compromised devices" from an unknown into a
number — which is the part a team can act on, and the reason the report is
carried on `AppContainer` and logged whatever it says.

## The seven signals

Each is a case of `IntegritySignal`, and the wire name is what a log line and a
future server-side report carry.

### `jailbreak_artefact_on_disk` — strong, jailbreak

A path from `SystemIntegrityProbe.artefactPaths` is readable. The list covers
three generations, because a check that only knows about `/Applications/Cydia.app`
has not been updated since 2019: the classic `/Applications` entries, the
Substrate-era `/Library/MobileSubstrate` and `/usr/lib` payloads, and the
rootless layout under `/var/jb` that palera1n and Dopamine use and that most
published snippets miss entirely.

It uses `access(2)` rather than `FileManager.fileExists`, which is the same
question through two more layers of dispatch — one of them Objective-C, and
therefore swizzlable without any hooking at all.

`/bin/sh` and `/bin/bash` are deliberately **not** on the list. They are on every
Mac, so including them would make this fire on every simulator run.

### `filesystem_writable_outside_container` — strong, jailbreak

A directory outside the app container reports as writable. The stronger of the
two filesystem heuristics, because it is the kernel answering about its own
enforcement rather than a file being absent: under an intact sandbox every one of
these is `EPERM` no matter what is installed.

It asks `access(2)` and writes nothing. The published form of this check creates
a file outside the container and deletes it, which leaves evidence of the probe
on the device — and the path where the cleanup fails is exactly the compromised
device the check exists for. `Tools/assert-integrity-heuristics.py` fails if the
probe grows a write.

### `injected_library_loaded` — strong, tamper

A loaded image path matches a code-injection framework. This is the strongest
thing available from inside the process, and the only heuristic here that is
about *this app* rather than about the device: a tweak that hooks this process has
to be mapped into this process to do it.

The markers are matched lowercased against every entry in the dyld image list.
The bare word `substitute` is excluded on purpose in favour of
`libsubstitute` and `substitute-inserter`: a marker that is also an ordinary
English word will one day match a framework path for reasons unrelated to code
injection, and a false positive on this signal is the one that withholds a
credential.

### `debugger_attached` — moderate, instrumentation

`sysctl` reports `P_TRACED` on this process. Only assessed on a distribution
build — on a development build it is the developer's own workflow, and a
permanently green check in front of every developer is how a suite of heuristics
becomes decoration.

`ptrace(PT_DENY_ATTACH)` is the other thing this is usually written as, and it is
a different feature: denying attachment is a *mitigation*, and a rejected one. It
is a private call, it breaks every legitimate debugging session including the
crash reporter's, and a jailbroken device removes it. This asks and reports.

### `bundle_identifier_mismatch` — strong, tamper

The running bundle identifier is not `AppContainer.expectedBundleIdentifier`.
This is what a repackaged app looks like: the binary was re-signed under an
identifier the attacker controls, because the original belongs to a team they do
not have.

The expected value is a literal in the composition root and never
`Bundle.main.bundleIdentifier`, which would be a comparison of a value against
itself — a check that can never fail, and the shape a surprising amount of
shipped anti-repackaging code takes.

The cost of that is real and is stated rather than hidden: in a unit-test process
`Bundle.main` is whatever hosts the test bundle, so a container built with the
app's own baseline inside a test observes a mismatch and is right to.
`DeviceIntegrityTests` asserts exactly that.

A **missing** identifier is not a mismatch. It is unassessable — "this is not an
app" rather than "this is a different app".

### `provisioning_profile_on_a_store_build` — moderate, tamper

A build that declares itself a distribution build is carrying an
`embedded.mobileprovision`. App Store and TestFlight builds are signed by Apple
and ship without one, so a profile is what a copy re-signed with a development or
enterprise certificate and sideloaded looks like.

`moderate` rather than `strong` because it has an innocent explanation the others
do not: a build configuration that declares `IntegrityBaseline.channel` as
`.appStore` while actually being signed for development produces it on every
launch. That is a mistake in the build settings, not an attack.

### `main_executable_not_encrypted` — strong, tamper

The main executable's `LC_ENCRYPTION_INFO_64` load command reports `cryptid` of
zero on a build that says it came from the store. The store encrypts what it
distributes, and `cryptid` is zero only after somebody has dumped the decrypted
image out of memory and rebuilt a binary from it — the first step of every static
analysis workflow against an iOS app.

`MachOEncryptionState` has four cases so that *could not tell* is not spelled the
same way as *not encrypted*. A header that cannot be walked, and a distribution
build with no encryption load command at all, both report the heuristic as
unassessable rather than firing it.

## Availability is not a negative

`IntegrityReport` carries two sets, and the second one is the part that is easy to
leave out:

| | fired | unassessable |
|---|---|---|
| Simulator | — | `jailbreak_artefact_on_disk`, `filesystem_writable_outside_container` |
| Development build | — | `debugger_attached`, `provisioning_profile_on_a_store_build`, `main_executable_not_encrypted` |
| No bundle identifier | — | `bundle_identifier_mismatch` |

A heuristic that could not run is not a heuristic that passed. Collapsing the two
is how a suite of checks quietly becomes decorative — every filesystem heuristic
here is unassessable on a simulator, which is every run in CI, so a report that
said "no signals" would be reporting a clean bill of health from checks that never
executed. `IntegrityReport.digest` names both halves for the same reason: a log
line that omitted the unassessable set would read as a clean run to whoever finds
it six months later, which is its only audience.

## The channel is declared, not detected

`DistributionChannel` comes from the compiler — `#if DEBUG` in `AppContainer` —
and never from the bundle.

Every runtime test for "am I a store build?" is a test the attacker controls the
answer to, because they control the bundle. A build that asks the bundle which
rules apply to it has handed the choice of rules to whoever repackaged it, and
the rules they would switch off are precisely the ones aimed at repackaging.

That inversion is what makes `provisioning_profile_on_a_store_build` mean
anything at all: the profile is not evidence by itself. The *disagreement*
between the profile and the declaration is.

`.testFlight` and `.appStore` evaluate identically today, and a reader should not
go looking for the difference. Both are signed by Apple, ship without a
provisioning profile, and are FairPlay-encrypted. They stay separate cases
because the report carries the channel to whoever triages it, and "one TestFlight
tester" and "the shipped app" are different news.

## What the app does about it: nothing that can lock anybody out

`IntegrityResponse` has two cases, `observe` and `restrict`. There is no case
that refuses to run, and its absence is the single most important decision here.

Refusing to launch is what every article on this subject reaches for, and it is
the worst option available, for two independent reasons:

* **It does not work.** The check runs inside the process it is judging, so on the
  device where it would matter the attacker owns the branch. Patching one
  conditional out of a binary they have already decrypted is the easiest thing
  they will do all day, and what they end up with is this app with the check
  removed.
* **It does work, on everybody else.** These are heuristics. A false positive is
  not hypothetical, and its cost is a paying customer holding an app that will
  not open and cannot be talked through a fix. A mitigation whose failure mode is
  *cannot be used at all* needs certainty behind it, and nothing in
  `IntegrityReport` is certain.

`Tools/assert-integrity-heuristics.py` fails if `IntegrityResponse` grows a third
case, or if any file in the integrity directory names `fatalError`, `exit`,
`abort`, `preconditionFailure` or `assertionFailure`. The decision is enforced,
not merely written down here.

### The one mitigation

The app ships `IntegrityPolicy.restrictOnStrongSignals`, and the whole of what it
does is: **on at least one strong signal, do not write the biometric-gated
duplicate of the refresh token.**

What it buys. That record is a *second* copy of a live refresh token, kept only
because an authentication gate stands in front of it. On a device where a hooking
framework is resident, an `LAContext` evaluation is among the first things such a
framework is used to lie about — so the gate is the part that fails first, and
what is left is an extra credential in the Keychain with nothing guarding it. Not
writing it is strictly a reduction in what can be stolen.

What it costs on a false positive. The person types a password instead of using
Face ID. Nobody is locked out, no data is lost, no screen is blocked, and the
next launch reconsiders.

What it does not touch. The session tokens themselves, which are ungated by
design because a background refresh has nobody to ask. `docs/security.md` argues
that trade.

Why this is not `.reportOnly`, when `CertificatePinningPolicy` and
`AttestationEnforcement` both are: those two need a server that does not exist
yet, so enforcing them in this template would produce an app that cannot send a
request. This one needs nothing but the device.

`.moderateSignals` was the other candidate threshold and was rejected. The two
moderate signals are a debugger and a provisioning profile, and both have a
build-configuration explanation — a team that mis-declares
`IntegrityBaseline.channel` would have biometric unlock silently off in every
build, which is the kind of failure that gets the whole mechanism deleted rather
than fixed. The threshold is a parameter, so a team that has measured its own
rates can lower it without touching a heuristic.

## Why the evaluation is a pure function

`SystemIntegrityProbe` gathers observations and makes no judgements.
`DeviceIntegrityEvaluator` makes every judgement and touches no system API.

That split is the only reason any of this is tested. A jailbroken device cannot be
brought into CI and never will be, so an `isJailbroken() -> Bool` that walks the
filesystem is untestable by construction. Splitting the pass in two makes the
half that decides *meaning* a pure function over a value, and a rootless
jailbreak, a resigned store build and a debugger on a TestFlight install are then
three values written down in `DeviceIntegrityTests`.

`Tools/assert-integrity-heuristics.py` fails if the evaluator names
`FileManager`, `Bundle`, `ProcessInfo`, `UIApplication`, `_dyld`, `sysctl`,
`getpid`, `access`, `stat`, `Darwin`, `MachO` or `targetEnvironment`, because the
first reasonable-looking step away from the split — *just read `Bundle.main`
here, it is right there* — is the step that makes the evaluation untestable
again.

The probe itself is not tested against a compromised device, and cannot be here.
What `SystemIntegrityProbeTests` does assert is the part that is true of the
process running the tests: that the probe agrees with the compile-time
environment, that the Mach-O walk does not mistake an unencrypted test host for a
crack, and that the three lists are lists a check could actually fire from.

## Not done

* **Nothing reports the posture to a server.** This is the half that matters, and
  it is the half a client cannot do alone: a server that receives an attested
  integrity report can rate-limit, step up authentication, or refuse a
  transaction — all responses a client has no business making about itself, and
  none of which an attacker can patch out of a binary. The channel for it exists
  (`docs/app-attest.md`) and binding the posture into the attested client data is
  its own item, because it changes a wire format a server has to agree with.
* **Nothing displays the posture.** A settings row saying "this device is showing
  signs of modification" is the honest place for a user-facing consequence, and
  needs copy and a localisation pass.
* **The mitigation branch is pinned by the audit script rather than by a test.**
  `AppContainer.live()` chooses `BiometricUnlockPolicy.disabled` over
  `.deviceOwner` from the mitigation, and observing that from a test would mean
  writing a gated Keychain item, which a simulator cannot satisfy — the biometric
  policy it needs has no enrolment behind it. So rule 8 of
  `Tools/assert-integrity-heuristics.py` checks that the `TokenStore` the root
  builds reads `withholdsBiometricUnlockRecord`, and the policy layer above it is
  tested directly.
* **No signal is calibrated.** See *What these heuristics cannot do*. Every
  confidence level here is an argument, not a measurement.
