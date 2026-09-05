import Foundation

// MARK: - Protocol

/// Where ``CursorPaginator`` gets its pages from.
///
/// One method, and deliberately one: everything a paginator needs to ask is
/// "the page after this cursor, at most this many rows", and everything it
/// needs to hear back is in ``PageSlice``. Keeping the seam that narrow is what
/// lets the paginator be tested without a server, previewed without a network,
/// and pointed at a database-backed source later without changing.
///
/// It lives in `Core` rather than `Networking` because the paginator does, and
/// the paginator must not know that pages come from HTTP. `Networking` supplies
/// the implementation that does — `APICursorPageSource`.
///
/// ## Conformances are `Sendable`, and the method is `async`
///
/// A source is handed to a `@MainActor` paginator and called from it, but the
/// work is expected to happen elsewhere — a `URLSession` call, a database read.
/// `Sendable` is what lets a conformer be an `actor` or a value type with no
/// isolation of its own, and it is what stops one holding main-actor state by
/// accident.
package protocol CursorPageSource<Element>: Sendable {

    associatedtype Element: Identifiable & Sendable

    /// Reads one page.
    ///
    /// - Parameters:
    ///   - cursor: `nil` for the first page; otherwise the cursor from the
    ///     previous ``PageSlice``.
    ///   - limit: The most rows the caller wants. A source may return fewer —
    ///     the end of the collection, or a server's own smaller cap — and
    ///     returning fewer is never how the caller learns it has finished.
    ///     Only `nextCursor == nil` says that.
    func loadPage(after cursor: PageCursor?, limit: Int) async throws -> PageSlice<Element>
}

// MARK: - In-memory source

/// A source that pages through a fixed array. For previews and tests.
///
/// It is the pagination equivalent of `MockUserRepository`: a real conformer,
/// fully implemented, that happens to answer from memory. A `#Preview` built on
/// it scrolls and loads exactly as the shipping screen does, which a hardcoded
/// array of rows cannot demonstrate.
///
/// ## Its cursor is readable, and a real one is not
///
/// The cursor here is `offset:<n>`. That contradicts everything ``PageCursor``
/// says about opacity, and it is confined to this type for one reason: a test
/// asserting "the second request carried the cursor from the first" needs to be
/// able to *name* the value it expects. Nothing outside this type parses it —
/// ``CursorPaginator`` passes cursors back untouched — so the transparency buys
/// legible tests without teaching any production code to read a cursor.
package struct InMemoryCursorPageSource<Element: Identifiable & Sendable>: CursorPageSource {

    private static var offsetPrefix: String { "offset:" }

    private let elements: [Element]
    private let delay: Duration?

    /// - Parameter delay: Slows each page down so a preview shows its loading
    ///   state for long enough to look at. `nil` in a test, where a delay is
    ///   only a slower suite.
    package init(_ elements: [Element], delay: Duration? = nil) {
        self.elements = elements
        self.delay = delay
    }

    package func loadPage(after cursor: PageCursor?, limit: Int) async throws -> PageSlice<Element> {
        precondition(limit > 0, "A page limit of \(limit) asks for nothing and would never terminate")

        if let delay {
            try await Task.sleep(for: delay)
        }

        let start = try Self.offset(decoding: cursor)
        guard start < elements.count else {
            return PageSlice(items: [], nextCursor: nil)
        }

        let end = min(start + limit, elements.count)
        var next: PageCursor?
        if end < elements.count {
            next = try Self.cursor(at: end)
        }
        return PageSlice(items: Array(elements[start..<end]), nextCursor: next)
    }

    // MARK: - Cursor encoding

    private static func offset(decoding cursor: PageCursor?) throws -> Int {
        guard let cursor else { return 0 }
        guard cursor.rawValue.hasPrefix(offsetPrefix),
              let offset = Int(cursor.rawValue.dropFirst(offsetPrefix.count)),
              offset >= 0 else {
            throw PaginationError.unusableCursor(cursor.rawValue)
        }
        return offset
    }

    /// Throwing rather than force-unwrapping. `offset:12` cannot fail
    /// ``PageCursor``'s validation, but a `!` here would be a claim about that
    /// validation made in a second place, and the two could drift apart.
    private static func cursor(at offset: Int) throws -> PageCursor {
        let raw = "\(offsetPrefix)\(offset)"
        guard let cursor = PageCursor(rawValue: raw) else {
            throw PaginationError.unusableCursor(raw)
        }
        return cursor
    }
}
