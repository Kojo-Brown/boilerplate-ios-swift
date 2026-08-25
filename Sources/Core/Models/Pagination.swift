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
