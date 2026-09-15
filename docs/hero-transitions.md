# Hero transitions and interactive dismissal

Phase 10 item 5. `HeroScope` is the presentation, `InteractiveDismissLayer` is
the gesture, `InteractiveDismissEngine` is the arithmetic under it, and this
file is why each of the three is shaped the way it is.

## What a hero transition is, mechanically

`matchedGeometryEffect(id:in:)` does one thing: it gives two views the same
identity for the purposes of geometry. While both are in the tree, one of them
is the **source** — the one whose frame is real — and the other is drawn at the
source's frame instead of its own. Change which one is the source inside an
animated transaction, and SwiftUI interpolates between the two frames. That
interpolation is the effect. There is no "hero" API; there is a frame swap and
an animation.

Everything that goes wrong with it follows from that one sentence.

## The rule, and why a proxy exists to enforce it

Exactly one view per `id` may be the source at a time.

| Sources | What happens |
| --- | --- |
| Two | SwiftUI logs `Multiple inserted views ... have the same key`, picks one, and the pair jumps rather than moves. |
| None | The destination has no frame to adopt and collapses to zero size. |
| One | The effect works. |

The trap is that neither failure is visible in the source of either view. A grid
cell that says `isSource: true` is correct on its own; so is a detail card that
says `isSource: true`. They are only wrong *together*, and the two declarations
are usually in different files.

So `HeroProxy` owns the decision and the two ends read it off:

```swift
func collapsedIsSource(_ id: ID) -> Bool { !isExpanded(id) }
func expandedIsSource(_ id: ID) -> Bool { isExpanded(id) }
```

which makes the invariant one line to assert — `collapsedIsSource(id) !=
expandedIsSource(id)`, for every id, in every state — rather than a convention
each call site has to remember. That assertion is `HeroProxyTests`, and it needs
no simulator.

The direction is worth stating too: the *collapsed* cell is the source until its
own card opens, and then the card is. That is what makes a collapse animate. By
the time the card is on screen the cell has already adopted the card's frame, so
removing the card hands the frame back along the path it arrived by.

## Why it is an overlay and not a push

`NavigationStack` cannot do this. A matched pair has to be in one view tree for
SwiftUI to interpolate between two frames, and a push is a change of tree: the
source is on the screen being covered, the destination is on the screen doing
the covering, and the pushed view has no way to reach the `Namespace` the
pusher declared.

So `HeroScope` is a `ZStack`: the collection, and the card above it.

That has a second consequence, and it is the one that makes the dismissal
interactive at all. The collection is still mounted behind the card — still
holding its scroll position, its selection, and every row's local state — so a
dismissal that is abandoned half-way returns to exactly what was there, with
nothing to restore. A push would have had to rebuild it.

It also has a cost, and it is not free: a hero overlay does not release what a
pushed screen would. For a grid of thumbnails that is the trade everyone makes.
For a detail screen that loads its own data, push and settle for a cross-fade.

`HeroTransitionRenderTests` measures the claim rather than repeating it. A
`ZStack` that rebuilds its first child and one that reuses it look identical in
the source, so the suite counts `onAppear`s: across a present-and-dismiss cycle,
the collection reports **zero** new appearances.

## Two orderings that are load-bearing

**The transform goes outside the matched-geometry modifier.**
`matchedGeometryEffect` records the frame of the view as it stands where the
modifier is applied. Apply a drag offset underneath it and the dragged position
is what gets recorded — so letting go half-way through a dismissal sends the
cell back to wherever the finger was, rather than to its slot in the grid.
`HeroScope` applies the drag transform outside whatever the `detail` closure
returns, which is why the closure marks its own end and the scope does not do it
for it.

**The card carries `.id(id)`.** Opening a different element while one is already
open is a different presentation, not the same one with new contents. Without an
explicit identity the card keeps its structural position in the `ZStack` and
SwiftUI reuses it: a drag in progress stays applied, a scroll position inside
the first card carries into the second, and — because nothing mounts — the new
pair never animates out of its own cell.

## The dismissal

Three decisions, none of which belongs in a gesture callback.

**The threshold is a fraction of the container, not a point count.** "150 points
dismisses" is a quarter of the way down an iPhone SE and a tenth of the way down
an iPad: the same gesture, two different meanings. `travelFraction` is 0.25, so
the distance that means "gone" is always a quarter of the screen in hand.

**Release is judged on where the drag was going.** A flick that travelled forty
points and was still moving at 1,200 points a second is a dismissal; a slow drag
that crept to a hundred and stopped is not. The translation is projected forward
by the release velocity before anything is measured, using UIKit's own constant
from *Designing Fluid Interfaces*:

```
projection = velocity × 0.499      // (velocity / 1000) × 0.998 / (1 − 0.998)
```

Half a second of coasting. Using the system's number means a flick that would
throw a scroll view past a paging boundary also dismisses a card, which is the
only definition of "the right amount" that generalises across hands.

**Movement against the dismissal resists rather than tracks.** A card dragged
upward that follows the finger leaves from the wrong edge and has nowhere to go.
The resistance is `UIScrollView`'s overscroll curve rather than a constant
factor, because a factor still lets a long drag throw the card off the top of
the screen and an asymptote cannot:

```
rubberBand(d) = (1 − 1 / (d × 0.55 / travel + 1)) × travel
```

Pull up as hard as you like: the card moves at most the distance that would have
dismissed it downward, and never further.

A fourth decision is a filter rather than a threshold. A hero card sits inside
scrollable, swipeable surroundings, so a mostly sideways drag is a page turn or
a back swipe that drifted down — `verticalDominance` requires the projected drag
to be at least as vertical as it is horizontal before it counts at all. It is
the most annoying false positive the component can produce, and the cheapest to
rule out.

## Why the engine is its own type

The same reason `FlowLayoutEngine` is: `DragGesture.Value` has no initialiser.
A test that wanted to assert "a flick of 1,200 points a second dismisses"
through the view would have to synthesise touches into a hosted window and hope
the gesture recogniser agreed — which measures UIKit's velocity smoothing, not
this repo's threshold.

So the thresholds, the projection, the rubber band and the transform live in
`InteractiveDismissEngine` as values in and values out, and
`InteractiveDismissLayer` is the adapter that feeds real drags through them.
`InteractiveDismissEngineTests` runs anywhere; the hosted suite is left with the
wiring.

## `@GestureState`, not `@State`

A dismissal can be interrupted by something that is not a finger lifting: an
incoming call, a system gesture claiming the touch, the view being removed under
it. `onEnded` does not run when a gesture is cancelled.

`@State` would keep the last translation it was handed and strand the card
half-dragged with nothing to put it back. `@GestureState` is reset by the
framework whenever the gesture stops for any reason, which makes the spring-back
the default and the dismissal the special case — the right way round, because
the failure mode of the default is "nothing happened" rather than "the screen is
stuck at an angle".

## Accessibility

Three things, none optional:

* **`.accessibilityAction(.escape)`.** A gesture-only dismissal is no dismissal
  for a VoiceOver user; escape is the gesture they already have for "close
  this".
* **`.isModal` on the card.** Without it a VoiceOver swipe wanders into the
  collection behind, which the reader cannot see and cannot act on.
* **Reduce Motion is honoured, and it does not mean "no animation".** An element
  that appears with no transition at all is harder to follow, not easier. What
  the setting asks for is the removal of the *travel* — the zoom across the
  screen — so `HeroScope` swaps the spring for a 200 ms ease. The matched
  geometry still runs and the card still lands in the right place; it simply
  gets there without the overshoot.

## What is not here

* **No `navigationTransition(.zoom)`.** It is the iOS 18 answer to the first
  half of this file and it is genuinely better where it applies: a real push,
  with the zoom and the interactive dismissal supplied by the system. This
  package targets iOS 17, so it is not available; when the floor moves, the
  push-shaped cases should move to it and this component should keep the cases
  that are overlays on purpose.
* **No velocity in the transform.** Velocity answers one question, asked once,
  at release. A transform that read it would flinch every time the finger
  changed speed.
* **No dismissal upward or sideways.** Both are a different gesture with a
  different meaning in the surroundings a card usually sits in. The engine
  refuses them rather than making the direction configurable, because the
  configuration would be a way to turn the sideways false positive back on.
