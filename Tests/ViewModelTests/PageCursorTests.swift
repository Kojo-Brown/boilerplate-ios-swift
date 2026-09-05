import Foundation
import Testing
@testable import Core
@testable import Networking

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

    private func page(json: String) throws -> CursorPage<PagedItem> {
        try JSONDecoder.apiDecoder.decode(CursorPage<PagedItem>.self, from: Data(json.utf8))
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

// MARK: - The in-memory source

@Suite("InMemoryCursorPageSource — a real conformer that answers from an array")
@MainActor
struct InMemoryCursorPageSourceTests {

    @Test("Paging to the end yields every element exactly once, in order")
    func itWalksTheWholeCollectionExactlyOnce() async {
        let source = InMemoryCursorPageSource(PagedItem.range(1...25))
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
        let source = InMemoryCursorPageSource(PagedItem.range(1...3))

        let slice = try await source.loadPage(after: nil, limit: 10)

        #expect(slice.items.count == 3)
        #expect(slice.nextCursor == nil)
    }

    @Test("A cursor it did not mint is rejected rather than read as zero")
    func aForeignCursorIsRejected() async throws {
        let source = InMemoryCursorPageSource(PagedItem.range(1...3))
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

    /// Wires a `MockAPIClient` that answers every request with ``pageJSON`` and
    /// records what it was asked.
    private func makeClient() -> (client: MockAPIClient, log: PageEndpointLog) {
        let client = MockAPIClient()
        let log = PageEndpointLog()
        let json = Self.pageJSON
        client.handler = { endpoint in
            await log.record(endpoint)
            return try JSONDecoder.apiDecoder.decode(CursorPage<PagedItem>.self, from: Data(json.utf8))
        }
        return (client, log)
    }

    @Test("The cursor and limit reach the request, and no idempotency key does")
    func theRequestCarriesTheCursorAndLimit() async throws {
        let (client, log) = makeClient()
        let source = APICursorPageSource<PagedItem>(
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
        let (client, log) = makeClient()
        let source = APICursorPageSource<PagedItem>(client: client, path: "/articles")

        _ = try await source.loadPage(after: nil, limit: 10)

        let endpoint = try #require(await log.endpoints.first)
        #expect(!endpoint.queryItems.contains(where: { $0.name == "cursor" }))
    }

    @Test("An endpoint that spells its parameters differently is configuration, not a new type")
    func parameterNamesAreConfigurable() async throws {
        let (client, log) = makeClient()
        let source = APICursorPageSource<PagedItem>(
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
