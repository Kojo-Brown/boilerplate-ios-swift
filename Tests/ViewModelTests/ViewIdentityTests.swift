import Foundation
import SwiftUI
import Testing
@testable import Core
@testable import Features

// MARK: - What this suite is holding

/// Phase 10 item 1. Two mechanisms, measured rather than asserted about.
///
/// The claim under test is not "these views are correct" — the existing suites
/// cover that — but "SwiftUI does less work than it did". That is only
/// observable from inside a tree the framework is driving, so the render tests
/// below host their subject in a `RenderHarness`, change one thing, and read
/// the evaluation counts back out of a ``BodyEvaluationLedger``.
///
/// The `==` tests are the other half, and they are the ones that fail first
/// when someone edits a row: an `Equatable` view whose `==` misses a stored
/// property does not render slowly, it renders *stale*, and no measurement
/// notices.
@Suite("View identity and Equatable conformance")
@MainActor
struct ViewIdentityTests {

    // MARK: - The ledger itself

    @Test("A label that was never recorded reads as zero rather than trapping")
    func unrecordedLabelIsZero() {
        let ledger = BodyEvaluationLedger()

        #expect(ledger.count(of: "nothing recorded here") == 0)
        #expect(ledger.total == 0)
        #expect(ledger.snapshot.isEmpty)
    }

    @Test("Recording accumulates per label")
    func recordingAccumulatesPerLabel() {
        let ledger = BodyEvaluationLedger()

        ledger.record("row")
        ledger.record("row")
        ledger.record("footer")

        #expect(ledger.count(of: "row") == 2)
        #expect(ledger.count(of: "footer") == 1)
        #expect(ledger.total == 3)
    }

    @Test("Resetting clears every count so an update can be measured on its own")
    func resetClearsEveryCount() {
        let ledger = BodyEvaluationLedger()
        ledger.record("row")

        ledger.reset()

        #expect(ledger.count(of: "row") == 0)
        #expect(ledger.total == 0)
    }

    @Test("Constructing a probe records one evaluation")
    func probeRecordsOnConstruction() {
        let ledger = BodyEvaluationLedger()

        _ = BodyEvaluationProbe("probe", into: ledger)
        _ = BodyEvaluationProbe("probe", into: ledger)

        #expect(ledger.count(of: "probe") == 2)
    }

    @Test("A probe with no ledger records nothing and costs a nil check")
    func probeWithoutLedgerIsInert() {
        let ledger = BodyEvaluationLedger()

        _ = BodyEvaluationProbe("probe", into: nil)

        #expect(ledger.total == 0)
    }

    // MARK: - Equality of the shipped rows

    @Test("Two rows built from the same item are equal")
    func rowsFromTheSameItemAreEqual() {
        let item = HomeItem(id: UUID(), title: "Item 1", subtitle: "Description for item 1")

        #expect(HomeItemRow(item: item) == HomeItemRow(item: item))
        #expect(HomeItemCard(item: item) == HomeItemCard(item: item))
    }

    /// The one that matters. If `HomeItem`'s equality were identity — comparing
    /// `id` and stopping — a row whose title was edited would compare equal to
    /// the row it replaced, SwiftUI would skip its body, and the screen would
    /// keep showing the old title indefinitely. Cheaper, and wrong.
    @Test("A row is not equal to one whose content changed under the same id")
    func sameIdentityWithDifferentContentIsNotEqual() {
        let id = UUID()
        let before = HomeItem(id: id, title: "Item 1", subtitle: "Description for item 1")
        let afterTitle = HomeItem(id: id, title: "Item 1 (edited)", subtitle: before.subtitle)
        let afterSubtitle = HomeItem(id: id, title: before.title, subtitle: "Edited description")

        #expect(HomeItemRow(item: before) != HomeItemRow(item: afterTitle))
        #expect(HomeItemRow(item: before) != HomeItemRow(item: afterSubtitle))
        #expect(HomeItemCard(item: before) != HomeItemCard(item: afterTitle))
        #expect(HomeItemCard(item: before) != HomeItemCard(item: afterSubtitle))
    }

    @Test("Rows for different items are not equal")
    func rowsForDifferentItemsAreNotEqual() {
        let first = HomeItem(id: UUID(), title: "Item 1", subtitle: "Description for item 1")
        let second = HomeItem(id: UUID(), title: "Item 2", subtitle: "Description for item 2")

        #expect(HomeItemRow(item: first) != HomeItemRow(item: second))
        #expect(HomeItemCard(item: first) != HomeItemCard(item: second))
    }

    // MARK: - What the framework actually skips

    /// The measurement the item exists for: one update, three subtrees, and
    /// only the one that was written inline is rebuilt.
    ///
    /// The counts are lower bounds rather than exact numbers on the side that
    /// is *supposed* to run — SwiftUI is free to evaluate a body more than once
    /// for a single change and doing so is not a defect. The side that is
    /// supposed to be skipped is exact: zero.
    @Test("An unrelated change rebuilds inline content and skips the memoised content")
    func unrelatedChangeSkipsMemoisedContent() {
        let ticker = RenderTicker()
        let ledger = BodyEvaluationLedger()
        let harness = RenderHarness(MemoisationHarness(ticker: ticker, ledger: ledger))

        // Every count below is relative to a tree that is already on screen,
        // so assert that it is before clearing them: a reset that lands before
        // the first render would move that render's evaluations into the
        // measurement and quietly invert what this test reports.
        #expect(ledger.count(of: ProbeLabel.inline) >= 1)
        #expect(ledger.count(of: ProbeLabel.memoized) >= 1)
        #expect(ledger.count(of: ProbeLabel.equatable) >= 1)

        // The first render is not redundant work — it is the render. What is
        // being measured is what the updates after it cost.
        ledger.reset()

        for _ in 1...3 {
            ticker.tick += 1
            harness.settle()
        }

        #expect(ledger.count(of: ProbeLabel.inline) >= 3)
        #expect(ledger.count(of: ProbeLabel.memoized) == 0)
        #expect(ledger.count(of: ProbeLabel.equatable) == 0)
    }

    /// The other direction, and the reason the first test is not simply a
    /// measurement of a view that never updates: change what the subtrees are
    /// keyed on and they rebuild like anything else.
    @Test("Changing the key rebuilds the memoised and equatable content")
    func changingTheKeyRebuildsMemoisedContent() {
        let ticker = RenderTicker()
        let ledger = BodyEvaluationLedger()
        let harness = RenderHarness(MemoisationHarness(ticker: ticker, ledger: ledger))

        #expect(ledger.count(of: ProbeLabel.memoized) >= 1)

        ledger.reset()
        ticker.title = "Renamed"
        harness.settle()

        #expect(ledger.count(of: ProbeLabel.memoized) >= 1)
        #expect(ledger.count(of: ProbeLabel.equatable) >= 1)
        #expect(ledger.count(of: ProbeLabel.inline) >= 1)
    }

    /// Identity is not the same lever as equality, and this is the difference:
    /// a body that re-runs keeps its view's state, and a view whose identity
    /// changes does not have that state any more. `onAppear` counts lifetimes,
    /// so the stable row reports one mount however often it is re-evaluated,
    /// and the row carrying `.id(tick)` reports one per value of `tick`.
    @Test("A view whose explicit identity changes is remounted; a stable one is not")
    func changingExplicitIdentityRemountsTheRow() {
        let ticker = RenderTicker()
        let ledger = BodyEvaluationLedger()
        let harness = RenderHarness(IdentityHarness(ticker: ticker, ledger: ledger))

        for _ in 1...3 {
            ticker.tick += 1
            harness.settle()
        }

        #expect(ledger.count(of: ProbeLabel.stableRow) == 1)
        #expect(ledger.count(of: ProbeLabel.rebuiltRow) >= 2)
    }
}
