# Localisation

Phase 10 item 7. Every string this package shows is declared in a String
Catalog, counted strings pick their form in the catalog rather than in Swift,
and the one container that lays out by hand now asks which way the reader
reads.

Three things were wrong before, and none of them was visible in the source.

---

## 1. A package's strings do not resolve against a package's catalog

This is the finding that makes the rest of the work necessary, and it is worth
stating precisely because it looks like nothing:

```swift
Text("Home")            // in an app target: extracted, translated, resolved
Text("Home")            // in a package target: resolved against Bundle.main
```

`Text(_:)`, `NSLocalizedString`, and `LocalizedStringResource(_:)` all default
to **`Bundle.main`** — the *app's* bundle. A package target's resources are not
in there. They are in `Bundle.module`, a separate resource bundle the build
copies in beside the binary, and nothing consults it unless it is named.

Foundation's documented fallback for a key it cannot find is to return **the
key**. So:

* with English-as-key strings, everything looks correct and nothing can ever be
  translated — the lookup misses and the key it echoes back happens to be the
  English;
* with symbolic keys, the screen renders `home.title`, in every language,
  including the one the catalog was written in.

Nothing catches either. It is not a warning, not a crash, and **not reproducible
in a preview**: a preview is built into the same module as its catalog, so both
are in the same bundle and the lookup succeeds. The failure needs the string and
the catalog to be in *different* bundles, which is the arrangement every shipped
call site is in.

### What that means for the layout of this package

Each target that shows a string carries its own catalog and its own accessor:

| Target | Catalog | Accessor | Namespace |
| --- | --- | --- | --- |
| `Core` | `Sources/Core/Resources/Localizable.xcstrings` | `coreString(_:_:)` | `CoreStrings` |
| `Networking` | `Sources/Networking/Resources/Localizable.xcstrings` | `networkingString(_:_:)` | `NetworkingStrings` |
| `Features` | `Sources/Features/Resources/Localizable.xcstrings` | `featureString(_:_:)` | `FeatureStrings` |

Three catalogs rather than one, because `Bundle.module` is generated *per
target* and resolves to the bundle of the module it is compiled into.
`Networking` shows three sentences and still gets a catalog of its own; the
alternative would be `Core` vending its bundle publicly so other targets could
reach across, which is a wider hole than a small third file.

Every accessor names its bundle and its table:

```swift
private func coreString(
    _ key: String.LocalizationValue,
    _ comment: StaticString
) -> LocalizedStringResource {
    LocalizedStringResource(
        key,
        table: "Localizable",
        bundle: .atURL(Bundle.module.bundleURL),
        comment: comment
    )
}
```

`Package.swift` carries `defaultLocalization: "en"` — required as soon as a
target has localised resources, and also the answer to "what does an
untranslated key fall back to": the English from the catalog, not the key.

### Reaching a string

`Text` has an initialiser for `LocalizedStringResource`, so where SwiftUI takes
a `Text` the call sites pass one:

```swift
.navigationTitle(Text(FeatureStrings.Home.title))
.accessibilityHint(Text(FeatureStrings.Home.openItemHint))
```

Where it does not — `Label(_:systemImage:)`, `Button(_:action:)`, `Section(_:)`
and the other APIs that take a `LocalizedStringKey` (which a resource is not)
or a `StringProtocol` (which a `String` is) — `.string` resolves it:

```swift
Label(FeatureStrings.Home.scanText.string, systemImage: "text.viewfinder")
```

`.string` is also what `errorDescription` returns. Resolution happens at the
point of call, deliberately: an error value can be built on a background task,
held in a `Result` and rendered minutes later, and a sentence resolved at
construction would be pinned to whatever locale was current then.

### Symbolic keys, not English-as-key

Xcode's default for an app is to use the English text as the key. This package
uses `home.title` and declares the English as the catalog's `en` value. Two
reasons, both about a package rather than an app:

* **Rewording is not renaming.** Changing "Sign In" to "Log in" under
  English-as-key orphans every translation of it. Here it is one value edit.
* **The same word is not always the same string.** "Settings" the screen and
  "Settings" the menu item are two entries that can diverge in a language that
  distinguishes them.

The cost is that a missed lookup renders `home.title` rather than plausible
English, which is exactly why the resolution tests below exist.

---

## 2. Plurals belong in the catalog

Two headings counted things and chose their form in Swift:

```swift
"\(blockCount) block\(blockCount == 1 ? "" : "s") detected"
```

English has two plural categories and is the easiest language there is to get
right. Russian has three and picks between them on the last *two* digits.
Arabic has six, one of which is for exactly two. Polish, Welsh and Irish each
differ again. No ternary reaches any of that.

The quieter cost is that **a translator never sees the sentence**. It does not
exist until runtime; what exists in the source is "block", "s" and "detected",
in an order the catalog cannot express and a translator cannot reorder.

Counted strings are `variations.plural` blocks now:

```json
"textScanner.blocksDetected %lld" : {
  "localizations" : {
    "en" : {
      "variations" : {
        "plural" : {
          "one"   : { "stringUnit" : { "value" : "%lld block detected" } },
          "other" : { "stringUnit" : { "value" : "%lld blocks detected" } }
        }
      }
    }
  }
}
```

and reached through a function whose interpolation builds the key:

```swift
package static func blocksDetected(_ count: Int) -> LocalizedStringResource {
    featureString("textScanner.blocksDetected \(count)", "%lld is how many blocks were found.")
}
```

`String.LocalizationValue` turns an interpolated `Int` into `%lld` and a
`String` into `%@`, which is why the catalog key carries the specifier.

Three keys are counted: the recognised-text heading, the barcode heading, and
`PaginationError.tooManyEmptyPages` — the plural that is not on a screen at all
but inside an error, reached through `localizedDescription`, and still has to
pick a form.

---

## 3. A custom `Layout` is not mirrored for you

`FlowLayout` laid Arabic out left to right, and the source gave no sign of it.

SwiftUI mirrors the containers it ships: an `HStack` in a right-to-left locale
runs right to left with nothing asked of the caller. A `Layout` conformance
looks like one of them in a view body and is not one. `placeSubviews` receives a
`bounds` whose `x` grows **rightwards under every layout direction there is**,
so a flow that puts its first item at `bounds.minX` puts it at the left edge in
every language, items run against the reading order, and `.leading` — a word
that means *start*, not *left* — quietly meant "left" for this one container
while meaning "start" for every stack beside it.

`LayoutSubviews.layoutDirection` exists precisely because this is the layout's
own responsibility. `FlowLayout` reads it; `FlowLayoutEngine` answers it by
reflecting every frame about the flow's vertical centre line, once, after the
lines are placed:

```swift
private func mirrorHorizontally(_ result: inout Solution) {
    let width = result.size.width
    for index in result.frames.indices {
        result.frames[index].origin.x = width - result.frames[index].maxX
    }
}
```

Three decisions in that:

* **One reflection at the end, not a branch inside the placement loop.**
  Right-to-left has to reverse the order of items along a line *and* move each
  line's content to the opposite edge, and those are the same operation seen
  twice. Two special cases would be two places to get the spacing wrong, and
  they would only ever agree by inspection.
* **Reflected about the flow's own reported size, not the width the lines were
  broken at.** A flow reports the width it used (208 points, say) rather than
  the width it was offered (250). Mirroring about the larger number would push
  every frame 42 points past the right edge of a container that had been told
  the flow was 208 wide — the same class of defect as reporting a size the
  content does not fit in.
* **The layout direction is part of the cache key.** This is the half that is
  easy to leave out. Layout direction is an environment value: it can change
  while the subviews and the proposed width both stand still, which is exactly
  the case a width-keyed cache reports as a hit. The flow would then go on
  placing frames solved for the other direction — correct arithmetic, cached
  under the wrong question. `FlowLayoutCache` keys a solution on the engine as
  well as the width, which covers alignment and line spacing for free.

### What else the right-to-left pass found

Nothing, and that is worth recording rather than implying. The rest of the
package already expresses horizontal position in reading-relative terms:
`VStack(alignment: .leading)`, `.frame(maxWidth: .infinity, alignment:
.leading)`, `.padding(.horizontal)`, `.transition(.move(edge: .bottom))`. There
is no `.padding(.left)`, no `NSTextAlignment`, and the one `.offset(x:)`-style
transform in the package — the hero card's interactive dismissal — moves
vertically. The custom layout was the only thing placing content by absolute
`x`, which is what made it the only thing that was wrong.

---

## What is *not* here

**No second language ships.** The catalogs have one localisation, `en`. Adding
Arabic or Hebrew would mean writing translations, and machine-quality
translations checked into a boilerplate are worse than an honest single
language: they read as reviewed and are not.

So the right-to-left work above is **structural**, and the tests are structural
with it. They assert that the layout asks which way the reader reads and
answers correctly — which is exactly what Xcode's own "Right-to-Left
Pseudolanguage" scheme option tests, since it flips layout direction without
translating anything. What no test here establishes is how a real Arabic
sentence renders in these views: whether it fits, whether it wraps where it
should, whether a translated button outgrows its row.

**No runtime check that a screen's text was translated.** The tests assert that
each *resource* resolves. A view that reaches for the wrong resource, or none,
is caught by `Tools/assert-localisation.py` reading the source, not by anything
observing a rendered tree.

**`URLError` and `LAError` keep Foundation's own descriptions.** They are
already localised, in the reader's language, and with more detail than a
catalog entry here could carry. `APIError.networkUnavailable` and
`BiometricAuthError.failed` pass them through.

---

## The gates

### `Tools/assert-localisation.py`

Runs in the lint job beside the Sendable, module-boundary and accessibility
audits. Like them it is syntactic — no toolchain, no simulator, and runnable on
Linux, which is where the scheduled agent can run it before pushing.

It closes the loop Xcode closes for an app target and does not close for a
package:

1. **No user-facing literal.** A curated list of SwiftUI APIs must not be called
   with a bare string outside preview code. This is the rule Xcode's extractor
   makes unnecessary for an app.
2. **Source and catalog agree, both ways.** Every key looked up must exist, and
   every key declared must be looked up. The second direction is the one that
   rots: a string removed from a screen leaves an entry a translator is still
   paid for.
3. **The tests cover every key.** A key with no entry in a resolution suite is a
   key the `Bundle.module` check does not cover.
4. **The catalog is well formed.** Comment, English value, `extractionState:
   manual`, plural entries with both English forms, and a format specifier in
   the key if and only if the value interpolates one.
5. **No plural assembled in Swift.**
6. **No `Layout` conformance that never reads `layoutDirection`.**
7. **No `LocalizedStringResource` built outside a strings file**, which is the
   only place that passes `bundle:`.

Every rule was verified by reintroducing the defect it names and watching the
script fail on it.

Preview code is excluded: the `Previews/` folders, and everything from a
`// MARK: - Preview` heading or the first `#Preview` to the end of a file.
`AppButton("Sign In")` in a preview is a sample, and a sample in a catalog is an
entry somebody is paid to translate.

### The test suites

`LocalisationTests` and `FeatureLocalisationTests` hold one pair per catalog key
— the resource and the key it was built from — and assert that resolving it
gives back something **other than the key**. That is the assertion that fails if
a `bundle:` argument is ever dropped, and it is why the pair lists have to match
the catalogs exactly, which rule 3 above enforces.

`PluralisationTests` asserts the plural machinery rather than the English: that
the key carries its specifier, that the catalog's `variations.plural` block
survived compilation into a `.stringsdict`, and that selection happens on the
count — including that exactly one form in `0...20` is singular, which is the
whole of English's rule and includes zero, which English pluralises and several
other languages do not.

`FlowLayoutDirectionTests` owns the mirror arithmetic; the right-to-left case in
`FlowLayoutRenderTests` owns the one thing it cannot reach, that SwiftUI carries
the environment's layout direction into `LayoutSubviews` and that the
conformance reads it there.

---

## Adding a string

1. Add the key to the target's `Localizable.xcstrings`, with a `comment` saying
   what it is and where it appears — that comment is the only context a
   translator gets — an `en` `stringUnit`, and `"extractionState": "manual"`.
2. Add an accessor to that target's strings namespace.
3. Add the pair to the matching resolution suite.
4. Use it: `Text(resource)` where SwiftUI takes a `Text`, `.string` elsewhere.

`python3 Tools/assert-localisation.py` fails on any of those left out.

## Adding a language

Add the locale to each `Localizable.xcstrings` — a `localizations` entry per
key, with every plural form that language needs. There is no code change:
`defaultLocalization` stays `en`, the accessors do not move, and the resolution
tests go on asserting against the source language. What will need a pass is the
layout, in the way the "What is *not* here" section above describes.
