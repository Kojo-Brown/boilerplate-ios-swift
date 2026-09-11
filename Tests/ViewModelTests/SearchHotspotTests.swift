import Foundation
import Testing
@testable import Core
@testable import Features

/// The counts behind Phase 10 item 3's fixed hotspot.
///
/// Every assertion here is a *count*, never a duration. The claim the fix
/// makes is "this work happens once per keystroke instead of four times, over
/// keys that were folded once instead of collated per comparison", and a
/// count says exactly that on a loaded CI runner and on a quiet laptop alike.
/// A wall-clock assertion would say it on one of them — this repository has
/// already deleted a timing assertion for being a load meter (Phase 9 item 5),
/// and `docs/profiling.md` is where the other half of the measurement, the one
/// that needs Instruments and a device, is written down instead.
@Suite("Search hotspot")
struct SearchHotspotTests {

    /// A stand-in for the screen's rows: two searchable fields, like
    /// `HomeItem`'s title and subtitle, so that "keys" and "elements" are
    /// different numbers and a test cannot confuse them.
    fileprivate struct Row: Identifiable, Sendable, Equatable {
        let id: Int
        let title: String
        let subtitle: String
    }

    /// Fixed so that the comparison counts below are arithmetic rather than
    /// observations.
    fileprivate static let catalogue: [Row] = (1...10).map { index in
        Row(
            id: index,
            title: "Item \(index)",
            subtitle: "Description for item \(index)"
        )
    }

    /// Case folding is locale-dependent — Turkish `"I"` folds to `"ı"`, not
    /// `"i"` — so a suite that wants the same answer on every runner has to
    /// say which locale it means rather than inherit the host's.
    fileprivate static let locale = Locale(identifier: "en_US")

    fileprivate static func keys(of row: Row) -> [String] {
        [row.title, row.subtitle]
    }

    fileprivate static func index(
        over rows: [Row] = SearchHotspotTests.catalogue,
        ledger: SearchWorkLedger? = nil
    ) -> SearchIndex<Row> {
        SearchIndex(
            rows,
            locale: SearchHotspotTests.locale,
            ledger: ledger,
            searchableText: SearchHotspotTests.keys(of:)
        )
    }

    // MARK: - The predicate

    /// What folding changed about *which* rows match, as opposed to how much
    /// it costs to find them. A faster search that answers differently is not
    /// a faster search.
    @Suite("Matching")
    struct Matching {

        @Test("Folded keys answer exactly what the collation they replace answered")
        func matchesTheCollationItReplaces() {
            let rows = SearchHotspotTests.catalogue
            let index = SearchHotspotTests.index()

            for query in ["item", "ITEM", "Item 1", "3", "description for item 7", "zzz"] {
                let folded = index.matches(query).map(\.id)
                let collated = rows.filter {
                    $0.title.localizedCaseInsensitiveContains(query)
                        || $0.subtitle.localizedCaseInsensitiveContains(query)
                }.map(\.id)

                #expect(folded == collated, "query: \(query)")
            }
        }

        /// The one deliberate widening, asserted from both sides so that it
        /// cannot be lost or acquired by accident: folding matches across
        /// diacritics, and the predicate it replaced did not. For a search
        /// field this is the behaviour a reader expects and the one they
        /// cannot get from a keyboard without an `é` on it.
        @Test("Folding matches across diacritics where the collation did not")
        func foldingIgnoresDiacritics() {
            let rows = [SearchHotspotTests.Row(id: 1, title: "Café", subtitle: "Paris")]
            let index = SearchHotspotTests.index(over: rows)

            #expect(index.matches("cafe").map(\.id) == [1])
            #expect(index.matches("CAFÉ").map(\.id) == [1])
            #expect(!rows[0].title.localizedCaseInsensitiveContains("cafe"))
        }

        /// Two spellings of the same word are one key. Without the
        /// normalisation step they are different `Character` sequences and the
        /// substring test misses — the failure being invisible in a source
        /// file, where both spellings render identically.
        @Test("A decomposed spelling is found by a precomposed query")
        func canonicallyEquivalentSpellingsFoldTogether() {
            let decomposed = "Cafe\u{0301} Noir"
            let rows = [SearchHotspotTests.Row(id: 1, title: decomposed, subtitle: "")]
            let index = SearchHotspotTests.index(over: rows)

            #expect(index.matches("café noir").map(\.id) == [1])
            #expect(index.matches("cafe noir").map(\.id) == [1])
        }

        @Test("An empty query returns the whole corpus without comparing anything")
        func emptyQueryCostsNothing() {
            let ledger = SearchWorkLedger()
            let index = SearchHotspotTests.index(ledger: ledger)
            ledger.reset()

            #expect(index.matches("").count == SearchHotspotTests.catalogue.count)
            #expect(ledger.scans == 0)
            #expect(ledger.comparisons == 0)
        }
    }

    // MARK: - What a pass costs

    @Suite("Index building")
    struct IndexBuilding {

        @Test("Building folds every key exactly once")
        func buildingFoldsEachKeyOnce() {
            let ledger = SearchWorkLedger()

            _ = SearchHotspotTests.index(ledger: ledger)

            #expect(ledger.indexBuilds == 1)
            #expect(ledger.foldedKeys == SearchHotspotTests.catalogue.count * 2)
        }

        /// The quiet quadratic. A stream that appends one row at a time to a
        /// long list refolds the whole list per batch if the index is rebuilt,
        /// and this is what holds the incremental path in place: two new keys
        /// folded, not twenty-two.
        @Test("Appending folds only the new keys")
        func appendingFoldsOnlyTheNewKeys() {
            let ledger = SearchWorkLedger()
            let index = SearchHotspotTests.index(ledger: ledger)
            ledger.reset()

            let grown = index.appending(
                [SearchHotspotTests.Row(id: 99, title: "Appended", subtitle: "New row")],
                searchableText: SearchHotspotTests.keys(of:)
            )

            #expect(ledger.foldedKeys == 2)
            #expect(grown.elements.count == SearchHotspotTests.catalogue.count + 1)
            #expect(grown.matches("appended").map(\.id) == [99])
            #expect(grown.matches("Item 4").map(\.id) == [4])
        }

        @Test("A scan compares every key until a row matches, and stops there")
        func scanComparisonsAreProportionalToTheCorpus() {
            let rows = SearchHotspotTests.catalogue
            let ledger = SearchWorkLedger()
            let index = SearchHotspotTests.index(ledger: ledger)

            ledger.reset()
            _ = index.matches("nothing here matches this")
            #expect(ledger.scans == 1)
            #expect(ledger.comparisons == rows.count * 2)

            ledger.reset()
            _ = index.matches("Item")
            #expect(ledger.comparisons == rows.count)
        }
    }

    // MARK: - What a read costs

    @Suite("Memoised reads")
    @MainActor
    struct MemoisedReads {

        private static func search(
            ledger: SearchWorkLedger,
            tracer: any PerformanceTracing = NoOpTracer()
        ) -> MemoizedSearch<SearchHotspotTests.Row> {
            let memoised = MemoizedSearch<SearchHotspotTests.Row>(
                locale: SearchHotspotTests.locale,
                ledger: ledger,
                tracer: tracer,
                searchableText: SearchHotspotTests.keys(of:)
            )
            memoised.replace(SearchHotspotTests.catalogue)
            return memoised
        }

        @Test("Reading the same query repeatedly scans once")
        func repeatedReadsScanOnce() {
            let ledger = SearchWorkLedger()
            let search = Self.search(ledger: ledger)
            ledger.reset()

            for _ in 0..<4 {
                #expect(search.results(for: "item 3", corpusVersion: 1).map(\.id) == [3])
            }

            #expect(ledger.scans == 1)
            #expect(ledger.cacheHits == 3)
        }

        @Test("A new query rescans; the one before it is not kept")
        func changingTheQueryRescans() {
            let ledger = SearchWorkLedger()
            let search = Self.search(ledger: ledger)
            ledger.reset()

            for query in ["i", "it", "ite"] {
                for _ in 0..<4 {
                    _ = search.results(for: query, corpusVersion: 1)
                }
            }
            _ = search.results(for: "i", corpusVersion: 1)

            #expect(ledger.scans == 4)
            #expect(ledger.cacheHits == 9)
        }

        @Test("A changed corpus invalidates the cached answer through either door")
        func aChangedCorpusInvalidatesTheCache() {
            let ledger = SearchWorkLedger()
            let search = Self.search(ledger: ledger)
            _ = search.results(for: "item", corpusVersion: 1)
            ledger.reset()

            // The version stamp alone.
            _ = search.results(for: "item", corpusVersion: 2)
            #expect(ledger.scans == 1)

            // And a replacement that forgets to bump it.
            search.replace([SearchHotspotTests.Row(id: 1, title: "Other", subtitle: "")])
            let results = search.results(for: "item", corpusVersion: 2)
            #expect(results.isEmpty)
            #expect(ledger.scans == 2)
        }

        @Test("An append keeps the corpus searchable and drops the cached answer")
        func appendingInvalidatesTheCache() {
            let ledger = SearchWorkLedger()
            let search = Self.search(ledger: ledger)
            _ = search.results(for: "appended", corpusVersion: 1)
            ledger.reset()

            search.append([SearchHotspotTests.Row(id: 99, title: "Appended", subtitle: "New")])

            #expect(search.results(for: "appended", corpusVersion: 2).map(\.id) == [99])
            #expect(ledger.scans == 1)
            #expect(ledger.cacheHits == 0)
            #expect(ledger.foldedKeys == 2)
        }

        @Test("Every real scan and every build is marked for Instruments")
        func workIsTraced() {
            let ledger = SearchWorkLedger()
            let tracer = RecordingTracer()
            let search = Self.search(ledger: ledger, tracer: tracer)

            _ = search.results(for: "item", corpusVersion: 1)
            _ = search.results(for: "item", corpusVersion: 1)

            #expect(tracer.beginCount(of: .searchIndexBuild) == 1)
            #expect(tracer.beginCount(of: .searchScan) == 1)
            #expect(tracer.unclosedIDs.isEmpty)
        }
    }

    // MARK: - The screen it was found on

    @Suite("Home screen")
    @MainActor
    struct HomeScreen {

        /// What one evaluation of `HomeView.body` reads: twice to choose
        /// between loading, error and empty, once to choose between the list
        /// and the grid, and once for the `ForEach`. Four passes over the
        /// corpus per keystroke before this item; one now.
        @Test("One body evaluation of HomeView costs one search pass")
        func fourReadsCostOneScan() async {
            let ledger = SearchWorkLedger()
            let sut = HomeViewModel(searchWork: ledger)
            await sut.onAppear()
            sut.searchQuery = "item 1"
            ledger.reset()

            let reads = (0..<4).map { _ in sut.filteredItems.count }

            #expect(reads == [2, 2, 2, 2])
            #expect(ledger.scans == 1)
            #expect(ledger.cacheHits == 3)
        }

        @Test("Typing costs one pass per keystroke, not one per read")
        func typingCostsOneScanPerKeystroke() async {
            let ledger = SearchWorkLedger()
            let sut = HomeViewModel(searchWork: ledger)
            await sut.onAppear()
            ledger.reset()

            for query in ["i", "it", "ite", "item"] {
                sut.searchQuery = query
                for _ in 0..<4 {
                    _ = sut.filteredItems
                }
            }

            #expect(ledger.scans == 4)
            #expect(ledger.cacheHits == 12)
        }

        @Test("A delete is visible in the filtered list immediately")
        func deletingInvalidatesTheFilteredList() async {
            let sut = HomeViewModel()
            await sut.onAppear()
            sut.searchQuery = "item 1"
            let before = sut.filteredItems

            sut.deleteItems(at: IndexSet(integer: 0))

            #expect(sut.filteredItems.count == before.count - 1)
            #expect(!sut.filteredItems.contains { $0.id == before[0].id })
            #expect(!sut.items.contains { $0.id == before[0].id })
        }

        @Test("The filtered list answers what the collation it replaced answered")
        func filteringMatchesTheOldPredicate() async {
            let sut = HomeViewModel()
            await sut.onAppear()
            let rows = sut.items

            for query in ["item", "ITEM 2", "description", "9", "zzz"] {
                sut.searchQuery = query
                let expected = rows.filter {
                    $0.title.localizedCaseInsensitiveContains(query)
                        || $0.subtitle.localizedCaseInsensitiveContains(query)
                }

                #expect(sut.filteredItems == expected, "query: \(query)")
            }
        }

        @Test("The fetch is one interval in the trace, opened and closed")
        func theFetchIsTraced() async {
            let tracer = RecordingTracer()
            let sut = HomeViewModel(tracer: tracer)

            await sut.onAppear()

            #expect(tracer.beginCount(of: .homeLoad) == 1)
            #expect(tracer.endCount(of: .homeLoad) == 1)
            #expect(tracer.unclosedIDs.isEmpty)
        }

        /// The reason the interval is closed in a `defer`. A cancelled fetch
        /// leaves through neither branch of the `do`, and an interval left
        /// open draws as a region running to the end of the trace — a hang
        /// that is not there, on the screen somebody is investigating.
        @Test("A cancelled fetch still closes its interval")
        func aCancelledFetchClosesItsInterval() async {
            let tracer = RecordingTracer()
            let sut = HomeViewModel(tracer: tracer)

            let fetch = Task { await sut.onAppear() }
            fetch.cancel()
            await fetch.value

            #expect(tracer.beginCount(of: .homeLoad) == 1)
            #expect(tracer.endCount(of: .homeLoad) == 1)
            #expect(tracer.unclosedIDs.isEmpty)
        }
    }
}
