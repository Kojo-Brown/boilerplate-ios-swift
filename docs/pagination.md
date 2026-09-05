# Cursor pagination and prefetch-on-scroll

Phase 9 item 6. Reading a list one page at a time, and asking for the next page
before the reader reaches the bottom of the last one.

The pieces:

| Type | Module | What it is |
| --- | --- | --- |
| `PageCursor` | `Core` | An opaque continuation token, validated once |
| `PageSlice<Element>` | `Core` | One page: rows plus the cursor after them |
| `CursorPageSource` | `Core` | "Give me the page after this cursor" |
| `CursorPaginator<Element>` | `Core` | The state machine and the trigger logic |
| `PrefetchPolicy` | `Core` | Page size, trigger distance, empty-page budget |
| `APICursorPageSource` | `Networking` | `CursorPageSource` over `APIClient` |
| `InMemoryCursorPageSource` | `Core` | The same, over an array, for tests and previews |
| `PaginatedList` | `Features` | The SwiftUI wiring: `List`, trigger, footer |

```swift
let paginator = CursorPaginator(
    source: APICursorPageSource<Article>(client: client, path: "/articles")
)

PaginatedList(paginator) { article in
    Text(article.title)
}
```

## Why a cursor and not `?page=3`

Offset pagination asks for rows 40–59 of an ordering the server is free to
change between requests. Insert a row above the window and every later page
shifts down by one: the reader sees row 40 twice and never sees row 60. Delete
one and a row is skipped. Neither is a rare race — a feed that anything writes
to reorders under a reader who is simply scrolling slowly.

A cursor names a *position in the ordering* — the sort key of the last row
delivered, with a tiebreaker — so the next request means "everything after this
row" rather than "rows 40 onwards". Inserts above the window do not move it.

`PageInfo` and `Page<T>` are still in `Sources/Core/Models/Pagination.swift`,
because plenty of endpoints only offer page numbers. `CursorPage<T>` is what to
reach for when an endpoint offers both.

## `has_more` and `next_cursor` can disagree

The wire type carries two answers to "is there more":

```json
{ "items": [...], "cursor": { "next_cursor": "eyJpZCI6NDJ9", "has_more": true } }
```

`PageSlice` carries one — `nextCursor == nil` is the only way a paginator learns
it has finished — so the disagreement is settled once, in `CursorPage.slice()`,
rather than at every call site that reads a page:

* **`has_more` decides termination.** It is the field whose purpose is to say so.
  An API that emits a cursor on its last page — many do, so a client polling for
  new rows has somewhere to resume from — would otherwise never terminate.
* **`has_more: true` with no cursor throws.** There is no way to ask for the page
  the server says exists, and a list that silently stopped growing would look
  exactly like a list that had ended.
* **A cursor `PageCursor` will not carry throws.** Most importantly the empty
  string: `?cursor=` reads as "no cursor" to most servers, which answers with
  page one, so accepting it would re-read the first page for as long as the
  reader kept scrolling.

`PageCursor`'s validation is deliberately wider than `IdempotencyKey`'s. A key
lands in an HTTP *header*, where CR/LF lets whoever supplied it write headers of
their own, so it narrows to RFC 3986's unreserved set. A cursor lands in a
*query item*, which `URLComponents` percent-encodes, so the injection concern is
already handled — and narrowing to the unreserved set would reject the base64
and JSON cursors real APIs emit.

## The four things the naive version gets wrong

Everything below is in `CursorPaginator`, and each has a test named after it in
`Tests/ViewModelTests/PaginationTests.swift`.

### 1. It fires the same request a dozen times

`onAppear` runs per row, and a flick brings thirty rows into view in a few
frames. Every one of them is a prefetch trigger, and without a guard every one
becomes a request for the same cursor.

The guard has to be **synchronous**. `prefetchIfNeeded(around:)` moves `phase` to
`.loadingNextPage` before it returns, so the second caller is turned away on the
main actor before the first has suspended:

```swift
package func prefetchIfNeeded(around item: Element) {
    guard canLoadMore, let cursor = nextCursor else { return }
    guard let index = indexByID[item.id] else { return }
    guard index >= items.count - policy.distanceFromEnd else { return }
    beginLoad(from: cursor, replacingContents: false, phase: .loadingNextPage)
}
```

A guard that awaited anything — a lock, an actor hop, the load itself — before
deciding would let all thirty through. This is also why the paginator is
`@MainActor` and holds no lock: the main actor *is* the lock, and it is the one
the trigger already runs on.

`indexByID` is a dictionary rather than a `Set` for the second guard.
`items.firstIndex(where:)` would answer "how far from the end is this row" with a
linear scan, on every one of those thirty appearances.

### 2. It shows a row twice

Cursor pages overlap whenever a row is inserted mid-read. Two rows with the same
`id` in a `ForEach` is undefined behaviour in SwiftUI, not a cosmetic repeat.

Every id appended is remembered, and a page re-delivering one is ignored — the
copy already on screen stays. Keeping the first is the conservative choice:
adopting the newer copy is defensible, but it means rows changing under a reader
who is only scrolling.

### 3. It appends a page the reader has already replaced

Pull-to-refresh while a next-page load is in flight ends with the old page
landing on top of the new list.

Cancellation alone does not fix it. A request past the point of no return still
returns — the response is already on the wire, and `Task.isCancelled` does not
reach into `URLSession`'s buffer. So every load carries the generation it started
in, and a result from an older one is dropped on arrival:

```swift
let slice = try await source.loadPage(after: cursor, limit: policy.pageSize)
guard loadGeneration == generation, !Task.isCancelled else { return nil }
```

`aSupersededPageIsDropped` builds exactly that: the stale call is scripted to
finish *after* being cancelled, so the generation check is the only thing that
can discard it.

Refresh also keeps the rows on screen while it runs — they are replaced when the
new first page lands, not when the request leaves — so `.refreshable` spins over
the list the reader was looking at rather than over an empty screen.

### 4. It deadlocks on an empty page

This is the one that does not look like a bug until it happens. The trigger for
loading more is *a row appearing*. A page that adds no rows — a server filtering
rows the reader may not see returns one routinely — produces no appearance, so
there is no trigger, and the scroll ends permanently with a spinner on screen and
more data behind it.

So a load that adds nothing follows its own cursor rather than returning, and
keeps following until a page contributes something or the list ends. That would
be an unbounded loop against a server whose cursor never terminates, so it is
bounded by `PrefetchPolicy.maxConsecutiveEmptyPages` and fails loudly past it.

The same reasoning is why `PrefetchPolicy` requires `distanceFromEnd < pageSize`.
At or above the page size, every arriving page lands entirely inside its own
trigger zone: the page that just loaded immediately requests the next one, and
the paginator walks the whole collection at full speed without anybody
scrolling — infinite scroll with the scrolling removed.

## Phases, not booleans

```swift
package enum PaginationPhase: Sendable, Equatable {
    case idle
    case loadingFirstPage
    case ready
    case loadingNextPage
    case exhausted
    case failed(message: String)
}
```

The alternative a list screen usually grows is `isLoading` / `isLoadingMore` /
`hasMore` / `errorMessage`: four booleans describing sixteen states, twelve of
which are unreachable, and the screen has to be written as though they were not.
Here a footer spinner and a full-screen spinner are different values, so
`PaginatedList`'s footer is a `switch`.

The failure carries a `String` rather than an error, for the reason
`ProfileFeature.Phase` gives: `LoadingState.failure` carries
`any Error & Sendable`, which cannot be `Equatable`, and a phase a test cannot
compare is a phase every assertion has to pattern-match its way into.
`SyncErrorMessage` would have been the thing to reuse; it lives in `Networking`,
which `Core` cannot see.

A failure keeps the cursor it was reaching for, so `retry()` resumes from where
it stopped rather than re-reading the list. Only a first page that never arrived
starts over.

## Why the trigger is `onAppear` on the row

The alternatives are worse in ways that are not obvious:

* A `GeometryReader` sentinel at the bottom of the list only fires once the
  reader has scrolled to the bottom, which is where a prefetch is too late to be
  a prefetch.
* `scrollPosition` / `onScrollGeometryChange` report an offset, which has to be
  turned back into "which row is that" using row heights the list does not know
  and cannot know with Dynamic Type in the picture.
* A trailing "Load more" row works, and puts a spinner in front of the reader as
  a permanent fixture of the list.

`onAppear` is what the framework offers that means "this row is now worth
thinking about". Its cost is that it fires constantly, which is paid for in the
guards above.

Its other cost is the reason for item 4: `onAppear` is **not** guaranteed for a
row scrolled past between two frames, and it never fires at all for a page that
adds no rows. A trigger that can be skipped is why the paginator follows an empty
page itself rather than waiting to be asked again.

## What is not done

* **No screen uses it yet.** `HomeViewModel` still fetches a hardcoded batch from
  the Phase 3 stub it was written with, and the API has no list endpoint to point
  `APICursorPageSource` at. Adopting the paginator on a real screen is a change
  to that screen, not to this machinery — `PaginatedList`'s preview drives the
  whole path against `InMemoryCursorPageSource` in the meantime.
* **Nothing is cached.** Every page is re-read from the network on a cold launch,
  and `refresh()` throws away what was loaded. Pages are not rows in the
  SwiftData store, so none of the offline-first machinery in
  `docs/offline-first.md` applies to them. A list that should survive a launch
  needs its pages persisted and its cursor persisted with them, which raises the
  question that document already answers for a single profile row: what a stale
  page is, and when it is worth showing.
* **Nothing pages backwards.** `CursorInfo.prevCursor` is decoded and unused.
  Bidirectional paging — a reader who enters a feed in the middle and scrolls
  both ways — needs two cursors, two trigger zones and a prepend that does not
  move the scroll position, which is a different design from this one rather
  than a parameter on it.
* **The empty-page budget is a constant, not a policy.** Four consecutive empty
  pages is a guess. A server that legitimately returns long runs of filtered
  pages would need it raised, and there is no signal here that would tell you to.
