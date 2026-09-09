import Core
import SwiftUI

// MARK: - Lazy paginated stack

/// A `ScrollView` + `LazyVStack` that loads its next page as the reader
/// approaches the end of it.
///
/// ```swift
/// LazyPaginatedStack(paginator) { article in
///     ArticleRow(article: article)
///         .equatable()
/// }
/// ```
///
/// The same contract as ``PaginatedList`` — ``CursorPaginator`` decides when to
/// load, this decides what the reader sees — over a different container, and
/// the difference is not cosmetic:
///
/// * `List` is a `UICollectionView` underneath. It **recycles**: a row scrolled
///   far enough out of view has its backing cell taken away and given to a row
///   coming in, so the memory a screenful of rows costs is the memory a
///   thousand rows cost.
/// * `LazyVStack` **realises**: a row is built when it first comes near the
///   viewport, and what happens to it afterwards is the framework's business
///   rather than a guarantee. What it buys is a layout `List` cannot express —
///   rows of genuinely different shapes, a custom separator, a header pinned by
///   `pinnedViews`, content that is not a list of rows at all — and full
///   control of the spacing and insets that `List` imposes.
///
/// Reach for ``PaginatedList`` when the screen is a list. Reach for this when it
/// is not, and take the three obligations below with it.
///
/// ## 1. The ids have to be stable
///
/// `ForEach(paginator.items)` keys each row on `Element.ID`, and that id is the
/// row's identity for as long as it is on screen: its `@State`, its scroll
/// position, its in-flight animation and its "have I appeared yet" all hang off
/// it. Two ways of writing the same loop throw that away:
///
/// ```swift
/// ForEach(items.indices, id: \.self) { index in       // identity is position
/// ForEach(Array(items.enumerated()), id: \.offset) {  // the same thing
/// ```
///
/// Under either, inserting a row at the top does not move any row's identity —
/// it moves every row's *content* down one slot while identity stays with the
/// slot. The reader sees each row's text change to its neighbour's, the state
/// each row was holding stays where it was, and the row that was actually added
/// never mounts at all. `LazyStackIdentityTests` measures exactly this.
///
/// A stable id is one that belongs to the row rather than to the request that
/// read it, which is the same requirement `HomeViewModel` was fixed to meet in
/// Phase 10 item 1 (see `docs/view-identity.md`): minting `UUID()` inside a
/// fetch produces ids that are technically unique and useless, because the next
/// fetch produces different ones for the same rows.
///
/// ## 2. `.id(...)` on a row is not a refresh
///
/// The recurring wrong fix — for a row that will not redraw, for a stack that
/// will not re-measure, for a scroll position that jumps — is to hang a
/// changing value off the row:
///
/// ```swift
/// row(item).id("\(refreshToken)-\(item.id)")  // don't
/// ```
///
/// That does force a redraw, by making every row a view SwiftUI has never seen
/// before: the whole realised range is torn down and rebuilt, every row's state
/// is discarded, transitions play as insertions, and in a lazy stack the rows
/// are re-measured from nothing so the scroll offset lands somewhere else. A row
/// that will not redraw has an `==` that is wrong or an id that is not stable,
/// and both are fixed where they are wrong. Nothing in this type applies `.id`.
///
/// ## 3. A page that fits on screen loads the next one
///
/// The prefetch trigger is `onAppear` per row, for the reasons ``PaginatedList``
/// sets out. In a lazy stack that trigger fires for every row the stack
/// realises, and a stack realises whatever fits in the viewport plus a buffer —
/// so if a whole page fits, its last row appears without anybody scrolling and
/// the next page is requested immediately. Chained, that is the entire
/// collection loaded at mount with the scrolling removed.
///
/// ``PrefetchPolicy`` already refuses the version of this that is unconditional
/// (`distanceFromEnd < pageSize` is a precondition). The rest is a sizing
/// question this type cannot answer for you: a page has to be taller than the
/// viewport, which means `pageSize` chosen against the shortest row the screen
/// can render, not the average. `LazyStackPrefetchTests` measures both sides —
/// tall rows load one page and stop, short rows chain.
///
/// ## Isolation and laziness
///
/// A `LazyVStack` is only lazy inside a scrolling container, which is what
/// gives it a visible rectangle to be lazy about. The same stack placed in a
/// plain `VStack` builds every row at mount — worth knowing before wrapping one
/// in something that measures its content, and worth knowing when reading the
/// test probes, which use exactly that to get a deterministic tree.
package struct LazyPaginatedStack<Element: Identifiable & Sendable, Row: View>: View {

    private let paginator: CursorPaginator<Element>

    private let spacing: CGFloat?

    @ViewBuilder private let row: (Element) -> Row

    /// - Parameters:
    ///   - paginator: The list, and everything that decides when to extend it.
    ///   - spacing: Distance between rows. `nil` takes the system spacing, as
    ///     `LazyVStack`'s own initialiser does.
    ///   - row: Builds one row. Make it `Equatable` and apply `.equatable()`
    ///     where the row is more than a `Text` — a lazy stack rebuilds every
    ///     realised row whenever this view's body runs, and this view's body
    ///     runs on every phase change.
    package init(
        _ paginator: CursorPaginator<Element>,
        spacing: CGFloat? = nil,
        @ViewBuilder row: @escaping (Element) -> Row
    ) {
        self.paginator = paginator
        self.spacing = spacing
        self.row = row
    }

    package var body: some View {
        ScrollView {
            LazyVStack(spacing: spacing) {
                ForEach(paginator.items) { item in
                    row(item)
                        .onAppear { paginator.prefetchIfNeeded(around: item) }
                }
                PaginationFooter(paginator)
            }
        }
        .task { await paginator.loadFirstPageIfNeeded() }
        .refreshable { await paginator.refresh() }
        .onDisappear { paginator.cancel() }
    }
}

// MARK: - Preview

/// A row for the preview below, sized so that a page is taller than the screen.
/// `InMemoryCursorPageSource` pages through these exactly as
/// `APICursorPageSource` pages through a server's, so the preview exercises the
/// prefetch trigger rather than illustrating it.
private struct PreviewFeedItem: Identifiable, Sendable {
    let id: Int
    let title: String

    static let samples: [PreviewFeedItem] = (1...120).map {
        PreviewFeedItem(id: $0, title: "Post \($0)")
    }
}

#Preview("Infinite scroll in a lazy stack") {
    NavigationStack {
        LazyPaginatedStack(
            CursorPaginator(
                source: InMemoryCursorPageSource(PreviewFeedItem.samples, delay: .milliseconds(400)),
                policy: PrefetchPolicy(pageSize: 15, distanceFromEnd: 4)
            ),
            spacing: 12
        ) { post in
            VStack(alignment: .leading, spacing: 6) {
                Text(post.title)
                    .font(.headline)
                Text("Row \(post.id) of \(PreviewFeedItem.samples.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .padding(16)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .navigationTitle("Feed")
    }
}
