import Foundation
import SwiftUI
import Testing
@testable import Core
@testable import Features
@testable import Networking

// Fixtures — `PagedItem`, `ScriptedPageSource` and friends — are in
// `PaginationProbes.swift`, shared with `PageCursorTests.swift`.

// MARK: - The paginator

@Suite("CursorPaginator — walking a list without reading a row twice")
@MainActor
struct CursorPaginatorTests {

    // MARK: Reading forward

    @Test("The first request asks for no cursor and the policy's page size")
    func theFirstRequestAsksForTheFirstPage() async {
        let source = ScriptedPageSource([.page(items: PagedItem.range(1...3), next: "c1")])
        let sut = CursorPaginator(source: source, policy: PrefetchPolicy(pageSize: 25, distanceFromEnd: 5))

        await sut.loadFirstPageIfNeeded()

        #expect(await source.requests == [ScriptedPageSource.Request(cursor: nil, limit: 25)])
        #expect(sut.items.map(\.id) == [1, 2, 3])
        #expect(sut.phase == .ready)
        #expect(sut.canLoadMore)
    }

    @Test("The next request carries the cursor the previous page returned")
    func theNextRequestCarriesThePreviousCursor() async {
        let source = ScriptedPageSource([
            .page(items: PagedItem.range(1...3), next: "c1"),
            .page(items: PagedItem.range(4...6), next: "c2"),
        ])
        let sut = CursorPaginator(source: source, policy: PrefetchPolicy(pageSize: 3, distanceFromEnd: 1))

        await sut.loadFirstPageIfNeeded()
        await sut.loadNextPage()

        #expect(await source.requests.map(\.cursor) == [nil, "c1"])
        #expect(sut.items.map(\.id) == [1, 2, 3, 4, 5, 6])
    }

    @Test("A page with no cursor ends the list, and nothing asks again")
    func aPageWithoutACursorExhaustsTheList() async {
        let source = ScriptedPageSource([
            .page(items: PagedItem.range(1...3), next: "c1"),
            .page(items: PagedItem.range(4...5), next: nil),
        ])
        let sut = CursorPaginator(source: source, policy: PrefetchPolicy(pageSize: 3, distanceFromEnd: 1))

        await sut.loadFirstPageIfNeeded()
        await sut.loadNextPage()

        #expect(sut.phase == .exhausted)
        #expect(!sut.canLoadMore)

        await sut.loadNextPage()
        sut.prefetchIfNeeded(around: sut.items[4])
        await sut.settled()

        #expect(await source.requestCount == 2)
    }

    /// Cursor pages overlap whenever a row is inserted mid-read. Two rows with
    /// the same `id` in a `ForEach` is undefined behaviour in SwiftUI, not a
    /// cosmetic repeat, so the paginator has to be the thing that stops it.
    @Test("A row delivered twice is kept once, in its original position")
    func aRepeatedRowIsDroppedRatherThanShownTwice() async {
        let source = ScriptedPageSource([
            .page(items: PagedItem.range(1...3), next: "c1"),
            .page(items: [PagedItem(id: 3), PagedItem(id: 4)], next: nil),
        ])
        let sut = CursorPaginator(source: source, policy: PrefetchPolicy(pageSize: 3, distanceFromEnd: 1))

        await sut.loadFirstPageIfNeeded()
        await sut.loadNextPage()

        #expect(sut.items.map(\.id) == [1, 2, 3, 4])
    }

    // MARK: Prefetching

    @Test("A row away from the end does not start a page")
    func prefetchIgnoresRowsAwayFromTheEnd() async {
        let source = ScriptedPageSource([
            .page(items: PagedItem.range(1...10), next: "c1"),
            .page(items: PagedItem.range(11...20), next: nil),
        ])
        let sut = CursorPaginator(source: source, policy: PrefetchPolicy(pageSize: 10, distanceFromEnd: 2))

        await sut.loadFirstPageIfNeeded()

        sut.prefetchIfNeeded(around: sut.items[0])
        sut.prefetchIfNeeded(around: sut.items[7])
        await sut.settled()

        #expect(await source.requestCount == 1)

        sut.prefetchIfNeeded(around: sut.items[8])
        await sut.settled()

        #expect(await source.requestCount == 2)
        #expect(sut.items.count == 20)
    }

    /// The property the whole prefetch design rests on. `onAppear` fires per row
    /// and a flick brings a page of them into view within a few frames; without a
    /// guard that decides *before it suspends*, every one of them becomes a
    /// request for the same cursor.
    @Test("A flick that appears a whole page of rows still makes one request")
    func concurrentPrefetchTriggersCollapseIntoOneRequest() async {
        let gate = TaskGate()
        let source = ScriptedPageSource(
            [
                .page(items: PagedItem.range(1...5), next: "c1"),
                .page(items: PagedItem.range(6...10), next: nil),
            ],
            gate: gate
        )
        let sut = CursorPaginator(source: source, policy: PrefetchPolicy(pageSize: 5, distanceFromEnd: 2))

        await gate.open(0)
        await sut.loadFirstPageIfNeeded()

        for item in sut.items {
            sut.prefetchIfNeeded(around: item)
        }

        // Synchronously, before any of those tasks has run: the second trigger
        // was turned away by a phase the first had already moved.
        #expect(sut.phase == .loadingNextPage)

        await gate.open(1)
        await sut.settled()

        #expect(await source.requestCount == 2)
        #expect(sut.items.count == 10)
    }

    // MARK: Refreshing

    @Test("A refresh replaces the list and starts again with no cursor")
    func refreshReplacesEverything() async {
        let source = ScriptedPageSource([
            .page(items: PagedItem.range(1...3), next: "c1"),
            .page(items: PagedItem.range(7...9), next: nil),
        ])
        let sut = CursorPaginator(source: source, policy: PrefetchPolicy(pageSize: 3, distanceFromEnd: 1))

        await sut.loadFirstPageIfNeeded()
        await sut.refresh()

        #expect(await source.requests.map(\.cursor) == [nil, nil])
        #expect(sut.items.map(\.id) == [7, 8, 9])
        #expect(sut.phase == .exhausted)
    }

    /// Cancellation alone does not cover this: a request past the point of no
    /// return still returns. The stale call here is deliberately built to finish
    /// *after* being cancelled, so the only thing that can discard it is the
    /// generation it was started in.
    @Test("A page from a superseded load never lands on the refreshed list")
    func aSupersededPageIsDropped() async {
        let gate = TaskGate()
        let source = ScriptedPageSource(
            [
                .page(items: PagedItem.range(1...3), next: "c1"),
                .page(items: PagedItem.range(4...6), next: "c2"),
                .page(items: PagedItem.range(7...9), next: nil),
            ],
            gate: gate,
            ignoresCancellation: true
        )
        let sut = CursorPaginator(source: source, policy: PrefetchPolicy(pageSize: 3, distanceFromEnd: 1))

        await gate.open(0)
        await sut.loadFirstPageIfNeeded()

        sut.prefetchIfNeeded(around: sut.items[2])
        await source.waitForRequests(2)

        await gate.open(2)
        await sut.refresh()

        await gate.open(1)
        await source.waitForAnswers(3)
        await sut.settled()

        #expect(sut.items.map(\.id) == [7, 8, 9])
        #expect(sut.phase == .exhausted)
    }

    @Test("Cancelling a prefetch leaves the list where it can resume")
    func cancellingAPrefetchLeavesAResumablePhase() async {
        let gate = TaskGate()
        let source = ScriptedPageSource(
            [
                .page(items: PagedItem.range(1...3), next: "c1"),
                // Call 1 is the abandoned prefetch: it reaches the source and
                // dies at the gate, so the resumed load is call 2.
                .page(items: PagedItem.range(4...6), next: nil),
                .page(items: PagedItem.range(4...6), next: nil),
            ],
            gate: gate
        )
        let sut = CursorPaginator(source: source, policy: PrefetchPolicy(pageSize: 3, distanceFromEnd: 1))

        await gate.open(0)
        await sut.loadFirstPageIfNeeded()

        sut.prefetchIfNeeded(around: sut.items[2])
        sut.cancel()
        await source.waitForRequests(2)

        #expect(sut.phase == .ready)
        #expect(sut.items.map(\.id) == [1, 2, 3])

        await gate.open(2)
        await sut.loadNextPage()

        #expect(sut.items.map(\.id) == [1, 2, 3, 4, 5, 6])
    }

    // MARK: Failing

    @Test("A failed page keeps its cursor, and a retry resumes rather than restarts")
    func aRetryResumesFromTheCursorThatFailed() async {
        let source = ScriptedPageSource([
            .page(items: PagedItem.range(1...3), next: "c1"),
            .failure(ScriptedPageFailure(reason: "the network went away")),
            .page(items: PagedItem.range(4...5), next: nil),
        ])
        let sut = CursorPaginator(source: source, policy: PrefetchPolicy(pageSize: 3, distanceFromEnd: 1))

        await sut.loadFirstPageIfNeeded()
        await sut.loadNextPage()

        #expect(sut.phase == .failed(message: "the network went away"))
        #expect(sut.items.map(\.id) == [1, 2, 3])

        await sut.retry()

        #expect(await source.requests.map(\.cursor) == [nil, "c1", "c1"])
        #expect(sut.items.map(\.id) == [1, 2, 3, 4, 5])
        #expect(sut.phase == .exhausted)
    }

    @Test("A first page that never arrived is retried from the start")
    func aFailedFirstPageIsRetriedFromScratch() async {
        let source = ScriptedPageSource([
            .failure(ScriptedPageFailure(reason: "offline")),
            .page(items: PagedItem.range(1...2), next: nil),
        ])
        let sut = CursorPaginator(source: source)

        await sut.loadFirstPageIfNeeded()

        #expect(sut.phase.errorMessage == "offline")

        await sut.retry()

        #expect(await source.requests.map(\.cursor) == [nil, nil])
        #expect(sut.items.map(\.id) == [1, 2])
    }

    /// Following it would re-read the same page for as long as the reader kept
    /// scrolling, and the rows already on screen would make it look like
    /// progress.
    @Test("A server that returns the cursor it was given stops the load")
    func aCursorThatDoesNotAdvanceStopsTheLoad() async {
        let source = ScriptedPageSource([
            .page(items: PagedItem.range(1...3), next: "c1"),
            .page(items: PagedItem.range(4...6), next: "c1"),
        ])
        let sut = CursorPaginator(source: source, policy: PrefetchPolicy(pageSize: 3, distanceFromEnd: 1))

        await sut.loadFirstPageIfNeeded()
        await sut.loadNextPage()

        #expect(sut.phase.errorMessage == PaginationError.cursorDidNotAdvance.localizedDescription)
        #expect(sut.items.map(\.id) == [1, 2, 3])
    }

    // MARK: Empty pages

    /// The deadlock this exists to prevent: the trigger for loading more is a row
    /// appearing, so a page that adds no rows produces no trigger and the scroll
    /// ends permanently with a spinner on screen and data behind it.
    @Test("A page that adds nothing is followed without waiting for a scroll")
    func anEmptyPageIsFollowedAutomatically() async {
        let source = ScriptedPageSource([
            .page(items: PagedItem.range(1...3), next: "c1"),
            .page(items: [], next: "c2"),
            .page(items: PagedItem.range(4...5), next: nil),
        ])
        let sut = CursorPaginator(source: source, policy: PrefetchPolicy(pageSize: 3, distanceFromEnd: 1))

        await sut.loadFirstPageIfNeeded()
        await sut.loadNextPage()

        #expect(await source.requests.map(\.cursor) == [nil, "c1", "c2"])
        #expect(sut.items.map(\.id) == [1, 2, 3, 4, 5])
        #expect(sut.phase == .exhausted)
    }

    @Test("Following empty pages is bounded, and the bound is a visible failure")
    func emptyPageFollowingIsBounded() async {
        let source = ScriptedPageSource([
            .page(items: PagedItem.range(1...2), next: "c1"),
            .page(items: [], next: "c2"),
            .page(items: [], next: "c3"),
            .page(items: [], next: "c4"),
        ])
        let policy = PrefetchPolicy(pageSize: 2, distanceFromEnd: 1, maxConsecutiveEmptyPages: 2)
        let sut = CursorPaginator(source: source, policy: policy)

        await sut.loadFirstPageIfNeeded()
        await sut.loadNextPage()

        let expected = PaginationError.tooManyEmptyPages(limit: 2)
        #expect(sut.phase.errorMessage == expected.localizedDescription)
        #expect(await source.requestCount == 3)
    }

    // MARK: Lifecycle

    @Test("A second appearance does not re-read a list that is already loaded")
    func loadingTheFirstPageIsIdempotent() async {
        let source = ScriptedPageSource([.page(items: PagedItem.range(1...3), next: nil)])
        let sut = CursorPaginator(source: source)

        await sut.loadFirstPageIfNeeded()
        await sut.loadFirstPageIfNeeded()

        #expect(await source.requestCount == 1)
    }
}

// MARK: - The list component

@Suite("PaginatedList — the SwiftUI half")
@MainActor
struct PaginatedListTests {

    @Test("The list builds a body in every phase it can be in")
    func theListRendersEachPhase() async {
        let source = ScriptedPageSource([
            .page(items: PagedItem.range(1...3), next: "c1"),
            .failure(ScriptedPageFailure(reason: "offline")),
        ])
        let paginator = CursorPaginator(source: source, policy: PrefetchPolicy(pageSize: 3, distanceFromEnd: 1))
        let view = PaginatedList(paginator) { item in
            Text("Row \(item.id)")
        }

        #expect(paginator.phase == .idle)
        _ = view.body

        await paginator.loadFirstPageIfNeeded()
        #expect(paginator.phase == .ready)
        _ = view.body

        await paginator.loadNextPage()
        #expect(paginator.phase.errorMessage == "offline")
        _ = view.body
    }
}
