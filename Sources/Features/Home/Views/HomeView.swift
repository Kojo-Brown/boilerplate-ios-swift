import SwiftUI

/// Home screen driven by `HomeViewModel` via the Observation framework.
/// Navigation is handled by `AppCoordinator` — call `coordinator.push(_:)` to
/// navigate rather than embedding `NavigationLink` directly in the view.
///
/// Layout adapts to the horizontal size class: compact (iPhone) renders a `List`
/// while regular (iPad) switches to an `AdaptiveGrid` whose column count is
/// determined by `GeometryReader` + size classes.
struct HomeView: View {
    @State private var viewModel = HomeViewModel()
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
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

// MARK: - Grid card

/// Card-style item used in the iPad grid layout.
private struct HomeItemCard: View {
    let item: HomeItem

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
        HomeView()
            .environment(AppCoordinator())
    }
}
