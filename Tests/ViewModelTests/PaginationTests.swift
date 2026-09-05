import Foundation
import SwiftUI
import Testing
@testable import Core
@testable import Features
@testable import Networking

// MARK: - Fixtures

private struct TestItem: Identifiable, Sendable, Equatable, Decodable {
    let id: Int

    static func range(_ ids: ClosedRange<Int>) -> [TestItem] {
        ids.map { TestItem(id: $0) }
    }
}

private struct ScriptedFailure: LocalizedError, Equatable {
    let reason: String

    var errorDescription: String? { reason }
}

/// One scripted answer from ``ScriptedPageSource``.
private enum PageOutcome: Sendable {
    case page(items: [TestItem], next: String?)
    case failure(ScriptedFailure)
}

/// A `CursorPageSource` whose answers are written in advance and whose requests
/// are recorded.
///
/// Answers are indexed by *call number* rather than taken off the front of a
/// queue. That distinction is the whole reason the superseded-page test below can
/// be written at all: two loads are in flight at once there, and with a queue the
/// page each of them received would depend on which one reached the front first —
/// which is the scheduling detail the test exists to be independent of.
private actor ScriptedPageSource: CursorPageSource {

    struct Request: Equatable, Sendable {
        let cursor: String?
        let limit: Int
    }

    private let outcomes: [PageOutcome]
    private let gate: TaskGate?
    private let ignoresCancellation: Bool

    private(set) var requests: [Request] = []

    /// Calls that got past the gate, whether they went on to answer or to throw.
    private(set) var answered = 0

    /// - Parameter ignoresCancellation: Makes a parked call finish even after its
    ///   task is cancelled, so a test can produce the one thing cancellation does
    ///   not prevent — a result arriving for a load nobody is waiting for.
    init(_ outcomes: [PageOutcome], gate: TaskGate? = nil, ignoresCancellation: Bool = false) {
        self.outcomes = outcomes
        self.gate = gate
        self.ignoresCancellation = ignoresCancellation
    }

    var requestCount: Int { requests.count }

    func loadPage(after cursor: PageCursor?, limit: Int) async throws -> PageSlice<TestItem> {
        let index = requests.count
        requests.append(Request(cursor: cursor?.rawValue, limit: limit))

        if let gate {
            if ignoresCancellation {
                await gate.waitForOpeningIgnoringCancellation(at: index)
            } else {
                try await gate.waitForOpening(at: index)
            }
        }

        answered += 1

        guard index < outcomes.count else {
            throw ScriptedFailure(reason: "the script has no answer for call \(index)")
        }

        switch outcomes[index] {
        case let .page(items, next):
            return PageSlice(items: items, nextCursor: next.flatMap { PageCursor(rawValue: $0) })
        case let .failure(error):
            throw error
        }
    }

    /// Waits until `count` requests have been *made*, so a test can order itself
    /// against work it started but is not holding.
    ///
    /// Polls for the reason `TaskGate` does: the actor is released at every
    /// sleep, which is what lets the calls being waited for get in.
    func waitForRequests(_ count: Int) async {
        while requests.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Waits until `count` calls have got past the gate.
    func waitForAnswers(_ count: Int) async {
        while answered < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor EndpointLog {
    private(set) var endpoints: [APIEndpoint] = []

    func record(_ endpoint: APIEndpoint) {
        endpoints.append(endpoint)
    }
}

// MARK: - The cursor itself

@Suite("PageCursor — an opaque token that has to survive being sent")
struct PageCursorTests {

    /// The blank cursor is the dangerous one: `?cursor=` reads as "no cursor" to
    /// most servers, which answers with page one — so a paginator that accepted
    /// it would re-read the first page for as long as the reader kept scrolling.
    @Test(
        "A cursor that cannot safely be sent is rejected",
        arguments: [
            "",
            " ",
            "\n",
            String(repeating: "c", count: PageCursor.maxLength + 1),
            "abc\u{0}def",
            "abc\rdef",
        ]
    )
    func unusableCursorsAreRejected(raw: String) {
        #expect(PageCursor(rawValue: raw) == nil)
    }

    /// The shapes real APIs actually emit. Narrowing to `IdempotencyKey`'s
    /// unreserved set would reject every one of them.
    @Test(
        "The cursor shapes real APIs emit are accepted",
        arguments: [
            "eyJpZCI6NDJ9",
            "Y3Vyc29yOjQy==",
            "1720000000.000000|42",
            "opaque+token/with=padding",
        ]
    )
    func realWorldCursorsAreAccepted(raw: String) throws {
        let cursor = try #require(PageCursor(rawValue: raw))

        #expect(cursor.rawValue == raw)
        #expect(cursor.description == raw)
    }

    @Test("A cursor of exactly the maximum length is accepted")
    func aMaximumLengthCursorIsAccepted() {
        let raw = String(repeating: "c", count: PageCursor.maxLength)

        #expect(PageCursor(rawValue: raw) != nil)
    }
}

// MARK: - The wire shape

@Suite("CursorPage.slice() — reconciling has_more with next_cursor")
struct CursorPageSliceTests {

    private func page(json: String) throws -> CursorPage<TestItem> {
        try JSONDecoder.apiDecoder.decode(CursorPage<TestItem>.self, from: Data(json.utf8))
    }

    @Test("A page with more to come carries the cursor forward")
    func aPageWithMoreCarriesItsCursor() throws {
        let decoded = try page(
            json: #"{"items":[{"id":1}],"cursor":{"next_cursor":"c2","prev_cursor":null,"has_more":true}}"#
        )

        let slice = try decoded.slice()

        #expect(slice.items.map(\.id) == [1])
        #expect(slice.nextCursor?.rawValue == "c2")
    }

    /// `has_more` decides, not the cursor's presence: an API that hands back a
    /// resume token on its last page — plenty do, for clients that poll for new
    /// rows — would otherwise never terminate.
    @Test("has_more false ends the list even when a cursor is still supplied")
    func hasMoreFalseEndsTheListDespiteACursor() throws {
        let decoded = try page(
            json: #"{"items":[{"id":9}],"cursor":{"next_cursor":"c9","prev_cursor":null,"has_more":false}}"#
        )

        let slice = try decoded.slice()

        #expect(slice.nextCursor == nil)
    }

    @Test("A promise of more items with no cursor to reach them is a failure")
    func moreItemsWithoutACursorThrows() throws {
        let decoded = try page(
            json: #"{"items":[{"id":1}],"cursor":{"next_cursor":null,"prev_cursor":null,"has_more":true}}"#
        )

        #expect(throws: PaginationError.moreItemsPromisedWithoutCursor) {
            try decoded.slice()
        }
    }

    @Test("A cursor the client cannot send is a failure rather than a silent stop")
    func anUnusableCursorThrows() throws {
        let decoded = try page(
            json: #"{"items":[{"id":1}],"cursor":{"next_cursor":"","prev_cursor":null,"has_more":true}}"#
        )

        #expect(throws: PaginationError.unusableCursor("")) {
            try decoded.slice()
        }
    }
}

// MARK: - The paginator

@Suite("CursorPaginator — walking a list without reading a row twice")
@MainActor
struct CursorPaginatorTests {

    // MARK: Reading forward

    @Test("The first request asks for no cursor and the policy's page size")
    func theFirstRequestAsksForTheFirstPage() async {
        let source = ScriptedPageSource([.page(items: TestItem.range(1...3), next: "c1")])
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
            .page(items: TestItem.range(1...3), next: "c1"),
            .page(items: TestItem.range(4...6), next: "c2"),
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
            .page(items: TestItem.range(1...3), next: "c1"),
            .page(items: TestItem.range(4...5), next: nil),
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
            .page(items: TestItem.range(1...3), next: "c1"),
            .page(items: [TestItem(id: 3), TestItem(id: 4)], next: nil),
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
            .page(items: TestItem.range(1...10), next: "c1"),
            .page(items: TestItem.range(11...20), next: nil),
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
                .page(items: TestItem.range(1...5), next: "c1"),
                .page(items: TestItem.range(6...10), next: nil),
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
            .page(items: TestItem.range(1...3), next: "c1"),
            .page(items: TestItem.range(7...9), next: nil),
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
                .page(items: TestItem.range(1...3), next: "c1"),
                .page(items: TestItem.range(4...6), next: "c2"),
                .page(items: TestItem.range(7...9), next: nil),
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
                .page(items: TestItem.range(1...3), next: "c1"),
                // Call 1 is the abandoned prefetch: it reaches the source and
                // dies at the gate, so the resumed load is call 2.
                .page(items: TestItem.range(4...6), next: nil),
                .page(items: TestItem.range(4...6), next: nil),
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
            .page(items: TestItem.range(1...3), next: "c1"),
            .failure(ScriptedFailure(reason: "the network went away")),
            .page(items: TestItem.range(4...5), next: nil),
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
            .failure(ScriptedFailure(reason: "offline")),
            .page(items: TestItem.range(1...2), next: nil),
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
            .page(items: TestItem.range(1...3), next: "c1"),
            .page(items: TestItem.range(4...6), next: "c1"),
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
            .page(items: TestItem.range(1...3), next: "c1"),
            .page(items: [], next: "c2"),
            .page(items: TestItem.range(4...5), next: nil),
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
            .page(items: TestItem.range(1...2), next: "c1"),
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
        let source = ScriptedPageSource([.page(items: TestItem.range(1...3), next: nil)])
        let sut = CursorPaginator(source: source)

        await sut.loadFirstPageIfNeeded()
        await sut.loadFirstPageIfNeeded()

        #expect(await source.requestCount == 1)
    }
}

// MARK: - The in-memory source

@Suite("InMemoryCursorPageSource — a real conformer that answers from an array")
@MainActor
struct InMemoryCursorPageSourceTests {

    @Test("Paging to the end yields every element exactly once, in order")
    func itWalksTheWholeCollectionExactlyOnce() async {
        let source = InMemoryCursorPageSource(TestItem.range(1...25))
        let sut = CursorPaginator(source: source, policy: PrefetchPolicy(pageSize: 10, distanceFromEnd: 3))

        await sut.loadFirstPageIfNeeded()
        var guardRail = 0
        while sut.canLoadMore && guardRail < 10 {
            await sut.loadNextPage()
            guardRail += 1
        }

        #expect(sut.items.map(\.id) == Array(1...25))
        #expect(sut.phase == .exhausted)
    }

    @Test("A collection shorter than one page ends on the first read")
    func aShortCollectionEndsImmediately() async throws {
        let source = InMemoryCursorPageSource(TestItem.range(1...3))

        let slice = try await source.loadPage(after: nil, limit: 10)

        #expect(slice.items.count == 3)
        #expect(slice.nextCursor == nil)
    }

    @Test("A cursor it did not mint is rejected rather than read as zero")
    func aForeignCursorIsRejected() async throws {
        let source = InMemoryCursorPageSource(TestItem.range(1...3))
        let cursor = try #require(PageCursor(rawValue: "not-an-offset"))

        await #expect(throws: PaginationError.unusableCursor("not-an-offset")) {
            try await source.loadPage(after: cursor, limit: 10)
        }
    }
}

// MARK: - The HTTP source

@Suite("APICursorPageSource — one GET per page")
@MainActor
struct APICursorPageSourceTests {

    private static let pageJSON = """
    {"items":[{"id":1},{"id":2}],"cursor":{"next_cursor":"c2","prev_cursor":null,"has_more":true}}
    """

    @Test("The cursor and limit reach the request, and no idempotency key does")
    func theRequestCarriesTheCursorAndLimit() async throws {
        let client = MockAPIClient()
        let log = EndpointLog()
        let json = Self.pageJSON
        client.handler = { endpoint in
            await log.record(endpoint)
            return try JSONDecoder.apiDecoder.decode(CursorPage<TestItem>.self, from: Data(json.utf8))
        }
        let source = APICursorPageSource<TestItem>(
            client: client,
            path: "/articles",
            queryItems: [URLQueryItem(name: "sort", value: "recent")]
        )
        let cursor = try #require(PageCursor(rawValue: "c1"))

        let slice = try await source.loadPage(after: cursor, limit: 25)

        #expect(slice.items.map(\.id) == [1, 2])
        #expect(slice.nextCursor?.rawValue == "c2")

        let endpoint = try #require(await log.endpoints.first)
        #expect(endpoint.method == .get)
        #expect(endpoint.path == "/articles")
        #expect(endpoint.idempotencyKey == nil)
        #expect(endpoint.queryItems.contains(URLQueryItem(name: "limit", value: "25")))
        #expect(endpoint.queryItems.contains(URLQueryItem(name: "cursor", value: "c1")))
        #expect(endpoint.queryItems.contains(URLQueryItem(name: "sort", value: "recent")))
    }

    @Test("The first page is requested without a cursor parameter at all")
    func theFirstRequestOmitsTheCursor() async throws {
        let client = MockAPIClient()
        let log = EndpointLog()
        let json = Self.pageJSON
        client.handler = { endpoint in
            await log.record(endpoint)
            return try JSONDecoder.apiDecoder.decode(CursorPage<TestItem>.self, from: Data(json.utf8))
        }
        let source = APICursorPageSource<TestItem>(client: client, path: "/articles")

        _ = try await source.loadPage(after: nil, limit: 10)

        let endpoint = try #require(await log.endpoints.first)
        #expect(!endpoint.queryItems.contains(where: { $0.name == "cursor" }))
    }

    @Test("An endpoint that spells its parameters differently is configuration, not a new type")
    func parameterNamesAreConfigurable() async throws {
        let client = MockAPIClient()
        let log = EndpointLog()
        let json = Self.pageJSON
        client.handler = { endpoint in
            await log.record(endpoint)
            return try JSONDecoder.apiDecoder.decode(CursorPage<TestItem>.self, from: Data(json.utf8))
        }
        let source = APICursorPageSource<TestItem>(
            client: client,
            path: "/articles",
            cursorParameterName: "after",
            limitParameterName: "first"
        )
        let cursor = try #require(PageCursor(rawValue: "c1"))

        _ = try await source.loadPage(after: cursor, limit: 5)

        let endpoint = try #require(await log.endpoints.first)
        #expect(endpoint.queryItems.contains(URLQueryItem(name: "after", value: "c1")))
        #expect(endpoint.queryItems.contains(URLQueryItem(name: "first", value: "5")))
    }
}

// MARK: - The list component

@Suite("PaginatedList — the SwiftUI half")
@MainActor
struct PaginatedListTests {

    @Test("The list builds a body in every phase it can be in")
    func theListRendersEachPhase() async {
        let source = ScriptedPageSource([
            .page(items: TestItem.range(1...3), next: "c1"),
            .failure(ScriptedFailure(reason: "offline")),
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
