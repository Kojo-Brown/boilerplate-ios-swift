import SwiftUI

/// Home screen driven by `HomeViewModel` via the Observation framework.
/// Navigation is handled by `AppCoordinator` — call `coordinator.push(_:)` to
/// navigate rather than embedding `NavigationLink` directly in the view.
struct HomeView: View {
    @State private var viewModel = HomeViewModel()
    @Environment(AppCoordinator.self) private var coordinator

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
                        Button {
                            coordinator.push(.settings)
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
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
        } else {
            itemList
        }
    }

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

// MARK: - Preview

#Preview {
    NavigationStack {
        HomeView()
            .environment(AppCoordinator())
    }
}
