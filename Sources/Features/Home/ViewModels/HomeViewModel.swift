import Core
import Foundation
import Observation

/// A placeholder item surfaced on the home screen.
///
/// `Equatable` is not decoration. `ForEach` uses `id` to decide *which* row a
/// value belongs to, and SwiftUI uses equality to decide whether that row needs
/// rebuilding at all — `HomeItemRow` and `HomeItemCard` are `Equatable` views,
/// and their `==` is this one.
package struct HomeItem: Identifiable, Equatable, Sendable {
    package let id: UUID
    package let title: String
    package let subtitle: String
}

/// Manages state and business logic for the home screen.
@Observable
@MainActor
package final class HomeViewModel: ViewModelProtocol {

    package init() {}

    private(set) var items: [HomeItem] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    package var searchQuery = ""

    /// Stored `Task` reference for the live-update stream.
    /// Keeping a reference enables explicit cancellation in `onDisappear`,
    /// preventing orphaned work after the view leaves the screen.
    private var liveUpdateTask: Task<Void, Never>?

    package var filteredItems: [HomeItem] {
        guard !searchQuery.isEmpty else { return items }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(searchQuery)
                || $0.subtitle.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    // MARK: - Lifecycle

    package func onAppear() async {
        guard items.isEmpty else { return }
        await loadItems()
    }

    /// Cancels all in-flight Tasks when the view disappears.
    package func onDisappear() {
        stopLiveUpdates()
    }

    // MARK: - Actions

    package func refresh() async {
        await loadItems()
    }

    package func deleteItems(at offsets: IndexSet) {
        let targets = offsets.map { filteredItems[$0].id }
        items.removeAll { targets.contains($0.id) }
    }

    // MARK: - Live Updates via AsyncStream + Task

    /// Starts consuming a `PollingStream` and appending each yielded batch to `items`.
    ///
    /// The consuming `Task` is stored in `liveUpdateTask` so it can be cancelled
    /// via `stopLiveUpdates()` or `onDisappear()`. Cancelling the Task propagates
    /// into `PollingStream`'s inner task via `onTermination`, stopping all work.
    package func startLiveUpdates(interval: Duration = .seconds(10)) {
        liveUpdateTask?.cancel()
        liveUpdateTask = Task {
            let stream = PollingStream.make(interval: interval) {
                // Stub — Phase 3 replaces this with a typed URLSession call
                [
                    HomeItem(
                        id: UUID(),
                        title: "Live Update",
                        subtitle: "Streamed via AsyncStream at "
                            + Date().formatted(.dateTime.hour().minute().second())
                    ),
                ]
            }
            for await batch in stream {
                guard !Task.isCancelled else { break }
                items.append(contentsOf: batch)
            }
        }
    }

    /// Cancels the live-update Task, which propagates into the underlying `PollingStream`.
    package func stopLiveUpdates() {
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
        return Self.catalogue
    }

    /// The rows this stub stands in for a server's, minted once.
    ///
    /// This used to be `(1...10).map { HomeItem(id: UUID(), ...) }` *inside*
    /// `fetchItems()`, which gave every row a new identity on every fetch. A
    /// pull-to-refresh that changed nothing therefore replaced the whole list
    /// as far as SwiftUI was concerned: `ForEach` matches rows by `id`, so ten
    /// ids it had never seen mean ten rows removed and ten inserted. Every
    /// row's state — a disclosure toggle, a swipe part-way open, an in-flight
    /// transition — is discarded with the row it belonged to, the diff
    /// animates as a full replacement rather than as nothing happening, and
    /// none of it is visible in a test that only counts rows.
    ///
    /// Identity belongs to the row, not to the request that read it. A real
    /// backend supplies it and the client keeps it; this stub does the same by
    /// creating the ids once and handing back the same values every time.
    ///
    /// Deleting is local-only here, so a refresh brings a deleted row back.
    /// That is the stub being a stub — the delete never reached a server — and
    /// it behaved the same way before, with a new id on top of it.
    private static let catalogue: [HomeItem] = (1...10).map { index in
        HomeItem(
            id: UUID(),
            title: "Item \(index)",
            subtitle: "Description for item \(index)"
        )
    }
}
