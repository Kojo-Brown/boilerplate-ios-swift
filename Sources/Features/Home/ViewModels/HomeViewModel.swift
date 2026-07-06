import Foundation
import Observation

/// A placeholder item surfaced on the home screen.
struct HomeItem: Identifiable {
    let id: UUID
    let title: String
    let subtitle: String
}

/// Manages state and business logic for the home screen.
@Observable
@MainActor
final class HomeViewModel: ViewModelProtocol {
    private(set) var items: [HomeItem] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    var searchQuery = ""

    var filteredItems: [HomeItem] {
        guard !searchQuery.isEmpty else { return items }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(searchQuery)
                || $0.subtitle.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    // MARK: - Lifecycle

    func onAppear() async {
        guard items.isEmpty else { return }
        await loadItems()
    }

    // MARK: - Actions

    func refresh() async {
        await loadItems()
    }

    func deleteItems(at offsets: IndexSet) {
        let targets = offsets.map { filteredItems[$0].id }
        items.removeAll { targets.contains($0.id) }
    }

    // MARK: - Private

    private func loadItems() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            items = try await fetchItems()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Stub — replaced by typed API client in Phase 3.
    private func fetchItems() async throws -> [HomeItem] {
        try await Task.sleep(for: .milliseconds(600))
        return (1...10).map {
            HomeItem(
                id: UUID(),
                title: "Item \($0)",
                subtitle: "Description for item \($0)"
            )
        }
    }
}
