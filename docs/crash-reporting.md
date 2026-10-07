# Crash and hang reporting with MetricKit

Phase 11 item 7. How this app learns that it crashed, what it sends, what it
deliberately does not send, and which part of it nothing in this repository can
execute.

## The one fact the design is built on

`MXMetricManagerSubscriber.didReceive(_ payloads: [MXDiagnosticPayload])` is
called **once** per payload. There is no acknowledgement, no re-delivery, and no
API that asks for a payload again. MetricKit hands over the previous day's
diagnostics — typically within seconds of a launch, at most once in 24 hours — and
then forgets them.

Everything else follows from that:

* Whatever has not been made durable by the time that callback returns is a crash
  report that no longer exists anywhere.
* So the spool write is **synchronous**, inside the callback, before anything
  else. `CrashReportPipeline.accept(_:)` is `nonisolated` and non-`async` for that
  reason and no other.
* The natural-looking alternative — `Task { await pipeline.accept(reports) }` —
  compiles, passes every test in the suite, and loses a payload on any launch the
  system cuts short. Launch is when MetricKit delivers; launch is also when an app
  is most likely to be killed for taking too long.
* The **upload** is asynchronous, because nothing is lost by it being late. A
  report that could not be sent stays spooled and is offered again at the next
  launch.

`Tools/assert-crash-reporting.py` fails if `accept` becomes `async`, if the spool
protocol becomes `async`, or if a `Task` appears between the callback and the
write.

## The shape of it

```
MetricKit
   │  MXDiagnosticPayload (not Sendable, not constructible)
   ▼
MetricKitProjection ──────────► [CrashReport]        Core, untestable
   │
   ▼
CrashReportPipeline.accept  ──► CrashReportSpooling  Core, synchronous
   │                               │
   │                               ▼
   │                            Application Support/CrashReports/*.json
   ▼
CrashReportPipeline.drain   ──► CrashReportUploading Core, async
                                   │
                                   ▼
                                APICrashReportUploader  Networking
                                   │  APIClient: pinned, attested, keyed
                                   ▼
                                POST /diagnostics/reports
```

`Core` describes the whole pipeline and transmits nothing, which is what lets its
privacy manifest go on saying it collects nothing — collection is transmission.
`Networking` is the only target that sends anything and is where the
`CrashData` and `PerformanceData` declarations live.

## Why there is a value type at the edge

No MetricKit class has a public initialiser: not `MXDiagnosticPayload`, not
`MXCrashDiagnostic`, not `MXHangDiagnostic`, not `MXCallStackTree`, not
`MXMetaData`. A pipeline written against those types is a pipeline that cannot be
tested anywhere — not in CI, not on a simulator, and not on a device inside a loop
anybody would call development.

Projecting at the edge moves the bounds, the durability, the de-duplication, the
retry classification and the redaction onto `CrashReport`, which a test can build
by hand. What is left on the far side is one file of field copying.

## What is sent

Per diagnostic:

| Field | Source | Why |
| --- | --- | --- |
| `windowStart`, `windowEnd` | `MXDiagnosticPayload.timeStamp*` | The payload's window. See below. |
| `build.applicationVersion` | `MXDiagnostic.applicationVersion` | Which release. |
| `build.buildVersion` | `MXMetaData.applicationBuildVersion` | Which dSYM. |
| `build.osVersion` | `MXMetaData.osVersion` | A bug on one iOS major is its own bug. |
| `build.deviceType` | `MXMetaData.deviceType` | Model, e.g. `iPhone14,2`. |
| `build.platformArchitecture` | `MXMetaData.platformArchitecture` | Which slice to symbolicate against. |
| `build.isTestFlightBuild` | `MXMetaData.isTestFlightApp` | A tester's hang is a release blocker; a user's is an incident. |
| `subject` | per diagnostic class | The signature, or the duration, or the byte count. |
| `callStack` | `MXCallStackTree` | Projected frame by frame — see below. |

A frame carries the binary's UUID, the offset into its `__TEXT` segment, the
binary's name when MetricKit knew it, and how deep in `subFrames` it was found.
UUID plus offset *is* symbolication: `atos -o <binary> -arch <arch> -l 0` resolves
it against the matching dSYM on a machine that has never seen the device.

### Timestamps are coarse, honestly

`MXDiagnosticPayload` timestamps the **payload**, not each diagnostic inside it.
Every report from one delivery therefore shares one window, and two crashes from
the same day have no real order between them. Nothing here invents a more precise
time: a crash report with a fabricated timestamp is worse than one with a coarse
true one.

## What is deliberately not sent

| Field | Why not |
| --- | --- |
| `MXFrame.address` | A load address in a process that no longer exists. Without the ASLR slide it symbolicates nothing, and the slide is what ASLR randomises per launch. What it does carry is a pointer out of somebody's address space. |
| `MXCrashDiagnostic.virtualMemoryRegionInfo` | A textual dump of the process's memory map, and the largest field in a crash diagnostic. Useful for one class of bug — a wild pointer whose target region you want named — and paid for on every report. Add it to `CrashSignature` when you are chasing that bug. |
| `MXMetaData.regionFormat` | The user's region. It narrows who they are and no crash has ever been fixed by knowing it. |
| `MXCallStackTree.jsonRepresentation()` | Hands over MetricKit's whole document, dropped fields included. The projection exists so that what leaves the device is chosen field by field. |
| `MXMetricPayload` | The daily *metrics* report — launch histograms, cellular conditions, animation hitches. A different feature with a different privacy answer. `didReceive(_:[MXMetricPayload])` is implemented and empty, and an adopter who wants it has one method to fill in and two manifest rows to add. |

The audit fails if any of them comes back, because each is a one-line addition in
a diff that is already about crash reporting, and each one makes a privacy
manifest that is currently true into one that is not.

## The bounds

`CrashReportLimits` — nothing MetricKit hands over is bounded by anything the app
controls. A payload covers 24 hours, a crash loop inside those 24 hours produces
one diagnostic per crash, and a recursion crash produces a stack as deep as the
stack got.

| Limit | Default | What it bounds |
| --- | --- | --- |
| `maxReportsPerPayload` | 64 | Reports per delivery. The only limit that **drops**; the count of what it dropped is reported. |
| `maxStacksPerReport` | 16 | Threads per report. |
| `maxFramesPerStack` | 128 | Frames per thread. |
| `maxFrameDepth` | 128 | How deep into `subFrames` the walk goes. |
| `maxTerminationReasonLength` | 256 | The one free-form string in a report. |
| `spoolCapacity` | 128 | Reports waiting on disk. |

Everything except the first is a *truncation*: the report is still spooled, still
uploaded, and says `isTruncated`. Carried rather than inferred — a stack cut at the
limit and a stack that is genuinely that short are indistinguishable once the
frames are counted, and the difference decides whether the bottom of the stack is
missing or absent.

The frame walk is an explicit stack rather than recursion. The input is a tree the
system built from a call stack that may have crashed *because* it recursed without
end; a recursive walk over it would be the same unbounded recursion inside the
reporting path.

## The digest

A report's identity is the SHA-256 of a canonical string over the format marker,
the kind, the build identity, the subject and the call stack. It does three jobs:

* It is the spool's filename, so a payload delivered twice — which MetricKit does
  not promise but has been observed to do after a restore — overwrites one file
  rather than queueing two uploads.
* It is the upload's `Idempotency-Key`, so an attempt whose response was lost is
  collapsed by the server instead of counted as a second crash. `docs/idempotency.md`
  is the general version; this is the one place in the app where the repeat is
  separated from the original by a process launch.
* It is what a server groups by, so "this crash, 1,400 times" is one row.

What is **in** it and what is **out** is the whole design:

| Out | Why |
| --- | --- |
| `windowEnd` | The digest answers "is this the same defect?", not "is this the same delivery". Two occurrences on consecutive days have to agree. |
| `terminationReason` | Frequently embeds a number that differs between occurrences of one bug — a footprint in a jetsam note, a deadline in a watchdog note. |
| `deviceType` | One bug across nine iPhone models is one bug. Hashing the model would split it into nine. |
| `StackFrame.binaryName` | MetricKit reports it as `nil` for some frames in some payloads, so including it would make the digest depend on how much the framework happened to know. |

Durations are bucketed to whole seconds and byte counts to whole kilobytes, so two
occurrences of one stuck main thread group together — and so that the digest does
not depend on how a `Double` happens to print.

`CrashReportDigestTests.canonicalFormIsPinned` pins the layout as a *literal*
rather than rebuilding it from the same properties, because a test that rebuilt it
would pass through exactly the change that makes two builds of the app disagree
about what one crash is called.

## The spool

One JSON file per report in `Application Support/CrashReports`.

**Application Support and not Caches**, because the system evicts Caches under
pressure and the pressure that evicts it is correlated with the crashes being
reported.

**A file per report and not one file**, because appending and removing are at
opposite ends of the queue and both have to be safe against the process dying
between any two instructions. With one file they are read-modify-write over the
whole queue; with a file each they are an atomic create and an unlink, and the
queue has no state of its own to corrupt.

**The filename carries the ordering** — `<zero-padded seconds>-<digest>.json`,
sorted lexicographically. Asking the file system for creation dates would mean
declaring `NSPrivacyAccessedAPICategoryFileTimestamp` in `Core` to buy an ordering
the reports already carry.

**At capacity the oldest go**, which is the opposite of what a log would do. A
report names the build it came from, so the front of a full spool is where reports
about builds the person has already replaced accumulate — and a spool that kept
them would never carry a report about the build that is installed.

**A file this build cannot decode is deleted and counted.** It will never become
decodable, so keeping it means re-reading and re-failing on it at every launch for
as long as the app is installed.

## Draining

```swift
await pipeline.drain()
```

Called from `MetricKitDiagnosticSubscriber.start()` at launch, and again after
every payload. At launch rather than only after a payload because the two are
independent: a report spooled yesterday and not uploaded — offline, or the server
was down — has to go on a launch where MetricKit delivers nothing, which is most
launches.

### Three outcomes, not two

| Outcome | Spool | When |
| --- | --- | --- |
| `accepted` | cleared | 2xx, including the 204 whose empty body fails to decode. |
| `rejected` | cleared | 4xx other than 408 and 429, a 401, or a report that will not encode. |
| `deferred` | kept | 5xx, 408, 429, a network failure, anything unclassifiable. |

A queue that distinguishes only success from failure has to pick one wrong
behaviour for a report the server will never accept: keep it, and one malformed
report blocks every later one for the life of the install; drop it on any failure,
and a day with no network costs every crash in it.

`decodingFailed` counting as accepted is the **normal path**, not a defensive
branch: `sendEmpty` decodes `EmptyResponse` from the response body, an empty body
is not valid JSON, and the right answer to "here is a crash report" is `204 No
Content`. In every other reading of it the status code already said the report was
taken, so re-sending would report one crash twice to satisfy a parser.

A 401 is permanent **here only**. The request is unauthenticated by design, so a
401 is the endpoint refusing the report rather than a token a refresh could fix —
and `URLSessionAPIClient` does not attempt a refresh for a request with
`requiresAuth: false`, so deferring would retry the identical request forever.

### A deferral stops the drain

It is a statement about the connection, not about the report, so carrying on down
the queue would cost one failing round trip per waiting report and change nothing.
The queue keeps its order and the next launch starts again from the front.

### Reentrancy

`drain()` is the textbook actor-reentrancy hazard. An actor serialises
*synchronous* access, not whole method bodies: at every `await` it is free to run
another job, and `drain()` awaits per report. Two drains — one from launch, one
from a scene becoming active a moment later — would interleave at the first
suspension, read the same spool contents the first has not finished clearing, and
send everything twice. `CrashReportPipeline.draining` is checked and set with no
`await` between, so the second caller is turned away before it can read anything,
and it says so.

Idempotency on the server is the belt to these braces. A client that knowingly
double-sends and relies on the other end to tidy up is a client spending its
users' data allowance for nothing.

## Why the request is unauthenticated

A crash is not a thing a signed-in user does. The process that died may have died
before the first screen, during a sign-out, or holding a refresh token the server
has since revoked — and those are the launches most worth hearing about.
Requiring a token would make exactly their reports unsendable.

What the server gets instead is the App Attest assertion the transport attaches
anyway, which is a stronger claim than a bearer token for this purpose: it says
the request came from a genuine install of this app, which is the property a
public diagnostics endpoint needs. `docs/app-attest.md` is what has to be true on
the server side.

## What the server has to do

Nothing here verifies anything; this is the client half.

1. Accept `POST /diagnostics/reports` with no `Authorization` header, and verify
   the attestation headers instead. Attestation is `.reportOnly` in this template,
   so an adopter turning it up has to do that first.
2. Read `format` out of the body — not out of a header — and refuse a document
   whose marker it does not know with a **4xx**, so the client drops it rather
   than retrying it forever.
3. Treat `Idempotency-Key` as the report's identity: a second request with a key
   already recorded is answered from the record, not applied again.
4. Answer `204` on success. Any 4xx other than 408 or 429 means "never send this
   again", and the client will obey.
5. Group by the key. It is a content digest, so it is stable across days, devices
   and models, and it is *not* stable across OS majors or builds — which is
   deliberate.

## What the gates check

`Tools/assert-crash-reporting.py`, in the lint job beside the other audits. Nine
rules, each verified by reintroducing the defect it names:

1. `accept` is neither `async` nor missing, and the drain keeps its reentrancy
   flag.
2. The spool protocol's requirements stay synchronous, including `store`'s exact
   signature — that signature *is* the contract.
3. The dropped fields stay dropped, in the projection and in the model.
4. `import MetricKit` appears in exactly one file.
5. The projection holds no policy: it consults `CrashReportLimits` and names no
   `URLSession`, no `FileManager` and no `APIEndpoint`.
6. The uploader takes an `any APIClient`, names no `URLSession`, posts with
   `requiresAuth: false`, and keys the request with the report's digest.
7. The composition root builds the pipeline and vends the subscriber, and
   `BoilerplateApp` holds the subscriber in a stored property —
   `MXMetricManager.add(_:)` does not retain it.
8. The callback spools before it starts a task.
9. This page keeps its limitations section.

`CrashReportTests`, `CrashReportSpoolTests` and `CrashReportPipelineTests` cover
the half a script cannot see: the digest's layout, the spool's durability and
eviction, the three outcomes, the drain's order, and the double-send the
reentrancy flag prevents.

## Limitations

**`MetricKitProjection` has never executed anywhere, and cannot here.** Every
MetricKit class it reads has no public initialiser and the framework delivers only
on a device, once a day, for the day before. So the field mapping, the unit
conversions, the thread reordering and the frame walk are exercised by nothing:
they are held in place by rules 3, 4 and 5 of the audit, which are syntactic. The
first real payload is the first execution. Verify it with Xcode's **Debug ▸
Simulate MetricKit Payloads** against a development build, which is the only loop
available.

**Nothing receives the reports.** `api.example.com` does not exist and
attestation ships `.reportOnly`, so in this repository every upload defers and
every report accumulates in the spool until the capacity evicts it. That is the
rollout position rather than a weaker feature: the client half is complete and the
missing ingredient is a server.

**There is no retry schedule.** A deferred report is offered again at the next
launch and not before. There is no timer, no `BGTaskScheduler` leg and no backoff,
so a device that is launched once a week uploads once a week. Wiring it into
`BackgroundRefreshCoordinator` would fix that and is its own item.

**`MXMetricPayload` is discarded.** The daily metrics report — launch
distributions, hitch ratios, cellular conditions — is accepted and dropped. It is
a different feature with a different privacy answer, and nothing in this app reads
it.

**The spool is not encrypted beyond the file system's own protection.** The reports
sit in Application Support under the app's data-protection class. They carry no
credentials and no user content by construction, which is the argument for that
being enough; an app whose crash reports could contain either should not be
putting them there.

**Nothing symbolicates.** The reports carry UUID-and-offset pairs and this
repository has no symbolication step, no dSYM upload and no build-id registry.
`fastlane/` uploads a build; it does not keep its symbols anywhere a report can be
read against. That is the next thing an adopter needs and it is not here.

**No field is redacted at runtime.** The redaction in this pipeline is structural —
a field is either projected or it is not — and `terminationReason` is the one
free-form string that gets through, capped but not inspected. It is written by the
system rather than by the app or the person using it, which is an argument about
today's iOS; the cap is the part that is a property of this code.
