import Core
import SwiftUI

// MARK: - Footer

/// What sits below the last row of a paginated collection: a spinner while a
/// page is in flight, the failure and a way past it, or the end of the list.
///
/// Extracted from ``PaginatedList`` when ``LazyPaginatedStack`` arrived, because
/// the two containers differ in exactly one respect — `List` versus
/// `ScrollView` + `LazyVStack` — and the footer is not it. A copy in each would
/// be two places for the retry button to drift out of step, and the retry
/// button is the only way past a failed page.
///
/// The empty cases are not oversights. With no rows yet there is nothing for a
/// footer to be below — the screen showing the collection owns its own empty
/// and first-load states, because only it knows what "no articles" should look
/// like.
///
/// ## `listRowSeparator` outside a `List`
///
/// The spinner, the failure and the end-of-list note each carry
/// `.listRowSeparator(.hidden)`. Inside ``PaginatedList`` that suppresses the
/// hairline `List` would otherwise draw above the footer; inside
/// ``LazyPaginatedStack`` there is no `List` to hear it and the modifier is
/// inert. That is the intended behaviour of a list-scoped modifier applied
/// outside a list, and it is why the footer can be shared unchanged rather than
/// parameterised on which container it is in.
package struct PaginationFooter<Element: Identifiable & Sendable>: View {

    private let paginator: CursorPaginator<Element>

    package init(_ paginator: CursorPaginator<Element>) {
        self.paginator = paginator
    }

    package var body: some View {
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
