import Foundation

// MARK: - Page-based pagination

/// Page-based paginated result returned by list endpoints.
struct Page<T: Decodable & Sendable>: Decodable, Sendable {
    let items: [T]
    let pagination: PageInfo

    enum CodingKeys: String, CodingKey {
        case items
        case pagination
    }
}

struct PageInfo: Decodable, Sendable, Equatable {
    let page: Int
    let perPage: Int
    let total: Int
    let totalPages: Int

    var hasNextPage: Bool { page < totalPages }
    var hasPreviousPage: Bool { page > 1 }

    enum CodingKeys: String, CodingKey {
        case page
        case perPage = "per_page"
        case total
        case totalPages = "total_pages"
    }
}

// MARK: - Cursor-based pagination

/// Cursor-based paginated result for infinite-scroll list endpoints.
struct CursorPage<T: Decodable & Sendable>: Decodable, Sendable {
    let items: [T]
    let cursor: CursorInfo

    enum CodingKeys: String, CodingKey {
        case items
        case cursor
    }
}

struct CursorInfo: Decodable, Sendable, Equatable {
    let nextCursor: String?
    let prevCursor: String?
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case nextCursor = "next_cursor"
        case prevCursor = "prev_cursor"
        case hasMore = "has_more"
    }
}
