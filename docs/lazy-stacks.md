# Lazy stacks: stable ids, the `.id()` trap, and where prefetch comes from

Phase 10 item 2. `List` recycles rows for you and hides the consequences of
getting identity wrong. `LazyVStack` does neither, so a screen that leaves
`List` behind takes on three obligations at once.

| Type | Module | What it is |
| --- | --- | --- |
| `LazyPaginatedStack` | `Features` | `ScrollView` + `LazyVStack` over a `CursorPaginator` |
| `PaginationFooter` | `Features` | The spinner / failure / end-of-list footer, shared with `PaginatedList` |
| `ProbedRow`, `LazyRealisationHarness` | tests | Counts how many rows were actually built |
| `LazyIdentityHarness` | tests | The same rows keyed three ways, side by side |
| `LazyPaginationHarness` | tests | `LazyPaginatedStack` with a row height a test chooses |

## Realising is not recycling

`List` is a `UICollectionView`. A row scrolled far enough out of view has its
backing cell taken away and handed to a row coming in, so a thousand rows cost
what a screenful costs.

`LazyVStack` *realises*: a row is built when it comes near the viewport, and
what happens afterwards is the framework's business rather than a promise. What
that buys is the layout `List` will not express — rows of genuinely different
shapes, no separators or insets you did not ask for, a header pinned through
`pinnedViews`, content that is not a list of rows at all.

The laziness itself is real and measured. `LazyStackIdentityTests` mounts four
hundred 44-point rows in a 402 × 874 window and counts how many bodies ran:

```
lazy realised <a fraction> of 400; the plain VStack built 400
```

The bound asserted is "a fraction of four hundred", not a number. How far beyond
the viewport SwiftUI realises is undocumented and varies by OS version, and a
test that pinned it would be asserting an implementation detail rather than the
property the container is chosen for.

One corollary is easy to trip over and worth stating on its own: **a `LazyVStack`
is only lazy inside a scrolling container.** Without one it is handed a definite
height and builds every row, which is what makes the identity harness
deterministic — and what makes wrapping a lazy stack in something that measures
its content a way to lose the laziness silently.

## Obligation 1: the ids have to be stable

`ForEach(paginator.items)` keys each row on `Element.ID`. That id is the row's
identity: its `@State`, its scroll position, its in-flight animation and its
"have I appeared yet" all hang off it. Two spellings of the same loop throw it
away:

```swift
ForEach(items.indices, id: \.self) { index in       // identity is position
ForEach(Array(items.enumerated()), id: \.offset) {  // the same thing
```

Insert a row at the front under either, and no row's identity moves. Every row's
*content* moves down one slot while identity stays with the slot.

`prependMountsTheNewRowOnlyUnderStableIdentity` measures exactly that, with the
same five items rendered both ways under one root. `AppearanceCountingRow`
records once per lifetime — `onAppear` fires when a view is mounted and not
again while it stays mounted — so the counts read as identities, not as
evaluations:

| After inserting item `0` at the front | Stable ids | Index ids |
| --- | --- | --- |
| The inserted row mounts | 1 | **0** |
| The last row mounts again | 1 | **2** |

The second row of that table is the bug, stated as a measurement. Nothing new
appears at the front, because position 0 already existed and simply renders
different text now. A row mounts at the *end* instead, holding an item that was
already on screen a moment ago under a different identity. Read as a bug report
it is the familiar one: an expanded disclosure, a half-typed field or a running
animation stays with the position and ends up attached to whichever item slid
into that slot.

A stable id belongs to the row rather than to the request that read it. That is
the same requirement `HomeViewModel` was fixed to meet in Phase 10 item 1 — see
`docs/view-identity.md`, where minting `UUID()` inside a fetch produced ids that
were unique and useless.

## Obligation 2: `.id(...)` on a row is not a refresh

The recurring wrong fix — for a row that will not redraw, for a stack that will
not re-measure, for a scroll position that jumps — is to hang a changing value
off the row:

```swift
row(item).id("\(refreshToken)-\(item.id)")  // don't
```

It does force a redraw, by making every row a view SwiftUI has never seen
before. `changingTheRowTagRemountsEveryRow` bumps the token once and counts two
mounts per row where the stacks beside it, rendered by the same body and
invalidated by the same change, count one. What the second mount costs is
everything the first row was holding: state discarded, transitions replayed as
insertions, and — in a lazy stack specifically — rows re-measured from nothing,
so the scroll offset lands somewhere the reader did not leave it.

A row that will not redraw has an `==` that is wrong or an id that is not
stable. Both are fixed where they are wrong. `LazyPaginatedStack` applies `.id`
to nothing.

Two things that are *not* this trap, because the distinction is what makes the
rule usable:

* `.id()` on a whole screen to reset it deliberately — a new document, a new
  user — is the modifier doing its job. The cost is the point.
* Restoring a scroll position across a reload does not need `.id()` either;
  `scrollPosition(id:)` with `scrollTargetLayout()` is the supported answer and
  is not wired up here (see "What this does not do").

## Obligation 3: a page that fits on screen loads the next one

The prefetch trigger is `onAppear` per row, for the reasons `PaginatedList`'s
own documentation sets out — a bottom sentinel fires too late to prefetch, and
scroll geometry has to be turned back into "which row is that" using heights the
view does not know.

In a lazy stack that trigger fires for every row the stack realises, and a stack
realises whatever fits in the viewport plus a buffer. So if a whole page fits,
its last row appears without anybody scrolling and the next page is requested
immediately. Chained, that is the entire collection loaded at mount with the
scrolling removed.

`LazyStackPrefetchTests` measures both sides against the same catalogue and the
same window, with the row height as the only variable:

| Page | Row height | Page height vs. 874 pt viewport | Loaded at rest |
| --- | --- | --- | --- |
| 40 rows | 200 pt | 8000 pt — trigger row ~8 screens down | exactly one page |
| 12 rows | 44 pt | 528 pt — the whole page is visible | chains until the content outgrows the viewport |

`PrefetchPolicy` already refuses the unconditional version of this:
`distanceFromEnd < pageSize` is a precondition, because at or above the page
size every arriving page lands inside its own trigger zone. What it cannot check
is the sizing, and the sizing is the real rule: **a page has to be taller than
the viewport, so choose `pageSize` against the shortest row the screen can
render, not the average.** Dynamic Type at its smallest setting, a row whose
subtitle is empty, and an iPad in landscape all push in the same direction.

The chain is bounded rather than merely lucky, and
`chainedPrefetchesDoNotDuplicateRows` is what says so: every trigger that fires
while a load is in flight is turned away synchronously — `prefetchIfNeeded`
moves the phase before it returns — so the rows that arrive are each other's
successors, delivered exactly once and in order, rather than the same page
several times over.

## Choosing between the two containers

| | `PaginatedList` | `LazyPaginatedStack` |
| --- | --- | --- |
| Underneath | `List` (recycles) | `ScrollView` + `LazyVStack` (realises) |
| Separators, insets, spacing | `List`'s, adjustable | none unless you draw them |
| Swipe actions, `onDelete`, `EditMode` | yes | no |
| Section headers pinned while scrolling | `List`'s own | `pinnedViews` |
| Cost of getting identity wrong | rows shuffle | rows shuffle, and the scroll offset moves |

Reach for `PaginatedList` when the screen is a list. Reach for
`LazyPaginatedStack` when it is not.

Both share `PaginationFooter`, which is the only reason the choice is cheap to
revisit. The footer carries `.listRowSeparator(.hidden)` on each of its cases:
inside a `List` that suppresses the hairline above the footer, and inside a lazy
stack there is no list to hear it and the modifier is inert. A list-scoped
modifier applied outside a list doing nothing is the documented behaviour, and
it is why the footer needed no parameter for which container it is in.

## What this does not do

* **Scroll restoration.** `scrollPosition(id:)` over a `scrollTargetLayout()` is
  the iOS 17 answer for "put the reader back where they were", and it is not
  wired up here. It is a screen-level concern — what to restore, and when — more
  than a container-level one, and adding an unused binding to this type would
  have been a guess at the answer rather than the answer.
* **A scroll-driven prefetch test.** Both prefetch tests measure what a mount
  realises. Driving a real scroll from a test — programmatically or through the
  backing `UIScrollView` — would exercise the trigger the way a reader does, and
  is worth doing when there is a second thing that needs it.
* **Adopting the stack anywhere.** `HomeView` still renders a `List` on iPhone
  and a `LazyVGrid` on iPad, and neither is paginated. Moving a screen onto this
  container is a change to that screen, with its own item.
