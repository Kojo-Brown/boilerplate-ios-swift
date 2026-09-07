import Core
import SwiftUI

/// Home screen driven by `HomeViewModel` via the Observation framework.
/// Navigation is handled by `AppCoordinator` — call `coordinator.push(_:)` to
/// navigate rather than embedding `NavigationLink` directly in the view.
///
/// Layout adapts to the horizontal size class: compact (iPhone) renders a `List`
/// while regular (iPad) switches to an `AdaptiveGrid` whose column count is
/// determined by `GeometryReader` + size classes.
package struct HomeView: View {
    @State private var viewModel: HomeViewModel
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @MainActor
    package init(dependencies: any HomeDependencies) {
        _viewModel = State(wrappedValue: dependencies.makeHomeViewModel())
    }

    package var body: some View {
        content
            .navigationTitle("Home")
            .searchable(text: $viewModel.searchQuery, prompt: "Search items")
            .refreshable { await viewModel.refresh() }
            .task { await viewModel.onAppear() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if viewModel.isLoading {
                        ProgressView()
                    } else {
                        Menu {
                            Button {
                                coordinator.push(.textRecognition)
                            } label: {
                                Label("Scan Text", systemImage: "text.viewfinder")
                            }
                            Button {
                                coordinator.push(.barcodeScanner)
                            } label: {
                                Label("Scan Barcode / QR", systemImage: "qrcode.viewfinder")
                            }
                            Button {
                                coordinator.push(.settings)
                            } label: {
                                Label("Settings", systemImage: "gearshape")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("More options")
                    }
                }
            }
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.filteredItems.isEmpty {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = viewModel.errorMessage {
            errorView(message)
        } else if viewModel.filteredItems.isEmpty {
            emptyView
        } else if horizontalSizeClass == .regular {
            itemGrid
        } else {
            itemList
        }
    }

    // MARK: - List layout (compact / iPhone)

    private var itemList: some View {
        List {
            ForEach(viewModel.filteredItems) { item in
                Button {
                    coordinator.push(.itemDetail(id: item.id, title: item.title))
                } label: {
                    HomeItemRow(item: item)
                        .equatable()
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in
                viewModel.deleteItems(at: offsets)
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Grid layout (regular / iPad)

    /// Uses `AdaptiveContainer` (`GeometryReader` + size classes) to resolve
    /// the optimal column count for the available canvas.
    private var itemGrid: some View {
        AdaptiveContainer { ctx in
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: 16),
                count: ctx.preferredColumnCount
            )
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(viewModel.filteredItems) { item in
                        Button {
                            coordinator.push(.itemDetail(id: item.id, title: item.title))
                        } label: {
                            HomeItemCard(item: item)
                                .equatable()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - Error / empty states

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Something went wrong", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") { Task { await viewModel.refresh() } }
                .buttonStyle(.borderedProminent)
        }
    }

    private var emptyView: some View {
        ContentUnavailableView(
            "No Items",
            systemImage: "tray",
            description: Text("Pull to refresh or check back later.")
        )
    }
}

// MARK: - Rows

/// The list row's content, in its own `Equatable` view.
///
/// Both row types below exist to be skipped. `HomeView`'s body reads
/// `viewModel.isLoading`, `viewModel.errorMessage` and `viewModel.searchQuery`,
/// so it re-runs on every keystroke in the search field and on both edges of
/// every load — and each of those evaluations rebuilds every visible row, none
/// of which has changed.
///
/// SwiftUI would like to skip them for us, but the comparison it falls back to
/// for a non-`Equatable` view inspects the view's memory, and `HomeItem` holds
/// two `String`s: reference-counted storage the framework cannot compare by
/// value. Conforming to `Equatable` replaces that guess with `HomeItem`'s own
/// `==`, and `.equatable()` at the call site is what tells SwiftUI to use it.
///
/// Two properties of this type are load-bearing and easy to lose in an edit:
///
/// * **`item` is the only stored property.** Everything the body renders comes
///   from it, so `==` is total: there is no captured value that can change
///   while the comparison reports equality and leaves a stale row on screen.
/// * **The tap action is not in here.** It stays on the `Button` in `HomeView`,
///   because it captures `coordinator`, and a closure cannot be compared. Held
///   here it would either be excluded from `==` — the stale-capture trap — or
///   force the type to be unequal on every rebuild, which is where it started.
///
/// Both are internal rather than `private` so `ViewIdentityTests` can hold them
/// to that first property: a stored property added without a matching line in
/// `==` is a stale row, and the test fails on it rather than the reader finding
/// it on screen.
struct HomeItemRow: View, Equatable {
    let item: HomeItem

    static func == (lhs: HomeItemRow, rhs: HomeItemRow) -> Bool {
        lhs.item == rhs.item
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(item.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// Card-style item used in the iPad grid layout. `Equatable` for the same
/// reason as ``HomeItemRow``, and more so: the grid renders more of these at
/// once, and each one carries a shadow and a clip shape to re-rasterise.
struct HomeItemCard: View, Equatable {
    let item: HomeItem

    static func == (lhs: HomeItemCard, rhs: HomeItemCard) -> Bool {
        lhs.item == rhs.item
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Text(item.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        HomeView(dependencies: PreviewHomeDependencies())
            .environment(AppCoordinator())
    }
}
