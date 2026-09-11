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

    /// - Parameters:
    ///   - tracer: Marks the fetch and each search pass for Instruments. The
    ///     composition root passes a ``SignpostTracer``; a preview and a test
    ///     that is not measuring get the no-op, so being instrumented costs
    ///     nothing anywhere it is not being read.
    ///   - searchWork: Optional. Counts the search work this screen does, for
    ///     `SearchHotspotTests` to assert on.
    package init(
        tracer: any PerformanceTracing = NoOpTracer(),
        searchWork: SearchWorkLedger? = nil
    ) {
        self.tracer = tracer
        search = MemoizedSearch<HomeItem>(ledger: searchWork, tracer: tracer) { item in
            [item.title, item.subtitle]
        }
    }

    private(set) var items: [HomeItem] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /// Increments on every write to ``items``.
    ///
    /// It is the cache key for ``search`` — see `MemoizedSearch` for why the
    /// corpus is stamped rather than compared — and it is also what keeps
    /// `filteredItems` observable. Observation tracks the properties a getter
    /// reads; the search cache is not one, so a `filteredItems` that read only
    /// the cache would hand SwiftUI rows it had registered no dependency on,
    /// and the list would stop updating when the rows changed.
    private(set) var itemsVersion = 0

    package var searchQuery = ""

    private let tracer: any PerformanceTracing
    private let search: MemoizedSearch<HomeItem>

    /// Stored `Task` reference for the live-update stream.
    /// Keeping a reference enables explicit cancellation in `onDisappear`,
    /// preventing orphaned work after the view leaves the screen.
    private var liveUpdateTask: Task<Void, Never>?

    /// The rows matching ``searchQuery``.
    ///
    /// This was the screen's hotspot, and it looked like this:
    ///
    /// ```swift
    /// items.filter {
    ///     $0.title.localizedCaseInsensitiveContains(searchQuery)
    ///         || $0.subtitle.localizedCaseInsensitiveContains(searchQuery)
    /// }
    /// ```
    ///
    /// Nothing about that is wrong, which is why it survived nine phases. What
    /// it costs is invisible in the source and doubly so: a locale-aware
    /// collation per element — `HomeView.content` reads this property up to
    /// four times per body evaluation, and the body re-runs on every keystroke.
    ///
    /// `SearchIndex` moves the locale work to where the corpus changes, and
    /// `MemoizedSearch` makes the four reads one pass. See `docs/profiling.md`
    /// for how to see it in Instruments and `SearchHotspotTests` for the
    /// counts that hold it there.
    package var filteredItems: [HomeItem] {
        search.results(for: searchQuery, corpusVersion: itemsVersion)
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

    /// Deletes the rows at `offsets` **of the filtered list**, which is what
    /// the user swiped.
    ///
    /// The filtered list is read once rather than per offset, and the targets
    /// are a `Set`: membership was a linear search through an `Array` inside a
    /// predicate that already runs once per row, so deleting *k* rows from *n*
    /// cost *n × k* comparisons. It is the same class of quiet quadratic as
    /// the one in `SearchIndex.appending(_:searchableText:)` — invisible at ten
    /// rows, and the reason a delete on a long list feels like a hang.
    package func deleteItems(at offsets: IndexSet) {
        let visible = filteredItems
        let targets = Set(offsets.map { visible[$0].id })
        setItems(items.filter { !targets.contains($0.id) })
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
                appendItems(batch)
            }
        }
    }

    /// Cancels the live-update Task, which propagates into the underlying `PollingStream`.
    package func stopLiveUpdates() {
        liveUpdateTask?.cancel()
        liveUpdateTask = nil
    }

    // MARK: - Private

    /// Replaces the corpus and keeps everything derived from it in step.
    ///
    /// The single writer. `items`, the version stamp and the search index have
    /// to move together — a stamp that is bumped without the index being
    /// rebuilt means a cached answer drawn from the previous rows — and one
    /// method is what makes that a property of the type rather than a rule
    /// three call sites have to remember.
    private func setItems(_ newItems: [HomeItem]) {
        items = newItems
        itemsVersion &+= 1
        search.replace(newItems)
    }

    /// Appends to the corpus without refolding what is already indexed.
    private func appendItems(_ batch: [HomeItem]) {
        guard !batch.isEmpty else { return }
        items.append(contentsOf: batch)
        itemsVersion &+= 1
        search.append(batch)
    }

    private func loadItems() async {
        isLoading = true
        errorMessage = nil

        // The interval covers the `await`, so it is what a hitch on this
        // screen gets compared against in the trace. `defer` rather than a
        // line after the `do` block because a cancelled fetch leaves through
        // neither branch, and an interval that is begun and never ended draws
        // in Instruments as a region running to the end of the trace — which
        // reads as exactly the hang somebody opened the trace to find.
        let loading = tracer.begin(.homeLoad)
        defer {
            tracer.end(loading)
            isLoading = false
        }

        do {
            let fetched = try await fetchItems()
            setItems(fetched)
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
