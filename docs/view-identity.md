# View identity, `Equatable` views, and the bodies that stop running

Phase 10 item 1. Two different levers, often confused for one, and the
measurement that tells whether either of them did anything.

| Type | Module | What it is |
| --- | --- | --- |
| `BodyEvaluationLedger` | `Core` | A tally of evaluations, keyed by label |
| `BodyEvaluationProbe` | `Core` | Records one evaluation where it is placed |
| `Memoized<Key, Content>` | `Features` | Content rebuilt only when a key changes |
| `HomeItemRow` / `HomeItemCard` | `Features` | The shipped rows, now `Equatable` |
| `RenderHarness` | tests | A hosted tree, so the framework does the deciding |

## The two levers

**Identity** answers *which view is this?* Two renders that produce the same
identity are the same view continuing to exist: its `@State` survives, its
in-flight animations continue, its `onAppear` does not fire again. A view whose
identity changes is a different view — the old one is destroyed with everything
it was holding, and a new one is mounted in its place.

**Equality** answers *does this view need rebuilding?* It applies to a view
whose identity is unchanged, and decides whether SwiftUI runs its `body` or
reuses what it rendered last time.

Confusing them is expensive in both directions. Reaching for `.id(value)` to
"force a refresh" throws away state that was fine. Making a view `Equatable` in
the hope that rows stop being recreated does nothing if the ids under them keep
changing — the rows are not being rebuilt, they are being replaced.

## Identity: the defect this item fixed

`HomeViewModel.fetchItems()` minted its rows inside the fetch:

```swift
// Before
private func fetchItems() async throws -> [HomeItem] {
    try await Task.sleep(for: .milliseconds(600))
    return (1...10).map {
        HomeItem(id: UUID(), title: "Item \($0)", subtitle: "Description for item \($0)")
    }
}
```

Every pull-to-refresh produced ten rows with ten ids SwiftUI had never seen. To
`ForEach`, that is not "the same list, refreshed" — it is ten removals and ten
insertions. The list animates as a full replacement, every row's state goes
with the row that held it, and a test that counts rows sees nothing wrong
because the count is the same ten.

The fix is not a SwiftUI technique. It is that **identity is a property of the
row, not of the request that read it**: a server assigns an id and the client
keeps it. The stub now does the same, minting its catalogue once and returning
the same values from every fetch, and the test that asserted ids *must differ*
after a refresh now asserts the opposite.

The general rule for `ForEach`:

* Prefer an id the data owns — a server id, a natural key.
* `id: \.self` on a `String` or an `Int` is an id the *content* owns: edit the
  content and the row is replaced rather than updated. It is right for a list of
  constants and wrong for anything editable.
* An index is never an id. Delete the first row and every row below it changes
  identity.
* `.id(value)` on a view is a deliberate "destroy this and build a new one".
  That is occasionally exactly what is wanted — resetting a form, restarting an
  animation — and it is never a way to make an update arrive.

## Equality: what SwiftUI does without being asked

SwiftUI already tries to skip subtrees. When a body re-runs it compares the
values it produced against the previous ones and, where they match, leaves that
subtree alone. The catch is *how* it compares a view that is not `Equatable`: it
falls back to inspecting the view's memory, which works for a struct of
`Int`s and `Bool`s and cannot see through the reference-counted storage behind
a `String`, an `Array`, or a captured closure. A row holding two `String`s is
not reliably skipped, and nothing reports that it was not.

Conforming the view to `Equatable` replaces that guess with an answer:

```swift
struct HomeItemRow: View, Equatable {
    let item: HomeItem

    nonisolated static func == (lhs: HomeItemRow, rhs: HomeItemRow) -> Bool {
        lhs.item == rhs.item
    }

    var body: some View { /* … */ }
}

// At the call site — this is what tells SwiftUI to use the `==` above.
HomeItemRow(item: item)
    .equatable()
```

### `nonisolated` is not optional here

`View` is `@MainActor`, so everything declared inside one is main-actor
isolated by inference — including that operator. `Equatable`'s requirement is
nonisolated, an isolated function cannot satisfy it, and the build fails with
*"main actor-isolated operator function '==' cannot be used to satisfy
nonisolated requirement from protocol 'Equatable'"*. The keyword is what lets
SwiftUI call the comparison while diffing.

It brings a restriction with it, and the restriction is a feature: a
nonisolated member of an isolated type may only touch immutable properties
whose types are `Sendable`. So an `Equatable` view compares `let`s of value
types and nothing else — which is the same set of things it is *safe* to
compare. A view holding a `var`, or a reference into the screen's state, will
not compile as written, and that is the compiler pointing at the stale-capture
trap before it ships. `Memoized` inherits the same rule as a constraint on its
key: `Key: Equatable & Sendable`.

`HomeView`'s body reads `viewModel.isLoading`, `viewModel.errorMessage` and
`viewModel.searchQuery`, so it re-runs on every keystroke in the search field
and on both edges of every load. Without the conformance, each of those
evaluations rebuilds every visible row. With it, a row is rebuilt when the item
behind it changed and not otherwise.

### The rule that keeps it honest

**Everything the body renders must be reachable from what `==` compares.**

A value the view holds but `==` ignores is a value that can change while the
comparison says "unchanged" — and the row goes on displaying the old one. That
is a worse defect than the redundant evaluation being avoided, and it does not
show up as slowness, it shows up as a wrong number on screen that a scroll
sometimes fixes.

Two consequences shape the shipped rows:

* **The tap action is not in the row.** It stays on the `Button` wrapping it,
  because it captures the coordinator, and closures cannot be compared. Held in
  the row it would either be excluded from `==` — the stale-capture trap — or
  make the row unequal on every rebuild, which is where this started.
* **`HomeItem`'s `==` compares content, not just `id`.** Equality that stopped
  at the id would be cheaper and would freeze every row whose title was ever
  edited. `ViewIdentityTests` asserts exactly this: same id, changed title, not
  equal.

Two more things `==` cannot see, and which therefore must not be what a
memoised body depends on: `@Environment` reads and `@Observable` reads made
*inside* the closure rather than passed into it.

### When the subtree has no type of its own

`Memoized` is for content written inline, where giving it a named `Equatable`
view would be ceremony — and for the case where what the content should be
compared on is narrower than everything in scope:

```swift
Memoized(item) { item in
    ExpensiveRow(item: item)
}
```

Its own body is cheap and always runs. What it builds is an `EquatableView`
around a private view whose `==` compares nothing but the key, so an unchanged
key means the content closure is never called. The closure takes the key as its
argument on purpose: reading anything else from inside it is the stale-capture
trap above, written down.

## Measuring it

SwiftUI offers no supported way to ask how often a body ran. `Self._printChanges()`
is underscored, prints rather than returns, and answers *why* a view was
invalidated rather than how many times. So the tree keeps the count itself:

```swift
let ledger = BodyEvaluationLedger()

VStack {
    BodyEvaluationProbe("row", into: ledger)
    Text(item.title)
}
```

The probe records in `init`, not in `body`, because constructing it *is* the
enclosing body running — the `ViewBuilder` closure it sits in has been called.
Where it sits decides what is counted: directly in a parent's body it counts
that parent's evaluations; inside a `Memoized` closure it counts the
evaluations the memoisation did not skip.

The ledger is deliberately not `@Observable`. It is written to from inside a
body, so a view reading an observable ledger would invalidate itself on every
recording — the instrument would manufacture the redundant evaluations it
exists to count, and would not terminate.

Calling `body` by hand cannot measure any of this. `_ = view.body` proves a body
compiles and does not trap, which is what `ComponentPreviewProviderTests` uses
it for; it cannot answer "would SwiftUI have skipped this?", because the call
itself is the evaluation. Only the framework can answer that, and only for a
tree it is driving — so `RenderHarness` hosts the view in a `UIHostingController`
inside a `UIWindow`, mutates one value, pumps the run loop, and reads the counts
back:

```swift
let harness = RenderHarness(MemoisationHarness(ticker: ticker, ledger: ledger))
ledger.reset()                       // the first render is not redundant work

for _ in 1...3 {
    ticker.tick += 1                 // nothing any subtree is keyed on
    harness.settle()
}

#expect(ledger.count(of: ProbeLabel.inline) >= 3)
#expect(ledger.count(of: ProbeLabel.memoized) == 0)
#expect(ledger.count(of: ProbeLabel.equatable) == 0)
```

The asymmetry in those assertions is deliberate. The side that is supposed to
run is a lower bound, because SwiftUI evaluating a body more than once for a
single change is allowed and is not a defect. The side that is supposed to be
skipped is exact: zero.

## What is not done

* **No screen is measured in CI.** The harness proves the mechanisms; nothing
  asserts a bound on how many times `HomeView` itself evaluates a row during a
  search. That needs a fixture list and a keystroke-driving test, and it is
  closer to the Instruments item later in this phase than to this one.
* **`LazyVStack` and `List` row recycling are untouched.** A lazy container
  builds rows as they approach the viewport and can discard them behind it, so
  "how many evaluations" there is a question about scrolling, not about state
  changes. That is the next item in this phase.
* **The probe measures evaluations, not cost.** A body that runs twice as often
  but does nothing expensive is not a problem, and this instrument cannot tell
  the difference. Instruments can, and is the item after next.
* **Nothing enforces the `==`-covers-the-body rule.** It is checked by review
  and by the equality tests, which have to be extended by hand when a stored
  property is added to a row. A stored property added without a matching line in
  `==` compiles, renders, and goes stale.
