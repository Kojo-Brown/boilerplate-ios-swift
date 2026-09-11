import Foundation

/// A ``SearchIndex`` with the last answer kept, so that reading a filtered
/// list repeatedly costs one pass rather than one pass per read.
///
/// ## Why a computed property is not enough
///
/// `HomeView` renders its list from `viewModel.filteredItems`, and a single
/// evaluation of that view's body reads it up to four times: twice to choose
/// between the loading, error and empty states, once to decide between the
/// list and the grid, and once more for the `ForEach`. A computed property
/// that filters recomputes all four. The body itself re-runs on every
/// keystroke — it reads `searchQuery` — so the cost of a search is four passes
/// over the corpus per character typed, inside the window where the frame for
/// that keystroke is due.
///
/// That is the shape of a *hitch*: work that is correct, invisible in the
/// source, and on the main thread between a touch and its frame. See
/// `docs/profiling.md` for finding it in a trace rather than by reading.
///
/// ## The cache key
///
/// The key is the query plus a version stamp for the corpus, and both halves
/// have to be cheap to compare — a cache whose key costs as much to check as
/// the work it skips is not a cache. Comparing the corpus itself would be a
/// pass over it; the owner stamps it instead, incrementing a counter whenever
/// it writes. `HomeViewModel.setItems(_:)` is the single writer that keeps the
/// stamp and ``replace(_:)`` in step.
///
/// The stamp does a second job in an `@Observable` view model, which is why it
/// is the caller's rather than this type's. Observation registers a dependency
/// on the properties a view actually reads; this object is not one of them, so
/// a `filteredItems` that read nothing but a cache would never invalidate the
/// view when the rows changed. Reading the stamp is what puts the dependency
/// back.
///
/// A cache of one is deliberate. A search field's queries arrive as a growing
/// prefix — `"c"`, `"ca"`, `"caf"` — so anything older than the last one is
/// spent, and holding them costs memory proportional to the corpus per
/// keystroke.
@MainActor
package final class MemoizedSearch<Element: Sendable> {

    private struct CacheKey: Equatable {
        let query: String
        let version: Int
    }

    private let searchableText: (Element) -> [String]
    private let locale: Locale?
    private let ledger: SearchWorkLedger?
    private let tracer: any PerformanceTracing

    private var index: SearchIndex<Element>
    private var cachedKey: CacheKey?
    private var cachedResults: [Element] = []

    /// - Parameters:
    ///   - locale: Passed through to ``SearchIndex``; see its note on why
    ///     folding is locale-dependent.
    ///   - ledger: Optional. Counts scans, comparisons and cache hits.
    ///   - tracer: Optional. Marks each real scan and each index build for
    ///     Instruments, so that a trace shows how many there were as well as
    ///     what they cost.
    ///   - searchableText: The strings an element can be found by. Stored,
    ///     because ``replace(_:)`` folds a new corpus with it.
    package init(
        locale: Locale? = .current,
        ledger: SearchWorkLedger? = nil,
        tracer: any PerformanceTracing = NoOpTracer(),
        searchableText: @escaping (Element) -> [String]
    ) {
        self.searchableText = searchableText
        self.locale = locale
        self.ledger = ledger
        self.tracer = tracer
        index = SearchIndex<Element>(
            [],
            locale: locale,
            ledger: nil,
            searchableText: searchableText
        )
    }

    /// The corpus as last indexed.
    package var elements: [Element] {
        index.elements
    }

    /// Folds a new corpus and drops the cached answer.
    ///
    /// Dropping the cache here rather than relying on the version stamp is the
    /// belt to the stamp's braces: a caller that replaces the corpus and
    /// forgets to bump its stamp gets an extra scan, which is a cost. The other
    /// way round it would get the previous corpus's rows, which is a bug on
    /// screen.
    package func replace(_ elements: [Element]) {
        index = tracer.measure(.searchIndexBuild) {
            SearchIndex(
                elements,
                locale: locale,
                ledger: ledger,
                searchableText: searchableText
            )
        }
        cachedKey = nil
        cachedResults = []
    }

    /// Folds `newElements` onto the end of the corpus and drops the cached
    /// answer.
    ///
    /// The append that does not refold what is already indexed; see
    /// ``SearchIndex/appending(_:searchableText:)`` for why that distinction is
    /// the difference between a live-update stream costing nothing and costing
    /// the whole corpus per batch.
    package func append(_ newElements: [Element]) {
        guard !newElements.isEmpty else { return }
        let appended = tracer.measure(.searchIndexBuild) {
            index.appending(newElements, searchableText: searchableText)
        }
        index = appended
        cachedKey = nil
        cachedResults = []
    }

    /// The elements matching `query`, from the cache when nothing has changed.
    ///
    /// - Parameter corpusVersion: The caller's stamp on the corpus. Any change
    ///   to it invalidates the cached answer.
    package func results(for query: String, corpusVersion: Int) -> [Element] {
        let key = CacheKey(query: query, version: corpusVersion)
        if key == cachedKey {
            ledger?.recordCacheHit()
            return cachedResults
        }

        let matched = tracer.measure(.searchScan) { index.matches(query) }
        cachedKey = key
        cachedResults = matched
        return matched
    }
}
