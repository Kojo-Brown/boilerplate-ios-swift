import Foundation

// MARK: - Page-based pagination

/// Page-based paginated result returned by list endpoints.
package struct Page<T: Decodable & Sendable>: Decodable, Sendable {
    package let items: [T]
    package let pagination: PageInfo

    package enum CodingKeys: String, CodingKey {
        case items
        case pagination
    }
}

package struct PageInfo: Decodable, Sendable, Equatable {
    package let page: Int
    package let perPage: Int
    package let total: Int
    package let totalPages: Int

    package var hasNextPage: Bool { page < totalPages }
    package var hasPreviousPage: Bool { page > 1 }

    package enum CodingKeys: String, CodingKey {
        case page
        case perPage = "per_page"
        case total
        case totalPages = "total_pages"
    }
}

// MARK: - Cursor-based pagination

/// Cursor-based paginated result for infinite-scroll list endpoints.
package struct CursorPage<T: Decodable & Sendable>: Decodable, Sendable {
    package let items: [T]
    package let cursor: CursorInfo

    package enum CodingKeys: String, CodingKey {
        case items
        case cursor
    }
}

package struct CursorInfo: Decodable, Sendable, Equatable {
    package let nextCursor: String?
    package let prevCursor: String?
    package let hasMore: Bool

    package enum CodingKeys: String, CodingKey {
        case nextCursor = "next_cursor"
        case prevCursor = "prev_cursor"
        case hasMore = "has_more"
    }
}

// MARK: - Wire shape to paginator shape

extension CursorPage {

    /// Reduces the envelope to the one fact a paginator can act on.
    ///
    /// ``CursorInfo`` carries two answers to "is there more" — `has_more` and
    /// the presence of `next_cursor` — and they can disagree. ``PageSlice``
    /// carries one, so the disagreement has to be settled here, once, rather
    /// than at every call site that reads a page.
    ///
    /// `has_more` decides termination, because it is the field whose *purpose*
    /// is to say so: an API that emits a cursor on the last page (many do, so
    /// that a client polling for new rows has somewhere to resume from) would
    /// otherwise never terminate. A `has_more` of `true` with no cursor is the
    /// one combination that cannot be honoured either way, and throws.
    ///
    /// - Throws: ``PaginationError/moreItemsPromisedWithoutCursor`` or
    ///   ``PaginationError/unusableCursor(_:)``.
    package func slice() throws -> PageSlice<T> {
        guard cursor.hasMore else {
            return PageSlice(items: items, nextCursor: nil)
        }
        guard let raw = cursor.nextCursor else {
            throw PaginationError.moreItemsPromisedWithoutCursor
        }
        guard let next = PageCursor(rawValue: raw) else {
            throw PaginationError.unusableCursor(raw)
        }
        return PageSlice(items: items, nextCursor: next)
    }
}
