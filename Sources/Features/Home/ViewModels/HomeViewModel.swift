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

    /// Stored `Task` reference for the live-update stream.
    /// Keeping a reference enables explicit cancellation in `onDisappear`,
    /// preventing orphaned work after the view leaves the screen.
    private var liveUpdateTask: Task<Void, Never>?

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

    /// Cancels all in-flight Tasks when the view disappears.
    func onDisappear() {
        stopLiveUpdates()
    }

    // MARK: - Actions

    func refresh() async {
        await loadItems()
    }

    func deleteItems(at offsets: IndexSet) {
        let targets = offsets.map { filteredItems[$0].id }
        items.removeAll { targets.contains($0.id) }
    }

    // MARK: - Live Updates via AsyncStream + Task

    /// Starts consuming a `PollingStream` and appending each yielded batch to `items`.
    ///
    /// The consuming `Task` is stored in `liveUpdateTask` so it can be cancelled
    /// via `stopLiveUpdates()` or `onDisappear()`. Cancelling the Task propagates
    /// into `PollingStream`'s inner task via `onTermination`, stopping all work.
    func startLiveUpdates(interval: Duration = .seconds(10)) {
        liveUpdateTask?.cancel()
        liveUpdateTask = Task {
            let stream = PollingStream.make(interval: interval) {
                // Stub — Phase 3 replaces this with a typed URLSession call
                [HomeItem(
                    id: UUID(),
                    title: "Live Update",
                    subtitle: "Streamed via AsyncStream at \(Date().formatted(.dateTime.hour().minute().second()))"
                )]
            }
            for await batch in stream {
                guard !Task.isCancelled else { break }
                items.append(contentsOf: batch)
            }
        }
    }

    /// Cancels the live-update Task, which propagates into the underlying `PollingStream`.
    func stopLiveUpdates() {
        liveUpdateTask?.cancel()
        liveUpdateTask = nil
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
