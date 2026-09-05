import Foundation
import Observation

// MARK: - Phase

/// Where a paginated list has got to.
///
/// One enum rather than the `isLoading` / `isLoadingMore` / `hasMore` /
/// `errorMessage` quartet a list screen usually grows, for the reason
/// `ProfileFeature.Phase` gives: four booleans describe sixteen states, twelve
/// of which are not reachable, and the screen has to be written as though they
/// were. Here "loading the first page" and "loading the next page" are different
/// values, so a footer spinner and a full-screen spinner are a `switch` rather
/// than a conjunction.
///
/// ## Why the failure is a `String`
///
/// `LoadingState.failure` carries `any Error & Sendable`, which cannot be
/// `Equatable` — and a phase that a test cannot compare is a phase every
/// assertion has to pattern-match its way into. The error is caught at the one
/// place that can classify it and reduced to what the footer renders, exactly as
/// `SyncErrorMessage` does for the sync strategies. `SyncErrorMessage` itself is
/// not reused only because it lives in `Networking`, which `Core` cannot see.
package enum PaginationPhase: Sendable, Equatable {

    /// Nothing has been asked for yet.
    case idle

    /// The first page is in flight. Any items on screen are from a previous
    /// load being refreshed underneath the reader.
    case loadingFirstPage

    /// Items are loaded and there is at least one more page.
    case ready

    /// The next page is in flight, with items already on screen.
    case loadingNextPage

    /// Every page has been read.
    case exhausted

    /// A load failed. The cursor that failed is kept, so
    /// ``CursorPaginator/retry()`` resumes rather than restarts.
    case failed(message: String)

    package var isLoading: Bool {
        switch self {
        case .loadingFirstPage, .loadingNextPage:
            true
        case .idle, .ready, .exhausted, .failed:
            false
        }
    }

    package var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

// MARK: - Prefetch policy

/// How far from the end of the loaded rows the next page starts loading.
///
/// The numbers matter more than they look. `distanceFromEnd` is how much
/// unscrolled content a page load gets to complete behind; too small and the
/// reader hits the bottom and waits, which is the spinner that infinite scroll
/// exists to avoid.
package struct PrefetchPolicy: Sendable, Hashable {

    /// Rows requested per page.
    package let pageSize: Int

    /// How near the end a row has to be, in rows, for its appearance to start
    /// the next page.
    package let distanceFromEnd: Int

    /// How many consecutive pages may add nothing before the load gives up.
    /// See ``PaginationError/tooManyEmptyPages(limit:)``.
    package let maxConsecutiveEmptyPages: Int

    package static let `default` = PrefetchPolicy()

    /// - Precondition: `distanceFromEnd < pageSize`. At or above the page size,
    ///   every arriving page lands entirely inside its own trigger zone, so the
    ///   page that has just loaded immediately requests the next one and the
    ///   paginator walks the whole collection at full speed without anybody
    ///   scrolling — infinite scroll with the scrolling removed.
    package init(pageSize: Int = 20, distanceFromEnd: Int = 5, maxConsecutiveEmptyPages: Int = 4) {
        precondition(pageSize > 0, "A page size of \(pageSize) asks for nothing")
        precondition(distanceFromEnd >= 0, "A negative prefetch distance never triggers")
        precondition(
            distanceFromEnd < pageSize,
            "A prefetch distance of \(distanceFromEnd) at page size \(pageSize) loads every page at once"
        )
        precondition(maxConsecutiveEmptyPages > 0, "An empty-page budget of zero rejects the first page")
        self.pageSize = pageSize
        self.distanceFromEnd = distanceFromEnd
        self.maxConsecutiveEmptyPages = maxConsecutiveEmptyPages
    }
}

// MARK: - Paginator

/// Holds one cursor-paginated list and decides when to ask for more of it.
///
/// ```swift
/// let paginator = CursorPaginator(
///     source: APICursorPageSource<Article>(client: client, path: "/articles")
/// )
///
/// List(paginator.items) { article in
///     ArticleRow(article: article)
///         .onAppear { paginator.prefetchIfNeeded(around: article) }
/// }
/// .task { await paginator.loadFirstPageIfNeeded() }
/// .refreshable { await paginator.refresh() }
/// ```
///
/// `PaginatedList` in `Features` is that wiring, already written.
///
/// ## The four things a naive version of this gets wrong
///
/// **It fires the same request a dozen times.** `onAppear` runs per row, and a
/// flick scrolls thirty rows into view in a few frames. Every one of them is a
/// prefetch trigger, and without a guard every one becomes a request for the
/// same cursor. The guard has to be *synchronous* — ``prefetchIfNeeded(around:)``
/// moves ``phase`` to `.loadingNextPage` before it returns, so the second caller
/// is turned away on the main actor before the first has suspended. A guard that
/// awaited anything before deciding would let all thirty through.
///
/// **It shows a row twice.** Cursor pages overlap whenever rows are inserted
/// mid-read, and two rows with the same `id` in a `ForEach` is undefined
/// behaviour in SwiftUI, not a cosmetic repeat. Every id that has been appended
/// is remembered, and a page re-delivering one is ignored — the copy on screen
/// stays. Keeping the first is the conservative choice: adopting the newer copy
/// would be defensible, but it would also mean rows changing under a reader who
/// is only scrolling.
///
/// **It appends a page that belongs to a list the reader has already replaced.**
/// Pull-to-refresh while a next-page load is in flight ends with the old page
/// landing on top of the new list. Cancellation alone does not fix it: a request
/// past the point of no return still returns. So every load carries the
/// generation it started in, and a result from an older one is dropped on
/// arrival.
///
/// **It deadlocks on an empty page.** The trigger for loading more is a row
/// appearing; a page that adds no rows produces no appearance, so a filtered
/// page that comes back empty ends the scroll permanently with a spinner on
/// screen and more data behind it. A load that adds nothing therefore follows
/// its own cursor rather than returning — bounded by
/// ``PrefetchPolicy/maxConsecutiveEmptyPages``, so a server whose cursor never
/// terminates fails loudly instead of spinning.
///
/// ## Isolation
///
/// `@MainActor`, because `items` and `phase` are read from SwiftUI's `body` and
/// the prefetch trigger is called from a view. The work is not: the `source` is
/// `Sendable` and does its own I/O wherever it likes. Nothing here holds a lock,
/// because the main actor is the lock.
@Observable
@MainActor
package final class CursorPaginator<Element: Identifiable & Sendable> {

    /// Every row loaded so far, in the order the server delivered them, with
    /// repeats removed.
    package private(set) var items: [Element] = []

    package private(set) var phase: PaginationPhase = .idle

    @ObservationIgnored
    private let source: any CursorPageSource<Element>

    @ObservationIgnored
    private let policy: PrefetchPolicy

    /// The cursor for the page after the last one applied, or the one a failed
    /// load was reaching for. Kept out of observation deliberately: it changes
    /// with every page and nothing renders it — ``phase`` already says whether
    /// there is more.
    @ObservationIgnored
    private var nextCursor: PageCursor?

    /// Where each id sits in ``items``.
    ///
    /// A `Set` would be enough for de-duplication, but the prefetch trigger also
    /// needs "how far from the end is this row", and answering that with
    /// `items.firstIndex(where:)` is a linear scan on every one of the dozens of
    /// row appearances a single flick produces.
    @ObservationIgnored
    private var indexByID: [Element.ID: Int] = [:]

    @ObservationIgnored
    private var loadTask: Task<Void, Never>?

    /// Bumped whenever a load starts or is cancelled, so a result that arrives
    /// after the list has moved on can be recognised and dropped.
    @ObservationIgnored
    private var generation: UInt64 = 0

    package init(source: any CursorPageSource<Element>, policy: PrefetchPolicy = .default) {
        self.source = source
        self.policy = policy
    }

    /// Whether another page can be asked for right now.
    ///
    /// `.ready` is the only phase in which that is true, and it is exactly the
    /// phase in which ``nextCursor`` is non-`nil`: a successful load that came
    /// back without a cursor lands in `.exhausted` instead.
    package var canLoadMore: Bool {
        if case .ready = phase { return true }
        return false
    }

    // MARK: - Loading

    /// Loads the first page unless something has already been loaded or is in
    /// flight. Safe to call from `.task`, which SwiftUI may run more than once.
    package func loadFirstPageIfNeeded() async {
        guard case .idle = phase else { return }
        beginLoad(from: nil, replacingContents: true, phase: .loadingFirstPage)
        await loadTask?.value
    }

    /// Discards every page and reads the list again from the start.
    ///
    /// The rows stay on screen while it runs — they are replaced when the new
    /// first page lands, not when the request leaves — so `.refreshable` spins
    /// over the list the reader was looking at rather than over an empty screen.
    package func refresh() async {
        beginLoad(from: nil, replacingContents: true, phase: .loadingFirstPage)
        await loadTask?.value
    }

    /// Loads the next page now, regardless of scroll position. For a "Load
    /// more" button; the scroll path is ``prefetchIfNeeded(around:)``.
    package func loadNextPage() async {
        guard canLoadMore, let cursor = nextCursor else { return }
        beginLoad(from: cursor, replacingContents: false, phase: .loadingNextPage)
        await loadTask?.value
    }

    /// Re-attempts the load that failed, from where it failed.
    ///
    /// A failure part-way down a list resumes from the cursor it was reaching
    /// for, keeping the rows already read. Only a first page that never arrived
    /// starts over.
    package func retry() async {
        guard case .failed = phase else { return }
        let fromScratch = items.isEmpty
        beginLoad(
            from: fromScratch ? nil : nextCursor,
            replacingContents: fromScratch,
            phase: fromScratch ? .loadingFirstPage : .loadingNextPage
        )
        await loadTask?.value
    }

    /// The scroll trigger: call it as each row appears.
    ///
    /// Cheap and safe to call for every row of every frame — it returns without
    /// allocating unless this row is inside the trigger zone and a load is not
    /// already running.
    package func prefetchIfNeeded(around item: Element) {
        guard canLoadMore, let cursor = nextCursor else { return }
        guard let index = indexByID[item.id] else { return }
        guard index >= items.count - policy.distanceFromEnd else { return }
        beginLoad(from: cursor, replacingContents: false, phase: .loadingNextPage)
    }

    /// Stops any load in flight, keeping the rows already read.
    ///
    /// For a screen going away with a prefetch outstanding. The phase falls back
    /// to one the screen can resume from, so returning to it re-triggers rather
    /// than sitting on a spinner that nothing will ever resolve.
    package func cancel() {
        loadTask?.cancel()
        loadTask = nil
        generation &+= 1
        guard phase.isLoading else { return }
        if items.isEmpty {
            phase = .idle
        } else {
            phase = nextCursor == nil ? .exhausted : .ready
        }
    }

    /// Waits for the load in flight, if there is one.
    ///
    /// Exists for tests, which need to await work that a scroll started and no
    /// caller is holding — the same reason `Store.settled()` does. A view never
    /// needs it: `.task` and `.refreshable` already await the call they made.
    package func settled() async {
        await loadTask?.value
    }

    // MARK: - Private

    /// Starts a load, synchronously.
    ///
    /// Everything that decides *whether* to load happens before this returns —
    /// the phase is moved on the main actor, so the next caller's guard sees it
    /// — and everything that takes time happens in the task it leaves behind.
    private func beginLoad(from cursor: PageCursor?, replacingContents: Bool, phase newPhase: PaginationPhase) {
        loadTask?.cancel()
        generation &+= 1
        let loadGeneration = generation
        phase = newPhase
        loadTask = Task { [weak self] in
            await self?.performLoad(
                from: cursor,
                replacingContents: replacingContents,
                generation: loadGeneration
            )
        }
    }

    /// Reads pages until one of them adds something, ends the list, or fails.
    ///
    /// The loop is the empty-page fix described on the type: normally it runs
    /// exactly once, and it goes round again only when a page contributed no
    /// rows and there is another cursor to follow.
    private func performLoad(
        from startCursor: PageCursor?,
        replacingContents: Bool,
        generation loadGeneration: UInt64
    ) async {
        var cursor = startCursor
        var replacing = replacingContents
        var emptyPages = 0

        while true {
            guard let slice = await fetchPage(after: cursor, generation: loadGeneration) else { return }

            if let cursor, slice.nextCursor == cursor {
                phase = .failed(message: PaginationError.cursorDidNotAdvance.localizedDescription)
                return
            }

            let added = apply(slice, replacingContents: replacing)
            replacing = false
            nextCursor = slice.nextCursor

            guard let next = slice.nextCursor else {
                phase = .exhausted
                return
            }

            if added > 0 {
                phase = .ready
                return
            }

            emptyPages += 1
            guard emptyPages < policy.maxConsecutiveEmptyPages else {
                let error = PaginationError.tooManyEmptyPages(limit: policy.maxConsecutiveEmptyPages)
                phase = .failed(message: error.localizedDescription)
                return
            }
            cursor = next
        }
    }

    /// One request.
    ///
    /// - Returns: `nil` when the caller must stop — either the load was
    ///   cancelled or superseded, in which case the phase belongs to whoever
    ///   superseded it and must not be touched, or it failed, in which case this
    ///   has already moved the phase to `.failed`.
    private func fetchPage(
        after cursor: PageCursor?,
        generation loadGeneration: UInt64
    ) async -> PageSlice<Element>? {
        do {
            let slice = try await source.loadPage(after: cursor, limit: policy.pageSize)
            guard loadGeneration == generation, !Task.isCancelled else { return nil }
            return slice
        } catch is CancellationError {
            return nil
        } catch {
            guard loadGeneration == generation else { return nil }
            phase = .failed(message: error.localizedDescription)
            return nil
        }
    }

    /// Merges a page in, dropping ids already on screen.
    ///
    /// - Returns: how many rows were actually added, which is what tells the
    ///   caller whether following the next cursor is progress or a loop.
    private func apply(_ slice: PageSlice<Element>, replacingContents: Bool) -> Int {
        var newItems: [Element] = replacingContents ? [] : items
        var newIndex: [Element.ID: Int] = replacingContents ? [:] : indexByID
        var added = 0

        for item in slice.items where newIndex[item.id] == nil {
            newIndex[item.id] = newItems.count
            newItems.append(item)
            added += 1
        }

        // Assigned once rather than appended to in place: `items` is observed,
        // and a page of twenty appends is twenty invalidations of every view
        // reading it.
        items = newItems
        indexByID = newIndex
        return added
    }
}
