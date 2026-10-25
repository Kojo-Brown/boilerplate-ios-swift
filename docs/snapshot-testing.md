# Snapshot tests and the CI diff gate

Fifteen pictures, committed, compared pixel by pixel on every pull request.

This page is about what that buys, what it costs, and the four ways a snapshot
suite stops being a test while every run stays green.

## What it catches that nothing else here does

The rest of the suite asserts about *structure*. `DesignSystemTests` says
`AppButton` exists and takes the configuration it claims to;
`AccessibilityAuditTests` says the controls are labelled and reachable;
`ViewIdentityTests` says a row does not re-render when it does not have to;
`DynamicTypeTests` says a control's height scales with the type size.

None of them would notice:

* a corner radius going from 12 to 4,
* a foreground colour resolving white-on-white in dark mode,
* a padding dropping out of a `VStack`,
* a label clipping at an accessibility type size,
* `FlowLayout` breaking a line one chip early.

Those are defects in the pixels. The only assertion that holds pixels still is
a picture of them, which is the entire argument for a snapshot test — and the
entire argument against taking too many: each one is a binary file a reviewer
cannot read, and a re-record nobody looked at is a test switched off.

## Why `ImageRenderer`, and what it cannot draw

A snapshot library would host the view in a `UIHostingController` and call
`drawHierarchy(in:afterScreenUpdates:)`. That is the real render server, so it
draws everything: materials, platform-backed controls, navigation chrome. This
gate does not use it.

What it uses is SwiftUI's own `ImageRenderer`, which walks the display list
synchronously, on the main actor, with no window and no run-loop turn. The
trade is deliberate: **fidelity is what a preview is for, and determinism is
what a gate is for.** The hosted route needs a window (process-wide state, and
this repository has a history of main-actor starvation to show for it — see
[docs/view-identity.md](./view-identity.md)), needs settling before it is
accurate, and will happily capture a spinner mid-rotation.

The cost is that `ImageRenderer` draws a subset, and the subset is real. These
are excluded from the catalogue for that reason, not by oversight:

| Excluded | Why |
| --- | --- |
| `LoadingView`, `InlineLoadingView`, `PaginationFooter`, `AppButton` while loading | An indeterminate `ProgressView` is an animation. Its pixels are a function of the clock, so there is no "the" picture of it. |
| `CameraPreviewView`, the Google sign-in button, `NavigationStack` chrome, `List` | Platform-backed. A `UIView` is not in SwiftUI's display list, so it renders blank — and blank records perfectly well, which is the trap. |
| `AppTextField`, in any state | Its resting background is a `Material`, which `ImageRenderer` does not draw. The error state replaces the material with a flat red wash and *was* in the catalogue — until the first recording was looked at. The `TextField` and `SecureField` inside it come out as the renderer's own "cannot draw this" placeholder: a yellow bar with a no-entry sign, with the label, the border, the red wash and the error row rendering correctly around it. A golden of that is a picture of the renderer's limits. |

A subject that renders blank is the failure mode to watch for, because nothing
automated can see it: a blank rectangle is stable, reproducible, and passes
forever. That is why a recording is reviewed by a person before it is
committed, and why the record lane pushes to a branch of its own rather than to
the branch under review.

**That review is not a formality.** The first recording taken for this gate had
two defects in it and neither one failed anything. `AppTextField` came out with
a yellow "cannot draw this" bar where its text field should be, as above. And
every dark snapshot was drawn on a *white* canvas, because `.background` had
been written after `.environment(\.colorScheme, …)` in the renderer — an
environment modifier applies to the subtree underneath it, so the canvas was a
sibling layer outside it and resolved `systemBackground` in the ambient scheme.
`home-item-row.dark` was white text on white. The light-versus-dark assertion
passed anyway, every time, because the *content* really did differ. It now
checks the canvas pixel as well as the picture.

## The catalogue

One `SnapshotSubject` per entry, in `Tests/SnapshotTests/SnapshotCatalogue.swift`.
Each is rendered on an opaque canvas of a fixed width with 16 points of padding;
the height is whatever the subject asks for, which is why a view that grows a
line reports a changed size rather than a diff of a clipped image.

| Subject | Width | Appearances | What it is a picture of |
| --- | --- | --- | --- |
| `semantic-colour-swatches` | 320 | light, dark | The `UIColor`-backed design tokens and nothing else. An instrument — see below. |
| `app-button-styles` | 390 | light, dark, accessibility3 | The four button states that are not animated: primary, secondary, destructive, disabled. |
| `inline-error-banner` | 390 | light, dark, accessibility3 | The dismissible error banner, including how its sentence wraps. |
| `tag-chip-flow` | 390 | light, dark | Seven chips of uneven width through `FlowLayout`, one of them selected. |
| `tag-chip-flow-narrow` | 220 | light | The same chips in a container too narrow for them. The line breaking is the subject; at a comfortable width it is invisible. |
| `home-item-row` | 390 | light, dark | Two list rows, one of them long enough to wrap, with a divider between. |
| `home-item-card` | 390 | light, dark | The iPad grid card: wrapping title, clipped corners, and the shadow the canvas padding exists for. |

File names are `<subject>.<scheme>[.<type size>].png`, derived from the
catalogue rather than written down. The standard type size is spelled by
leaving it out.

## The two invariants over the goldens

A pixel comparison cannot tell a correct picture from a consistently wrong one.
Two assertions in `SnapshotGateTests` can, and they read the committed files
rather than rendering anything:

**A subject recorded in both schemes has two different pictures.** The design
system's tokens are `Color(uiColor:)` wrappers around `UIColor`s with a dynamic
provider, and a `UIColor` resolves against the *current trait collection* — not
against SwiftUI's `colorScheme` environment. Setting only the environment
leaves `AppColors.surface` resolving light inside a dark snapshot:
reproducible, stable, and wrong. `SnapshotRenderer` therefore says the
appearance twice, once to SwiftUI and once to UIKit, and
`semantic-colour-swatches` is the subject that would catch it if either half
were dropped — every other subject contains text, which takes its colour from
the environment and would differ between the schemes regardless.

**A subject recorded at an accessibility type size is taller for it.** Dynamic
type is a layout change here, not a font change: `ScaledControlHeight` gives a
control a floor that grows. A golden at `accessibility3` that is no taller than
the standard one means the type size never reached the render.

## The tolerance

`SnapshotTolerance.standard` is two numbers:

* `channelTolerance: 4` — a pixel whose every channel is within 4 of the
  recorded one is the same pixel. This absorbs antialiasing on the edge of a
  glyph and nothing else.
* `mismatchBudget: 0.001` — at most one pixel in a thousand may exceed it.

Neither is a measurement. They start tight, and the gate prints the observed
numbers whenever a comparison is not exact even when it passes, so that moving
one of them is a decision taken against evidence from a real run. **Changes to
these two values belong in this paragraph**, with the run that justified them:

* Set to 4 / 0.001 when the gate was introduced, and neither has yet been
  needed. The evidence: the goldens were recorded twice on two different
  `macos-15` runner VMs and every light-scheme image came back byte-identical
  (the six that changed were the dark ones, and they changed because a defect
  in the renderer was fixed between the two recordings) — and then the first
  verify run, on a third VM, reported **no drift at all**: fifteen comparisons,
  every channel of every pixel identical, nothing printed. This renderer on one
  runtime is bit-exact run to run. The tolerance is there for the day the
  runtime moves, not for ordinary noise. The next person to move either number
  should add their run here rather than replacing this line.

A failure reports the mismatched pixel count, the largest channel delta, and
**the bounding box of the difference**, which is the line to read first:
`x 14…376, y 52…71` is one row of text and almost always a string or a font;
a box covering the image is a colour or a layout; a few pixels at the bottom
edge is something that grew.

Three images are written per failing case — the recorded one, the rendered one,
and an overlay painting every differing pixel magenta over the recording. CI
uploads them as the `snapshot-failures-<run>` artifact. Locally they land in
`SnapshotFailures/`, which is gitignored.

## Provenance, and the simulator the gate asks for

`__Snapshots__/environment.json` records what the goldens were recorded
against — the iOS version, the renderer, the scale — plus the inventory of
every golden the directory is supposed to hold.

The CI gate reads that file, asks
`.github/actions/select-simulator` for the runtime it names, and **warns rather
than fails** when the runner image no longer has it. The verdict is the pixels:
failing a build over a version string nobody would have seen a difference from
is a gate measuring the wrong thing. But when a comparison does fail, the
failure names both environments, which turns "17 snapshots changed" into "the
runtime moved under them".

The device model is deliberately not recorded. The renderer is handed an
explicit width and an explicit scale, so what model of iPhone the simulator
claims to be changes nothing.

This is also why the gate is a separate job from `Build and test`: that job
takes the newest runtime its SDK can drive, which is the right choice for
everything except a recorded picture.

## Re-recording

A re-record replaces the thing the gate compares against. Done without reading
the diff, it turns the gate off for every case it touches — so the question to
answer first is always *why* the pixels moved.

**On a Mac**, in a checkout:

```sh
touch .snapshot-record
xcodebuild test \
  -scheme boilerplate-ios-swift-Package \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SnapshotTests
rm .snapshot-record
```

**The switch is a file, not an environment variable**, and that is not a
stylistic choice. A test bundle on a simulator is launched by the test runner
*inside* the simulator and inherits nothing from the `xcodebuild` process on
your Mac, so `SNAPSHOT_RECORD=1 xcodebuild …` reaches nothing — the suite takes
the verify path, reports all fifteen cases as never recorded, and writes none
of them. `TEST_RUNNER_SNAPSHOT_RECORD=1` as a build setting, which is the
documented way to put a variable into a test runner's environment, does not
reach it either: on the scheme SwiftPM generates, the `.xctestrun` comes out
with an empty `EnvironmentVariables` dictionary. Three CI runs established
that. What the test process certainly can see is the source tree, because it is
already reading and writing goldens there.

Forgetting the `rm` is covered: `Tools/assert-snapshot-gate.py` fails while the
file exists in a checkout, and it is gitignored, so the switch can be neither
committed nor silently left on.

The goldens are written straight into the source tree — `#filePath`, not the
test bundle — so `git diff` is the review. Recording is not a free action: the
lane writes each image, reads it back, and fails if the PNG does not round-trip
byte for byte, because a golden that decodes differently than it encoded fails
the gate on every later run against no change at all.

**With no Mac at all** — the case this repository's scheduled agent is in, with
no `swift`, no `xcodebuild` and no simulator — push the branch under a
`snapshots/` prefix:

```sh
git push origin HEAD:snapshots/my-change
```

`.github/workflows/record-snapshots.yml` records on a macOS runner and commits
the result back to that branch. Fetch it, **open the images**, and cherry-pick
the recording onto the branch under review. The lane refuses to run on `main`,
and it is the only workflow here with `contents: write`.

## What the audit holds

`Tools/assert-snapshot-gate.py` runs in the lint job, needs no toolchain, and
covers the state a green run cannot see:

1. the goldens directory holds images, the manifest and the readme, nothing else;
2. every golden is a non-empty PNG — a truncated write or an LFS pointer reads
   as "never recorded", which looks like a first run rather than a corruption;
3. the manifest is well formed and names a positive scale, an iOS version and a
   renderer;
4. the manifest's inventory and the directory agree **in both directions** — an
   orphan left behind by a renamed subject is an image nothing compares
   against;
5. every file name decomposes into a subject, a scheme and an optional type
   size the source declares, and every declared subject has a golden;
6. record mode is **off right now** — no `.snapshot-record` in the checkout —
   exactly one place names it, `ci.yml` never does, and the record lane does;
7. some job runs `-only-testing:SnapshotTests` and the main suite skips it;
8. the record lane is limited to `snapshots/**` and refuses the default branch;
9. `.snapshot-record` and `SnapshotFailures/` are both gitignored;
10. this page mentions every subject that has a golden.

The inventory check is split in half on purpose. This script can see the
directory and not the catalogue; `SnapshotGateTests.environmentIsRecorded`
compares the same inventory against `SnapshotCase.all`, which only a compiled
test can. Either half alone is a rubber stamp.

The comparison engine has its own suite, `SnapshotComparisonTests`, which
builds bitmaps by hand: the tolerance, the mismatch budget, the bounding box,
the magenta overlay, the `CGImage` round trip (a vertical flip in either
direction would be invisible in a golden and fatal to the gate's meaning) and
the PNG round trip. It is the part of a snapshot gate that can be proved rather
than recorded.

## What this does not claim

* **Nobody has watched these tests fail on a changed view.** The recordings and
  every comparison have run in CI; the agent that wrote the suite has no Swift
  toolchain, so the reds reported here are the ones CI produced, not ones
  reasoned about.
* **A snapshot proves nothing about behaviour.** It is a picture. A button that
  is drawn correctly and does nothing passes every case here.
* **The exclusions are a judgement, not a measurement.** `ImageRenderer`'s
  behaviour with materials and platform views is documented but not versioned,
  and the day it starts drawing a `Material` the resting `AppTextField` becomes
  recordable and this page is where that belongs.
* **Seven subjects is a sample.** The screens themselves are not in the
  catalogue — `LoginView` carries a platform-backed sign-in button and
  `HomeView` a `List` — so what is held still is the design system, not the
  composition of it.
