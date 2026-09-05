import Core
import SwiftUI

// MARK: - Paginated list

/// A `List` that loads its next page as the reader approaches the end of it.
///
/// ```swift
/// PaginatedList(paginator) { article in
///     Text(article.title)
/// }
/// ```
///
/// Everything that decides *when* to load is in ``CursorPaginator``; this is the
/// three places a SwiftUI list has to tell it what the reader is doing — a row
/// appeared, the screen appeared, the reader pulled to refresh — plus a footer
/// that renders the resulting phase.
///
/// ## Why the trigger is `onAppear` on the row
///
/// The alternatives are worse in ways that are not obvious:
///
/// * **A `GeometryReader` sentinel at the bottom of the list** only fires when
///   the reader has already scrolled to the bottom, which is where a prefetch
///   is too late to be a prefetch.
/// * **`scrollPosition` / `onScrollGeometryChange`** report the scroll offset,
///   which has to be turned back into "which row is that" using row heights this
///   view does not know — and cannot know, with dynamic type in the picture.
/// * **`List(paginator.items)` with a trailing "load more" row** works, and puts
///   a spinner in front of the reader as a permanent fixture of the list.
///
/// `onAppear` per row is what the framework offers that means "this row is now
/// worth thinking about", and the cost of it firing dozens of times during a
/// flick is paid in ``CursorPaginator/prefetchIfNeeded(around:)``, which is a
/// dictionary lookup and two comparisons in the common case.
///
/// One caveat is worth stating because it shapes the paginator's design:
/// `onAppear` is **not** guaranteed for a row that is scrolled past between two
/// frames, and it never fires at all for a page that adds no rows. A trigger
/// that can be skipped is why the paginator follows an empty page itself rather
/// than waiting to be asked again.
package struct PaginatedList<Element: Identifiable & Sendable, Row: View>: View {

    private let paginator: CursorPaginator<Element>

    @ViewBuilder private let row: (Element) -> Row

    package init(
        _ paginator: CursorPaginator<Element>,
        @ViewBuilder row: @escaping (Element) -> Row
    ) {
        self.paginator = paginator
        self.row = row
    }

    package var body: some View {
        List {
            ForEach(paginator.items) { item in
                row(item)
                    .onAppear { paginator.prefetchIfNeeded(around: item) }
            }
            footer
        }
        .task { await paginator.loadFirstPageIfNeeded() }
        .refreshable { await paginator.refresh() }
        .onDisappear { paginator.cancel() }
    }

    // MARK: - Footer

    /// What sits below the last row: a spinner while a page is in flight, the
    /// failure and a way past it, or the end of the list.
    ///
    /// The empty cases are not oversights. With no rows yet there is nothing for
    /// a footer to be below — the screen showing this list owns its own empty
    /// and first-load states, because only it knows what "no articles" should
    /// look like.
    @ViewBuilder
    private var footer: some View {
        switch paginator.phase {
        case .idle, .ready:
            EmptyView()

        case .loadingFirstPage, .loadingNextPage:
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
                .listRowSeparator(.hidden)
                .accessibilityLabel("Loading more items")

        case .failed(let message):
            VStack(spacing: 8) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await paginator.retry() }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)

        case .exhausted where paginator.items.isEmpty:
            EmptyView()

        case .exhausted:
            Text("No more items")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
                .listRowSeparator(.hidden)
        }
    }
}

// MARK: - Preview

/// A row for the preview below. `InMemoryCursorPageSource` pages through these
/// exactly as `APICursorPageSource` pages through a server's, so the preview
/// exercises the prefetch trigger rather than illustrating it.
private struct PreviewArticle: Identifiable, Sendable {
    let id: Int
    let title: String

    static let samples: [PreviewArticle] = (1...120).map {
        PreviewArticle(id: $0, title: "Article \($0)")
    }
}

#Preview("Infinite scroll") {
    NavigationStack {
        PaginatedList(
            CursorPaginator(
                source: InMemoryCursorPageSource(PreviewArticle.samples, delay: .milliseconds(400)),
                policy: PrefetchPolicy(pageSize: 15, distanceFromEnd: 4)
            )
        ) { article in
            VStack(alignment: .leading, spacing: 4) {
                Text(article.title)
                    .font(.headline)
                Text("Row \(article.id) of \(PreviewArticle.samples.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("Articles")
    }
}
