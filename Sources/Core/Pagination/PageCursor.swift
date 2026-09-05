import Foundation

// MARK: - Cursor

/// An opaque continuation token handed back by a list endpoint, meaning "the
/// page after the one you just read".
///
/// ```swift
/// let slice = try await source.loadPage(after: nil, limit: 20)
/// let next = try await source.loadPage(after: slice.nextCursor, limit: 20)
/// ```
///
/// ## Why a cursor and not a page number
///
/// Offset pagination asks the server for rows 40–59 of an ordering it is free to
/// change between requests. Insert a row above the window and every later page
/// shifts down by one: the reader sees row 40 twice and never sees row 60 at
/// all. Delete one and a row is skipped entirely. Neither is a rare race — a
/// feed that anything writes to reorders under a reader who is simply scrolling
/// slowly, and the duplicate is what ``CursorPaginator`` spends a dictionary to
/// survive. ``PageInfo`` is still here because plenty of endpoints only offer
/// pages; this is what to reach for when the endpoint offers both.
///
/// A cursor names a *position in the ordering* — the sort key of the last row
/// delivered, usually encoded with a tiebreaker — so the next request means
/// "everything after this row" rather than "rows 40 onwards". Inserts above the
/// window do not move it.
///
/// ## Opaque, and treated as such
///
/// The contents are the server's business. Nothing here parses one, compares
/// two for ordering, or persists one across a launch: a cursor encodes a
/// position in a result set the server may have rebuilt since, and an expired
/// cursor is the one thing an API is entitled to reject. The only comparison
/// made anywhere is equality, and only to catch the server handing back the
/// cursor it was given — see ``PaginationError/cursorDidNotAdvance``.
///
/// ## Validation, and how it differs from `IdempotencyKey`
///
/// `IdempotencyKey` narrows to RFC 3986's unreserved set because it lands in an
/// HTTP *header*, where CR/LF would let whoever supplied it write headers of
/// their own. A cursor lands in a *query item*, which `URLComponents`
/// percent-encodes, so the injection concern is already handled and narrowing to
/// the unreserved set would reject the base64 and JSON cursors real APIs emit.
///
/// What is rejected instead is the one value that is actively dangerous:
/// **empty**. A blank cursor sent as `?cursor=` is read by most servers as "no
/// cursor", which returns page one — so a paginator that accepted it would fetch
/// the first page forever while the reader scrolled. Control characters are
/// rejected too, on the general principle that a value that cannot be logged
/// safely should not be carried, and the length is capped so a malformed token
/// cannot be the reason a request exceeds a proxy's URL limit.
package struct PageCursor: RawRepresentable, Hashable, Sendable, CustomStringConvertible {

    /// The longest cursor this type will carry.
    ///
    /// Comfortably above the encoded sort-key-plus-tiebreaker that a real cursor
    /// is, and far enough below the 8 KB request line that common proxies accept
    /// that a cursor can never be what makes a URL too long.
    package static let maxLength = 2048

    package let rawValue: String

    /// Adopts a cursor read out of a response body.
    ///
    /// - Returns: `nil` if `rawValue` is blank, longer than ``maxLength``, or
    ///   carries a control character.
    package init?(rawValue: String) {
        guard PageCursor.isUsable(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    /// Whether `value` is safe to send as the cursor query item.
    ///
    /// The blank check is `trimmingCharacters` rather than `isEmpty` on purpose:
    /// `" "` percent-encodes to `%20` and reaches the server as a cursor that
    /// points nowhere, which is the same failure as the empty one and would slip
    /// past an emptiness test.
    private static func isUsable(_ value: String) -> Bool {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.count <= PageCursor.maxLength else {
            return false
        }
        return value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    package var description: String { rawValue }
}

// MARK: - One page, as the paginator sees it

/// The items of one page plus the cursor that reaches the next, with the wire
/// format's redundancy already resolved.
///
/// This is deliberately not ``CursorPage``. The wire type carries both a
/// `next_cursor` and a `has_more`, which can disagree; this type carries one
/// fact, and `nextCursor == nil` is the *only* way a paginator learns it has
/// reached the end. Reconciling the two happens once, in ``CursorPage/slice()``,
/// rather than at every place that reads a page.
package struct PageSlice<Element: Sendable>: Sendable {

    package let items: [Element]

    /// The cursor for the page after this one, or `nil` when this is the last.
    package let nextCursor: PageCursor?

    package init(items: [Element], nextCursor: PageCursor?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

// MARK: - Errors

/// The ways a server's answer can be one a paginator cannot follow.
///
/// Every case here is a *server* defect rather than a transport failure, which
/// is why none of them is retryable: repeating the same request gets the same
/// unusable answer. They exist as distinct cases so the failure that reaches a
/// log says which contract was broken, instead of surfacing as a list that
/// silently stops growing.
package enum PaginationError: LocalizedError, Hashable, Sendable {

    /// `has_more` was true and `next_cursor` was absent. There is no way to ask
    /// for the page the server says exists.
    case moreItemsPromisedWithoutCursor

    /// A cursor arrived that ``PageCursor`` will not carry — blank, over-long,
    /// or carrying a control character. The payload is kept for the log; it is
    /// deliberately not in the message, because it is unvalidated server text.
    case unusableCursor(String)

    /// The server answered a request for "the page after X" with "the next page
    /// is X". Following it would re-read the same page forever, so the load
    /// stops here instead.
    case cursorDidNotAdvance

    /// Too many pages in a row contained nothing new.
    ///
    /// A page that adds no rows is legitimate — a server filtering rows the
    /// reader may not see returns one routinely — and ``CursorPaginator``
    /// follows it automatically rather than waiting for a scroll that cannot
    /// happen. This is the bound on that: past it, "the next page is empty too"
    /// is more likely a server walking a cursor that never terminates than a
    /// genuinely sparse result.
    case tooManyEmptyPages(limit: Int)

    package var errorDescription: String? {
        switch self {
        case .moreItemsPromisedWithoutCursor:
            "The server reported more items but sent no cursor to reach them."
        case .unusableCursor:
            "The server sent a page cursor that cannot be used."
        case .cursorDidNotAdvance:
            "The server returned the same page cursor it was given."
        case let .tooManyEmptyPages(limit):
            "Stopped after \(limit) empty pages in a row."
        }
    }
}
