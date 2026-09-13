# Custom layout: when `Layout` is the only thing that will do

Phase 10 item 4. `FlowLayout` is this package's `Layout` conformance, `TagChip`
is the component it exists for, and this file is why the pair could not be
written any other way.

## The problem

A row of tags. Each one is as wide as its own text plus its padding, they run
left to right, and when the next one does not fit it starts a new row.

Nothing about that is exotic, and no SwiftUI container ships that can do it:

| Container | What it does instead |
| --- | --- |
| `HStack` | Does not wrap. Past the trailing edge it compresses its subviews, so "Structured Concurrency" becomes "Structured Conc…" rather than moving to the next row. |
| `LazyVGrid` | Wraps into *columns*. Every cell in a column is as wide as the widest thing in it, so a row of "iOS" and "Structured Concurrency" either pads the short chip to the long one's width or squeezes the long one. |
| `VStack` of `HStack`s | Wraps, if something has already decided which chip belongs in which row. Nothing in a view body can decide that. |

That last row is the whole difficulty. Which chips fit on the first row depends
on the rendered width of every chip before them, and a chip's rendered width
does not exist until the text inside it has been measured — which happens
during layout, after every `body` in the tree has already run.

`GeometryReader` does not help, and it is worth being precise about why, because
it is the reflex answer. A `GeometryReader` reports the space its *parent*
offered it. It says nothing about how wide the text inside it wants to be, it
cannot be asked, and wrapping each chip in one to find out reads its own
proposed width rather than the chip's ideal width. The measurement a flow needs
is of its children, and `Layout` is the only API that provides it.

That is what "measure-dependent" means here, and it is the test for whether a
custom layout is warranted at all: **if the arrangement can be computed from
values already in the view's state, it is not a `Layout` — it is a `body`.**

## The shape of the implementation

`Layout` has two required methods and a lifecycle, and the split in this package
follows what each of them can be tested with.

```
FlowLayout        — the SwiftUI adapter: measures LayoutSubviews, places frames
    ↓ Item(size:, leadingSpacing:, firstBaseline:)
FlowLayoutEngine  — pure geometry: breaks lines, aligns them, returns frames
    ↓ Solution(lines:, frames:, size:)
FlowLayout        — offsets by bounds.origin and calls subview.place(…)
```

The reason for the split is that a `Layout` conformance cannot be unit tested.
Both of its methods take a `LayoutSubviews`, and there is no initialiser for
one — the only way to hold a value of that type is to be called by SwiftUI,
inside a tree SwiftUI is driving. Left as one type, every assertion about where
a line breaks would need a simulator, a hosting controller and a settle.

So `FlowLayoutEngine` takes measured sizes and returns frames, and
`FlowLayoutEngineTests` runs anywhere. What is left for the hosted
`FlowLayoutRenderTests` is the wiring, which is exactly the part that unit tests
of the engine cannot reach: a layout that measured at the wrong proposal, forgot
to offset by `bounds.origin`, or placed its subviews at a size other than the one
it broke lines with would pass every engine test and still draw the wrong thing.

## Four decisions worth knowing about

### Measure at `.unspecified`, place at what was measured

`FlowLayout` asks each subview for its size at an unspecified proposal — its
ideal size — and then places it at exactly that size. Proposing the container's
width instead would let a `Text` wrap itself to fill the row, and a flow with
one very long tag per line is not a flow.

The chip holds up the other end of this with `.fixedSize(horizontal: true,
vertical: false)`. Without it a label that would rather wrap than be narrow can
report one width during measurement and draw at another.

### Overflow is reported, not hidden

A flow cannot narrow a chip; it has no say in how wide the text is. So an item
wider than the container keeps its width, takes a line to itself, and the size
the flow reports is wider than the width it was proposed.

The alternative — reporting the proposed width and letting the item hang out of
the bounds — is how a custom layout ends up drawing outside its own frame with
nothing in the API to say it has. `overWideItemOverflowsRatherThanBeingSqueezed`
holds this.

### A proposal of zero is a real question

SwiftUI probes a layout at the zero size and at the infinite size before it
proposes the one it has. They are not noise to be clamped away — they are "how
narrow can you be?" and "how wide would you like to be?", and a flow has an
answer to both. Infinite width is one line; zero width is one item per line,
which reports the widest single item, which is the narrowest the flow can be
drawn without truncating anything.

### Spacing comes from the subviews unless a caller overrides it

`spacing` and `lineSpacing` are `CGFloat?`, and `nil` means "ask the subviews",
not "no gap". SwiftUI views carry spacing preferences — two pieces of text want
less air between them than a text and an image — and a container that hardcodes
a number throws that away. Horizontal spacing is resolved per adjacent pair,
exactly as `HStack` does it.

Line spacing is one value for the whole flow, and that is a deliberate
divergence. The exact answer would be the gap between the last item of one line
and the first item of the next, which cannot be known while the lines are being
formed — and resolving it afterwards, per line, would make the gap between two
rows depend on which chip happened to land at the end of a row. Widening the
container by a point could then change the spacing between rows that did not
move. One value for the whole flow is stable under reflow, which is the property
that matters for a container whose entire purpose is to reflow.

## The cache is not an optimisation detail

`Layout` is not called once per pass. SwiftUI probes with several proposals and
then calls `placeSubviews` with the winner, so a naive flow measures every
subview three or four times per frame — and measuring a subview runs the text
layout for a `Text`. Forty chips probed four times is a hundred and sixty text
measurements for one frame, none of which can change the answer: an item's ideal
size does not depend on the width it is going to be broken into.

`FlowLayoutCache` therefore holds two things with different lifetimes:

* **the measurements**, taken once and reused until `updateCache` says the
  subviews have changed;
* **the solved lines**, cached against the width they were solved for.

`measurePasses` and `solvePasses` are on the cache because no assertion about
geometry can tell a cache that works from one that silently re-measures — the
frames are identical either way. `FlowLayoutCacheTests` asserts the counts
directly: three widths, one measurement.

`updateCache` invalidates unconditionally rather than diffing. A subview whose
text changed keeps its identity and its position, so there is nothing in
`subviews` to compare against what was measured; re-measuring is one pass over
the subviews, and a stale line break is a visible defect.

## Baseline alignment, and why a flow declares one

`FlowLayout` implements `explicitAlignment(of:in:proposal:subviews:cache:)`,
which most custom layouts skip. Without it, a flow inside an
`HStack(alignment: .firstTextBaseline)` is aligned by the fallback SwiftUI uses
for a container that declares no baseline — its bottom edge — so a label beside
it sits level with the *last* row of chips rather than the first. Returning the
first line's baseline for `.firstTextBaseline` and the last line's for
`.lastTextBaseline` is what makes a flow composable with the text around it.

Within a line, `.firstBaseline` is the only alignment whose height is not simply
the tallest item: a line holding a deep ascent and a deep descent is taller than
either item on it. `baselineAlignmentAlignsBaselines` is the test that would
catch the easy mistake of using `max(height)` there.

## What is not done

**No screen adopts this yet.** `FlowLayout` and `TagChip` are exercised by their
previews and their tests; no feature in this package has tags to show. Wiring
them into a screen is a change to that screen's model, not to this component.

**Right-to-left is untested.** The layout places by leading edge in its own
coordinates, which is what `subview.place(at:anchor:)` mirrors for an RTL
environment — but nothing here asserts it, and the Phase 10 localisation item
(`Localisation with String Catalogs including plurals and an RTL pass`) is where
that belongs.

**Animation between reflows is the default.** `FlowLayout` conforms to
`Animatable` only through `Layout`'s default `EmptyAnimatableData`, so a change
in container width moves chips with whatever animation the surrounding
transaction carries, and a chip that moves between lines takes the direct path
rather than travelling along the flow. Making that path explicit needs real
animatable state and is a separate piece of work.

**Nothing is lazy.** Every subview is measured on every invalidation, because
`Layout` has no laziness to offer — the container is handed all of its subviews
up front. A flow of hundreds of chips is the wrong container; see
`docs/lazy-stacks.md`.
