import Core
import Foundation

// MARK: - HTTP page source

/// Reads pages of `Element` from a cursor-paginated list endpoint.
///
/// ```swift
/// let source = APICursorPageSource<Article>(client: client, path: "/articles")
/// let paginator = CursorPaginator(source: source)
/// ```
///
/// This is the whole of what `Networking` owes pagination: turn a cursor and a
/// limit into a `GET`, and turn the envelope that comes back into a
/// ``PageSlice``. Everything about *when* to ask lives in `CursorPaginator`, in
/// `Core`, where it can be tested without a server.
///
/// ## Why the parameter names are configurable and the shape is not
///
/// `cursor` and `limit` are the common spelling and the defaults, but they are
/// only a convention: `after`/`first`, `page[cursor]`/`page[size]` and
/// `next`/`per_page` are all in the wild, and an endpoint is not worth a
/// separate conformer just because it spells its query differently. The
/// *response* shape is fixed, because that is ``CursorPage`` — an endpoint that
/// answers in a different envelope needs its own `CursorPageSource`, which is
/// four lines and a decode.
///
/// ## No idempotency key, and no retry
///
/// A page read is a `GET`: repeating it is free, so there is nothing to
/// de-duplicate and `APIEndpoint.get` will not accept a key. Retrying it is
/// likewise not this type's job — the failure has to reach the paginator, which
/// is what keeps the cursor and what the reader retries through. A retry buried
/// here would turn a failed page into a spinner that lasts as long as the
/// backoff, with no way for the reader to give up on it.
package struct APICursorPageSource<Element: Decodable & Sendable & Identifiable>: CursorPageSource {

    private let client: any APIClient
    private let path: String
    private let queryItems: [URLQueryItem]
    private let cursorParameterName: String
    private let limitParameterName: String

    /// - Parameters:
    ///   - queryItems: Sent with every page — a filter or a sort order that the
    ///     cursor is relative to. They belong here rather than at the call site
    ///     precisely because they must not change between pages: a cursor is a
    ///     position in *one* ordering, and re-sorting mid-scroll makes it
    ///     meaningless.
    package init(
        client: any APIClient,
        path: String,
        queryItems: [URLQueryItem] = [],
        cursorParameterName: String = "cursor",
        limitParameterName: String = "limit"
    ) {
        self.client = client
        self.path = path
        self.queryItems = queryItems
        self.cursorParameterName = cursorParameterName
        self.limitParameterName = limitParameterName
    }

    package func loadPage(after cursor: PageCursor?, limit: Int) async throws -> PageSlice<Element> {
        var query = queryItems
        query.append(URLQueryItem(name: limitParameterName, value: String(limit)))
        if let cursor {
            query.append(URLQueryItem(name: cursorParameterName, value: cursor.rawValue))
        }

        let page: CursorPage<Element> = try await client.send(
            APIEndpoint.get(path, queryItems: query)
        )
        return try page.slice()
    }
}
