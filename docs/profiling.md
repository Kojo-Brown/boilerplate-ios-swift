# Profiling: hitches, hangs, and the hotspot behind the search field

Phase 10 item 3. A profiler answers a question no test can: *what did one frame
actually cost, on a real device, while a person was touching the screen.* This
is the walkthrough for asking it — and the record of the one hotspot it points
at in this codebase, which was in a computed property four lines long.

| Type | Module | What it is |
| --- | --- | --- |
| `TracePoint`, `TraceHandle` | `Core` | The vocabulary a trace is read with |
| `PerformanceTracing` | `Core` | The seam: `begin` / `end` / `emit` |
| `SignpostTracer` | `Core` | `os_signpost` into **Points of Interest** |
| `NoOpTracer`, `RecordingTracer` | `Core` | Off, and the double a test reads |
| `SearchIndex` | `Core` | The corpus, folded once |
| `MemoizedSearch` | `Core` | The last answer, kept |
| `SearchWorkLedger` | `Core` | Counts scans, comparisons, cache hits |

**What is measured where.** Instruments measures *cost* and needs a device;
`SearchWorkLedger` measures *how often* and runs in CI. Neither substitutes for
the other, and this document is careful about which one each number below came
from. **No Instruments trace was captured for this commit** — a CI runner has
no device, and the agent that wrote it has no Mac. The hotspot was found by
reading, the fix is held in place by counts, and the procedure below is what
reproduces the other half on a machine that can.

## Vocabulary

**A frame deadline.** The display asks for a frame every 16.7 ms at 60 Hz, and
every 8.3 ms at 120. Everything between a touch and the pixels — the gesture,
your `body`, layout, rendering, the GPU — fits in that, or it does not.

**A hitch** is a frame that misses. What a person sees is a stutter while
scrolling or typing; what the trace shows is one frame whose commit or render
phase ran past its deadline. Instruments reports it as *hitch time ratio*,
milliseconds of hitch per second of scrolling, which is the number to compare
across runs — a count of hitches says nothing about how bad they were. Apple's
guidance is that under 5 ms/s is good and over 10 ms/s is visible.

**A hang** is the main thread blocked long enough to stop responding at all:
250 ms is a micro-hang, half a second is a hang, and past two seconds the
watchdog may kill the app on launch paths. A hitch is a frame that was late; a
hang is a queue of frames that never happened.

The distinction matters because the *fixes* differ. A hitch is usually too much
work in the render loop — a body that rebuilds too much, a filter recomputed per
read, an image decoded during layout. A hang is usually work that should not be
on the main thread at all — synchronous file or network I/O, a `Data(contentsOf:)`,
a `JSONDecoder` over a large payload, a `DispatchSemaphore.wait` bridging async
code into a synchronous call.

## Capturing a trace

1. **Release, on a device.** Product ▸ Profile (⌘I) builds with the Profile
   configuration. A Simulator trace measures a Mac: different CPU, no thermal
   state, a GPU that is not the phone's, and debug builds that skip the
   optimiser your shipping code depends on. For timing questions it is not
   evidence.
2. **Pick the template by the question.**
   - *Animation Hitches* — scrolling and typing that stutters.
   - *Time Profiler* — where main-thread time goes, once you know a frame is
     late.
   - *SwiftUI* — view body durations and how often a body ran.
   - *App Launch* — everything before the first frame.
3. **Record the gesture, not the app.** Start recording, do the one thing that
   stutters, stop. A 90-second trace of general use hides a 300 ms interval;
   a 6-second trace of typing into a search field does not.

## Reading it

**Start in the Points of Interest track.** This is what `SignpostTracer` is
for. Without it a trace is system events and symbol names, and the work you
wrote has to be found by correlating timestamps. With it, the app's own
intervals — `HomeLoad`, `SearchIndexBuild`, `SearchScan` — sit on a track above
the hitches, and "which of my operations was open across this stutter" is a
question you answer by looking rather than by inferring.

```swift
let loading = tracer.begin(.homeLoad)
defer { tracer.end(loading) }
```

Two properties of that pair are load-bearing, and `PerformanceTraceTests`
asserts both because getting either wrong produces a trace that lies:

- **Every `begin` gets an `end`, on every path out** — including a `throw` and
  a cancellation, which is why it is a `defer` rather than a line at the end of
  the method. An interval that is never closed draws as a region running to the
  end of the trace: it looks exactly like the hang somebody opened the trace to
  find.
- **Each interval gets its own identifier.** `os_signpost` pairs a begin with
  an end by identifier, and the default, `.exclusive`, promises only one is
  open at a time. Two overlapping loads under one identifier are reported as
  one long interval — again, an invented hang.

**Then the hitch itself.** Expand a hitch in the Animation Hitches track and it
names the phase that overran: a *commit* hitch is your code — the run loop,
layout, the view update — and a *render* hitch is the GPU, usually too many
offscreen passes, blurs, shadows or masks. Only the first kind is fixed by
anything in this document.

**Then the stack.** In Time Profiler, narrow the range to the late frame,
invert the call tree and hide system libraries. What you are looking for is
your own symbol carrying weight it has no reason to carry, in a stack that
starts at the main thread.

**For a hang**, record with the *Hangs* or *Thread State Trace* instrument, or
run the app with the Thread Performance Checker on (Scheme ▸ Diagnostics), and
look for main-thread blocks that are not waiting on a frame. The fix is
`OffMainActor.run { … }` around the pure work, or an `async` call that was
being waited on synchronously.

## The hotspot

Here is the property that filtered the home screen for nine phases:

```swift
package var filteredItems: [HomeItem] {
    guard !searchQuery.isEmpty else { return items }
    return items.filter {
        $0.title.localizedCaseInsensitiveContains(searchQuery)
            || $0.subtitle.localizedCaseInsensitiveContains(searchQuery)
    }
}
```

Nothing about it is wrong. That is why it survived: it is what the
documentation suggests, it is correct, and its cost is invisible in the source
in two separate ways.

**It is a collation, not a comparison.** `localizedCaseInsensitiveContains`
resolves the current locale and asks ICU for a case-insensitive search under
that locale's rules — per element, per key, per call. In a Time Profiler trace
of a keystroke this is a tower of `CFStringFindWithOptions` and locale lookups
under the getter, on the main thread, inside the frame the keystroke is due in.

**It is a computed property read four times per body evaluation.**
`HomeView.content` reads it twice to choose between the loading, error and empty
states, once to choose between the list and the grid, and once more for the
`ForEach`. The body re-runs on every keystroke, because it reads `searchQuery`.
Four full passes over the corpus, per character typed.

Ten rows will never show this. It is a hotspot in the shape it has, not in the
size it currently runs at — which is the general lesson a profiler teaches
about list screens, and the reason this was worth fixing before the list gets
its real data source.

### The fix, in two halves

**`SearchIndex` moves the locale-sensitive work to where the corpus changes.**
Each key is folded once — case, diacritics and full-width forms collapsed, then
normalised so canonically equivalent spellings are one string — and a query
folded the same way matches with a plain substring test. Folding is a widening
of the predicate as well as a speed-up, and a deliberate one: `cafe` now finds
`Café`, which is the behaviour a search field wants and the one a keyboard
without an `é` cannot otherwise reach. `SearchHotspotTests.Matching` asserts
parity with the old predicate on ASCII text and asserts the diacritic widening
from both sides, so neither can change by accident.

**`MemoizedSearch` makes the four reads one pass.** The cache key is the query
plus a version stamp the owner increments whenever it writes to the corpus —
cheap to compare, which is the whole point, since a cache whose key costs as
much as the work it skips is not a cache. `HomeViewModel.setItems(_:)` is the
single writer that keeps the stamp, the rows and the index in step.

The stamp has a second job that is easy to lose. `HomeViewModel` is
`@Observable`, and Observation registers a dependency on the properties a
getter actually reads. A `filteredItems` that read only the cache would
register nothing, and the list would stop updating when the rows changed.
Reading the stamp is what puts the dependency back.

### What the counts say

`SearchWorkLedger` counts the work, and `SearchHotspotTests` asserts on it.
Reproduce with the package's test scheme — `xcodebuild -list` names it, and CI
picks the `-Package` one because that is the only scheme carrying the test
target:

| | Before | After |
| --- | --- | --- |
| Passes over the corpus, per keystroke | 4 | 1 |
| Reads answered from cache, per keystroke | 0 | 3 |
| Locale-aware collations | 4 × rows × keys, per keystroke | 0 |
| Key foldings | — | rows × keys, per corpus change |
| Key foldings, per appended batch | — | keys of the batch only |

That last row is a second quiet quadratic, fixed in the same place:
`SearchIndex.appending(_:searchableText:)` folds only the new rows, where a
rebuild would refold the entire list on every batch the live-update stream
delivers. At ten rows it is nothing; at ten thousand it is the frame budget,
every few seconds, forever.

`HomeViewModel.deleteItems(at:)` had a third, smaller one — `Array.contains`
inside a predicate that already runs per row, so deleting *k* of *n* rows cost
*n × k* comparisons. It is a `Set` now.

### What the counts do not say

They do not say a scan is cheap, or that the screen is fast. They say the work
happens once instead of four times, over folded keys instead of collated ones.
The remaining question — what one scan costs on the oldest device you support,
with a corpus the size the app will really have — needs a device, the
walkthrough above, and somebody looking at the trace.

## Instrumenting something new

1. Add a case to `TracePoint`. The switch in `SignpostTracer` is exhaustive, so
   the compiler asks you for its name; a name is a `StaticString` because
   `os_signpost` records a pointer into the binary rather than copying a string
   on a path that is meant to cost nothing.
2. Wrap the work: `tracer.measure(.yourPoint) { … }`, or `begin` plus a
   `defer { end }` when the work is `async`.
3. Take the tracer as `any PerformanceTracing = NoOpTracer()`. Being
   instrumented then costs nothing in a preview or in a test that is not
   measuring it, and the composition root passes the real one — the container's
   single `SignpostTracer`, so that every interval in the app is issued from
   one counter.
4. If the claim is about *how often* rather than *how long*, count it with a
   ledger and assert the count. CI cannot read a trace, and a duration
   assertion in a suite is a load meter that goes red when the runner is busy.
