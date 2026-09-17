# Accessibility

Phase 10 item 6. What this package publishes to VoiceOver, why each decision
went the way it did, and how the claims are checked rather than asserted.

Before this item, 135 source files carried eleven accessibility modifiers
between them, nine of which were in two files. That is not a pass that was done
badly — it is a pass that had not happened. What follows is the pass, the four
things it covers, and the parts that were considered and deliberately left
alone.

## How this is checked, and what could not be

The item set out to check the labels and traits below at runtime: host each
control, read the accessibility tree UIKit publishes from it, assert on what
came out. **That does not work in a unit-test process**, and the finding is
worth recording because it will come up again.

SwiftUI does not build its UIKit accessibility bridge unless an assistive
client is attached. `_UIHostingView.accessibilityElements` returns an *empty
array* — not nil, not a tree built on first access — and the text is drawn into
a `CGDrawingView` which is not an element and vends nothing:

```
_UIHostingView<...>       element=false elements=0   count=0 subviews=1
  PlatformContainer       element=false elements=nil count=0 subviews=1
    HostingScrollView     element=false elements=nil count=0 subviews=2
      PlatformGroupContainer element=false elements=nil count=0 subviews=1
        CGDrawingView     element=false elements=nil count=0 subviews=0
```

That was read off a window with a real `UIWindowScene`, made key and visible,
fully laid out, on the iOS 18.5 simulator, after the tree had rendered. It is a
gate rather than laziness, and no arrangement of windows gets past it. Reading
the published tree needs an XCUITest target with a host app, which this package
does not have — it belongs with the simulator-matrix item in Phase 12.

So the pass is verified two ways, and neither is the one that was wanted:

* **`Tools/assert-accessibility-audit.py`** checks the *shape* of the three
  defects in the source — a tap gesture with no `.accessibilityAction(named:)`
  beside it, a `.frame(maxWidth: .infinity)` followed by a `.frame(height:)`,
  an `Image(systemName:)` that is neither hidden nor named. Every exception is
  recorded with a reason and every recorded exception must still exist, the
  same both-directions rule the Sendable audit uses. It is syntactic, so it
  runs in the lint job on Linux — which is where the scheduled agent can run it
  before pushing, unlike every other gate in this repository.
* **`DynamicTypeTests`** measures heights through
  `UIHostingController.sizeThatFits(in:)`, which is the layout system rather
  than the accessibility system, and is unaffected by any of the above.

The gap this leaves is stated plainly: **nothing here verifies what VoiceOver
would actually say.** The labels, values, traits and rotor below are asserted
by reading the code, not by reading the tree. Each was checked against Apple's
documented behaviour for the modifier in question; none was observed.

## Labels

A label is the control's name. It answers "what is this", it does not change
when the control's state does, and it is what somebody says out loud when they
ask Siri to press it.

What was wrong, and is not now:

| Where | It announced | It announces |
|---|---|---|
| `AppButton` mid-request | "Sign In, button" — identical to idle | "Sign In, Loading" |
| `LoginView`'s sign-in button mid-request | nothing; the branch holding the word was not in the tree | "Sign In, Signing in" |
| `AppTextField` | its own name twice: "Email. Email, text field." | once |
| `BiometricAuthButton` | "faceid" then the label | the label |
| `TextRecognitionView`'s clear button | "xmark circle fill" | "Clear recognized text" |
| `TextRecognitionView`'s scan toggle | "play circle" / "pause circle" | "Start scanning" / "Pause scanning" |
| `SettingsView` while loading a profile | a nameless spinner, then a sentence | "Loading profile" |
| `HomeView`'s rows | title and subtitle run together as one long name | title as the name, subtitle as the value |

Two rules come out of that table and are worth stating on their own.

**A spinner is a picture.** It says "wait" to somebody who can see it and
nothing whatsoever to VoiceOver, which goes on reading the label the spinner
replaced — so a button mid-request and a button waiting to be pressed sound
identical, and the second press is the duplicate request. Every spinner in a
control is now hidden from the tree, and the wait is stated as the control's
*value* through `accessibilityBusy(_:doing:)`. The value, and not the label,
because a label is what a control *is*: folding "Loading" into it would make
the button a different control every time it was pressed.

**An icon-only control has no text to be named after.** Left alone it is
announced as the symbol's identifier — "xmark circle fill" — which is the
asset's name, not an answer to what pressing it does.

## Traits

A trait is what kind of thing an element is. The two failures here were both
the same shape: something that behaved like a control without being one.

`SettingsView`'s appearance picker was three rows carrying
`.contentShape(Rectangle())` and `.onTapGesture { selection.wrappedValue = scheme }`.
That is three separate failures wearing one costume:

1. A tap gesture publishes no `.isButton` trait, so VoiceOver announced each
   row as text and never offered to activate it.
2. It is not an activation point either, so double-tapping did nothing.
3. The current choice was a drawn checkmark, so the selected row and the other
   two sounded exactly alike.

The screen had a picker nobody using VoiceOver could operate or read the state
of. It is `AppearanceOptionRow` now: a `Button`, which fixes the first two by
being one, carrying `.isSelected` on top of `.isButton`, which is what
VoiceOver reads as "selected" and what the checkmark was drawing. The glyph is
hidden, because a row announcing both would say it twice.

`LoginView`'s error banner was the same mistake in a different costume — an
`HStack` with `.onTapGesture { clearError() }`, which meant the only way to
dismiss the banner was unavailable to exactly the people most likely to be
reading it slowly. It is `InlineErrorBanner` now: one combined element, named
"Error: …" because the triangle that says "error" to everybody else is hidden,
with dismissal offered as an `.accessibilityAction(named:)` running the same
closure the tap gesture does.

The banner stays `.isStaticText` rather than becoming a button. Its job is to
be read; dismissing it is a convenience on top, and a `.isButton` trait would
promise that activating it does something the reader wants, when what it does
is take the message away.

When a sign-in attempt fails, VoiceOver focus is moved to the banner with
`@AccessibilityFocusState`. A view that is merely inserted below the fields is,
to a reader still focused on the password field, nothing at all — the attempt
simply seems not to have happened.

## Dynamic Type

The accessibility feature with the widest reach and the least visible failures.
Nothing warns, no test goes red, and every preview in the package renders at
`.large`, where a control pinned to 50 points and one with a 50-point floor are
pixel-identical. They differ only at the sizes nobody on the team has the
simulator set to.

Three controls sat inside `.frame(height: 50)` — `AppButton`,
`BiometricAuthButton` and `LoginView`'s sign-in button. A fixed height is a
*maximum* as well as a minimum: fifty points hold a 17-point label with room to
spare and hold the same label at `AX5` not at all, so it was clipped through
the middle. `ScaledControlHeight` replaces the pin with `minHeight` and keeps
the floor itself in proportion through `@ScaledMetric`, so the control does not
stop being a comfortable target the moment its text outgrows it. Fifty points
at `.large` clears the 44-point minimum in the Human Interface Guidelines with
margin, and scales from there.

`DynamicTypeTests` measures each control at `.large` and again at an
accessibility size and asserts the second is taller. Comparisons rather than
absolute numbers, deliberately: a height of 50 at `.large` is not a bug and a
height of 50 at `AX5` is, so only reading both says which one you have — and an
absolute assertion would encode one iOS version's font metrics into the suite.
The sharpest of the three is the button mid-request, where the spinner's
intrinsic size does not move with the text size, so the height can only be
coming from the scaled floor.

Two fixed sizes are kept on purpose:

* **`LoginView`'s 56-point Swift glyph.** It is decoration, hidden from the
  tree, and a hero mark that tripled in height at `AX5` would push the form it
  introduces off the screen. What scales on that screen is the type.
* **`HomeItemCard`'s two- and three-line limits.** A card in a grid is meant to
  be uniform, and VoiceOver reads the whole string whether or not the last line
  of it is drawn, so the truncation costs a sighted reader at a large text size
  and costs a VoiceOver reader nothing. If that trade is revisited, note that
  the card is `Equatable` over exactly its stored properties — see
  `docs/view-identity.md` — so a line limit read from the environment has to
  arrive as a stored property that `==` compares, not as an `@Environment`
  read.

## The VoiceOver rotor

Labels and traits answer "what is this". A rotor answers "how do I get back to
it".

**Headings.** `.isHeader` is what puts a view on VoiceOver's built-in Headings
rotor, and it is the cheapest navigation this package can offer: with it, a
reader flicks between sections instead of swiping through every control in
them. `List` section headers already carry it. The three headings written by
hand did not, and now do — `LoginView`'s title, the camera-permission banner,
and `RecognizedTextHeading`.

**A rotor of its own, over recognized text.** `TextRecognitionView`'s results
panel was a single `Text(result.fullText)`: every block Vision found, joined
with newlines into one string. A paragraph is one accessibility element however
long it is, so a receipt with forty lines on it was one swipe that read for a
minute and a half, with no way to stop part-way, repeat a line or skip to the
total. Sighted readers were not reading it that way — their eyes jump between
lines — and nothing in the tree offered the same jump.

`RecognizedTextPanel` renders one `Text` per block, which makes each block its
own stop, and carries
`.accessibilityRotor(Text("Text blocks"), entries: result.blocks, entryLabel: \.text)`,
which makes the blocks reachable from anywhere on the screen. The two are a
pair: swiping is the linear access and the rotor is the random access. Visually
it is the same paragraph, drawn as a stack instead of a string, because the
blocks were already newline-separated.

The rotor's entries are the *same* array the `ForEach` walks rather than a
mapped copy. Entries are matched to rendered views by `Identifiable`
conformance, and a rotor entry whose id is in no `ForEach` is an entry
VoiceOver cannot move to.

## What is not covered

Stated rather than implied, because a document claiming a "full pass" invites
the assumption that everything below was done.

* **No VoiceOver was run.** The scheduled agent runs on Linux; CI runs a
  simulator, and — as the section at the top of this file records — the
  published tree cannot be read from a unit-test process either. `xcodebuild`
  cannot run VoiceOver, so this is a gap the gates here cannot close: an
  XCUITest journey with `XCUIDevice` accessibility auditing is the route, and
  it belongs with the simulator-matrix item in Phase 12.
* **Contrast is unmeasured.** Nothing here checks colour contrast ratios, and
  several of the semantic colours are opacity-modulated
  (`.secondary.opacity(0.3)`, `Color.red.opacity(0.1)`), which is where
  contrast failures concentrate.
* **`SignInWithAppleButton` and `GoogleSignInButton` are taken as given.** Both
  are vendor controls with their own accessibility; this package adds the
  in-flight value to the Apple one and otherwise leaves them alone. Their
  50-point frames stay, because neither renders text this package controls.
* **Reduce Motion is honoured in one place only.** `HeroTransition` reads
  `accessibilityReduceMotion` (Phase 10 item 5); the other animations in the
  package do not.
* **Voice Control labels are whatever the VoiceOver labels are.** No
  `.accessibilityInputLabels` are declared, so a control with a long name is
  spoken in full to activate it.
* **No screen is audited end to end**, and no *control* is either: see the
  section above. `LoginView` and `HomeView` also own their view models through
  `@State`, so even with a readable tree a test could not drive them into the
  states worth auditing. Extracting the two banners and the appearance row is
  what would make those states reachable, and the same move is what the rest
  would need.
* **The static audit checks shapes, not meanings.** It can tell that a symbol
  carries an `.accessibilityLabel`; it cannot tell that the label is a good
  one. "Button" would satisfy it.
