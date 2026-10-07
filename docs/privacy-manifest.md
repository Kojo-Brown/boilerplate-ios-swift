# Privacy manifests and required-reason APIs

Phase 11 item 6.

A privacy manifest is a document that makes claims about a binary, and the only
thing that ever checks the two against each other is an App Store upload — which
happens once, late, on somebody else's machine, against a build somebody is
trying to ship. Everything in between is green. That is the whole reason this
item is a gate and a set of files rather than a file.

## What is where

| File | What it is |
| --- | --- |
| `Sources/Core/Resources/PrivacyInfo.xcprivacy` | `Core`'s manifest. The one target that reaches a required-reason API. |
| `Sources/Networking/Resources/PrivacyInfo.xcprivacy` | `Networking`'s. Declares what the transport sends. |
| `Sources/Features/Resources/PrivacyInfo.xcprivacy` | `Features`'. Declares what the sign-in forms send. |
| `Sources/App/Resources/PrivacyInfo.xcprivacy` | The composition root's. Declares nothing, deliberately. |
| `Tools/app-template/PrivacyInfo.xcprivacy` | **The one an adopter has to copy.** The union of the four, for the app bundle's root. |
| `Tools/assert-privacy-manifest.py` | The standing check. Runs on Linux in the lint job. |
| `Tests/ViewModelTests/PrivacyManifestTests.swift` | Proves each manifest is *in* its bundle, which no script can see. |

## Why there are five manifests and not one

The four under `Sources/` are what Xcode reads to build the privacy report, and
they are per target because that is the unit a reader can act on: a report that
says "this app reads `UserDefaults`" sends somebody looking through 85 source
files, and one that says `Core` does sends them to two.

The fifth is the one that matters for an upload, and the reason is static
linking. A SwiftPM target links into the app's executable by default. `Core`'s
`UserDefaults` calls are therefore symbols in the *app's* binary; what sits
beside that binary is `boilerplate-ios-swift_Core.bundle`, carrying the
manifest but not the code. The required-reason check reads the manifest at the
root of the bundle whose binary it scanned — the app's — so a project that
embeds this package and ships no manifest of its own is the case that produces
an `ITMS-91053` notice naming the app binary and an API nobody remembers adding.

This is the cautious reading of Apple's aggregation behaviour and it is
deliberately the one taken here. If aggregation does cover statically linked
resource bundles, the cost of `Tools/app-template/PrivacyInfo.xcprivacy` is a
duplicated declaration, which costs nothing. If it does not, the cost of
omitting it is a rejected upload. The audit keeps the template an exact union in
**both** directions, because a template declaring more than the package uses is
the same false statement one file further out — and it is the file an adopter
copies, so it is the one that reaches the App Store listing.

`Sources/App`'s manifest declares nothing and exists anyway. An absent manifest
and an empty one read identically to Apple's tooling and do not read identically
to a person: absent is "nobody has assessed this target", empty is "somebody
assessed it and the answer was none". It also means the next thing added to the
composition root fails the audit against a file that is already there.

## What is declared, and why

### `NSPrivacyAccessedAPICategoryUserDefaults` — `CA92.1`, in `Core`

Two call sites, both in `Core`:

* `AppState.colorSchemePreference` persists the light/dark override.
* `UserDefaultsBackgroundRefreshLedger` persists the consecutive-failure count
  that `BackgroundRefreshCoordinator` turns into a backoff exponent.

Both read and write values this app wrote itself, in its own container, which is
exactly what `CA92.1` describes: *"access user defaults to read and write
information that is only accessible to the app itself"*.

`1C8F.1` — the App Group reason — is **not** declared, because the ledger's
`suiteName` is `nil` at every call site, which resolves to `UserDefaults.standard`.
Pass a literal suite name and the audit fails until `1C8F.1` is added, because a
group store is reachable by every extension in the group and is a different
claim.

`Sources/App` names `UserDefaultsBackgroundRefreshLedger` to build the graph and
declares nothing. Naming a type is not calling the API it wraps, which is why
the audit's pattern is `\bUserDefaults\b` and not `UserDefaults`.

### `NSPrivacyCollectedDataTypeEmailAddress` and `NSPrivacyCollectedDataTypeName`, in `Features`

`LiveAuthService.login` posts the email address and the password to
`/auth/login`. `LiveSocialAuthExchangeService.exchange` posts the provider's
identity token and, for Apple, the given and family names handed back on first
authorisation. Both linked to the account, neither used for tracking, purpose
app functionality.

There is no data type for a password in Apple's taxonomy and none is invented
here. The account it belongs to is what `NSPrivacyCollectedDataTypeEmailAddress`
records.

### `NSPrivacyCollectedDataTypeName`, in `Networking`

`UserRepository.updateProfile` `PATCH`es the display name. The `GET` of
`/users/me` is not collection — it reads data back rather than transmitting it —
and the account deletion carries no body.

### `NSPrivacyCollectedDataTypeDeviceID`, in `Networking`

`X-Attest-Key-Id` rides every request the attestor can sign: the App Attest key
identifier out of the Keychain.

This one is a judgement call and the narrower reading is defensible. The key is
per-install, a reinstall destroys it, and it cannot be correlated across apps
the way an `identifierForVendor` can — on that reading it is not a device
identifier at all. It is declared anyway. The cost of over-declaring in a
manifest is one more row in a privacy report; the cost of under-declaring is a
manifest stating that the app sends no identifier while it sends one on every
request. Revisit it when the server half of `docs/app-attest.md` exists and the
binding is known.

### Nothing about tracking, anywhere

`NSPrivacyTracking` is `false` and `NSPrivacyTrackingDomains` is empty in all
five manifests. Nothing in this package reaches an advertising or attribution
SDK, and the audit enforces the agreement between the two keys in both
directions — a domain listed with tracking off describes nothing, and tracking
declared with no domain is the one that fails in production, as a request iOS
silently refuses once the user has denied tracking.

### `NSPrivacyCollectedDataTypeCrashData` and `NSPrivacyCollectedDataTypePerformanceData`, in `Networking`

Phase 11 item 7. `APICrashReportUploader` `POST`s a MetricKit-derived report to
`/diagnostics/reports`: `CrashData` for the crash diagnostics, `PerformanceData`
for the hang, CPU, disk-write and launch ones. Two rows rather than one, because
they are two of Apple's categories and a reader of the privacy report is entitled
to know which this app sends.

Both are declared **`Linked`**, and that is the judgement call here. A report
carries no account identifier and the request is deliberately unauthenticated —
a crash before sign-in is the one most worth having, and requiring a token would
make exactly those launches unreportable. But the transport attaches
`X-Attest-Key-Id` to every request it can sign, this one included, so the report
arrives beside the per-install identifier declared one section up. Claiming the
diagnostics are unlinked while sending them next to an identifier would be false.

The purpose is `AppFunctionality` and not `Analytics`: these reports exist to fix
defects, nothing aggregates them into behaviour, and no third party receives
them.

What is **not** sent matters as much and no manifest can state it.
`MetricKitProjection` drops `MXFrame.address` (a pointer into an address space
that no longer exists, useless without the ASLR slide), `virtualMemoryRegionInfo`
(a memory-map dump) and `MXMetaData.regionFormat` (the user's region, which has
never fixed a crash). `docs/crash-reporting.md` carries the full list and
`Tools/assert-crash-reporting.py` fails if any of them comes back.

### Nothing about on-device diagnostics, which is still an absence

`RepositoryTelemetry`, `DiagnosticJournal` and `FileDiagnosticSink` all exist and
none of them is declared, because none of them transmits: the journal is a file
in the container and the telemetry goes to `os_log`. Apple's definition of
collection is transmission off the device, so an on-device log is not it. The
crash spool is the same — it is a directory in Application Support, and it
becomes collection only at the upload, which is why the declaration lives in
`Networking` and `Core`'s manifest still says it collects nothing.

## What the gates check

`Tools/assert-privacy-manifest.py`, in the lint job beside the other seven
audits. Each rule was verified by reintroducing the defect it names:

1. Every target ships a manifest; it parses; it carries all four top-level keys
   with the right types and no others.
2. Every accessed-API entry names one of Apple's five categories, with a
   non-empty reason list drawn from the codes Apple documents for *that*
   category.
3. Every collected-data entry names a real data type, carries both booleans, and
   lists at least one real purpose.
4. `NSPrivacyTracking` and `NSPrivacyTrackingDomains` agree, both ways.
5. **The equality that matters**: for each target, the required-reason
   categories its source reaches equal the categories its manifest declares.
   Both drifts fail — an undeclared use, and a declaration whose code is gone.
6. The targets that put a request body on the wire are exactly the targets
   declaring collected data.
7. The app template is the exact union of the four, in both directions.
8. Every target carrying a manifest has a `resources:` rule in `Package.swift`,
   without which the file reaches no bundle.
9. This page mentions every category and data type the package declares, and
   keeps a limitations section.

`PrivacyManifestTests` covers the half a script cannot: it loads each manifest
out of its target's *built* bundle, through the `…ResourceBundle` accessors, and
asserts the parsed contents. A manifest with no `resources:` rule behind it is a
correct document that ships nowhere, and rule 8 only checks that the rule is
written down — the test checks that it worked.

## Limitations

**Nothing here verifies that a collected-data row is true.** "Email address, for
app functionality" is a claim about intent and about a server, and no scanner
reads either. Rule 6 is a proxy: it catches a module that starts sending request
bodies while its manifest says it collects nothing, and it would not catch a
module that starts sending a *different* field in a body it already sends. That
direction is review, not CI.

**There is no app target, so the file that matters is not shipped.**
`Tools/app-template/PrivacyInfo.xcprivacy` is a template an adopter has to copy
into their app target and tick for membership. Nothing in this repository can
check that they did, because this repository has no `.xcodeproj` and
`Package.swift` declares a library.

**The `Info.plist` usage descriptions are a separate mechanism and are also
missing.** `CameraService` calls `AVCaptureDevice.requestAccess(for: .video)`,
which terminates the process if `NSCameraUsageDescription` is absent — and it is
absent, because there is no `Info.plist` here either. The privacy manifest does
not cover usage strings and this audit does not look for them. An app target
embedding this package needs `NSCameraUsageDescription`, and `NSFaceIDUsageDescription`
for the biometric gate in `docs/security.md`.

**Third-party SDK manifests are taken on trust.** GoogleSignIn, GTMAppAuth,
GTMSessionFetcher and AppAuth each ship their own `PrivacyInfo.xcprivacy` inside
their own bundles, and Xcode aggregates them into the privacy report. Nothing
here reads them, so a dependency bump that drops a manifest, or adds a
declaration an adopter has to carry into their nutrition label, passes this gate
silently. Checking it would mean reading `.build/checkouts`, which exists only
after a resolve — and this audit runs on a machine with no Swift toolchain.

**Apple's vocabulary is hard-coded.** A gate that fetches a list is a gate that
goes red when a CDN does, so the categories, reason codes, data types and
purposes are tables in the script. A category Apple adds later reads as an
unknown string and fails the audit, which is the safe direction: an
unrecognised declaration gets a person's attention instead of being waved
through.

**The reason codes are not checked for aptness.** The audit knows `CA92.1` is a
valid `UserDefaults` reason; it cannot know whether it is the *right* one for a
given call site. `1C8F.1` is the one case where it tries, by failing on a
literal suite name.
