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
@Suite("View identity and Equatable conformance", .serialized, .timeLimit(.minutes(1)))
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
    /// only the one written inline is rebuilt.
    ///
    /// The counts are read per update rather than in total, for two reasons.
    /// The distribution is the finding — "3 evaluations over 3 updates" and
    /// "3 on one update and none after" are different claims about a
    /// memoisation — and a failure that carries the whole history says which
    /// update went wrong, which a single total cannot.
    ///
    /// **Reaching steady state is not part of the measurement.** On CI run
    /// 34162321433 the memoised subtree was rebuilt exactly once across three
    /// updates, and it was the first: the tail of the initial render and the
    /// layout that follows a window becoming visible land on it. Steady state
    /// is what the item claims; asserting zero from the first update would be
    /// asserting something this harness has observed to be false.
    ///
    /// How many updates that tail spans is *not* fixed at one, which is what
    /// run 34405002270 showed — with another suite mounting harnesses of its
    /// own, it reached the second update too, and a test that discarded exactly
    /// one update failed on a rebuild it was always going to tolerate. So the
    /// warm-up drives updates until one of them rebuilds nothing memoised, and
    /// the measurement starts from there. The result is a stricter assertion
    /// than the one it replaces — every measured update must be clean, where
    /// before the first of four was exempt — and it no longer depends on how
    /// busy the machine is.
    @Test("An unrelated change rebuilds inline content and skips the memoised content")
    func unrelatedChangeSkipsMemoisedContent() async {
        let ticker = RenderTicker()
        let ledger = BodyEvaluationLedger()
        let harness = await RenderHarness.mount(MemoisationHarness(ticker: ticker, ledger: ledger))
        defer { harness.dismount() }

        // The mount is a render, not redundant work. Assert it happened before
        // clearing it: counts cleared before the first render would move that
        // render into the measurement and invert what this test reports.
        #expect(ledger.count(of: ProbeLabel.inline) >= 1)
        #expect(ledger.count(of: ProbeLabel.memoized) >= 1)
        #expect(ledger.count(of: ProbeLabel.equatable) >= 1)

        // Bounded: if the memoisation is broken outright this never settles, and
        // the budget is what turns that into a failed assertion below rather
        // than a test that runs until the suite's time limit kills it.
        var warmUps = 0
        while warmUps < 10 {
            ledger.reset()
            ticker.tick += 1
            await harness.settle()
            warmUps += 1
            if ledger.count(of: ProbeLabel.memoized) == 0 { break }
        }

        var perUpdate: [[String: Int]] = []
        for _ in 1...4 {
            ledger.reset()
            ticker.tick += 1
            await harness.settle()
            perUpdate.append(ledger.snapshot)
        }

        let history: Comment = "warm-up updates: \(warmUps); per-update counts: \(perUpdate)"

        #expect(perUpdate.allSatisfy { ($0[ProbeLabel.inline] ?? 0) >= 1 }, history)
        #expect(perUpdate.allSatisfy { ($0[ProbeLabel.memoized] ?? 0) == 0 }, history)
        #expect(perUpdate.allSatisfy { ($0[ProbeLabel.equatable] ?? 0) == 0 }, history)
    }

    /// The other direction, and the reason the test above is not simply a
    /// measurement of a view that never updates: change what the subtrees are
    /// keyed on and they rebuild like anything else.
    @Test("Changing the key rebuilds the memoised and equatable content")
    func changingTheKeyRebuildsMemoisedContent() async {
        let ticker = RenderTicker()
        let ledger = BodyEvaluationLedger()
        let harness = await RenderHarness.mount(MemoisationHarness(ticker: ticker, ledger: ledger))
        defer { harness.dismount() }

        #expect(ledger.count(of: ProbeLabel.memoized) >= 1)

        ledger.reset()
        ticker.title = "Renamed"
        await harness.settle()

        let counts: Comment = "counts after the key changed: \(ledger.snapshot)"
        #expect(ledger.count(of: ProbeLabel.memoized) >= 1, counts)
        #expect(ledger.count(of: ProbeLabel.equatable) >= 1, counts)
        #expect(ledger.count(of: ProbeLabel.inline) >= 1, counts)
    }

    /// Identity is not the same lever as equality, and this is the difference:
    /// a body that re-runs keeps its view's state, and a view whose identity
    /// changes does not have that state any more. `onAppear` counts lifetimes,
    /// so the stable row reports one mount however often it is re-evaluated,
    /// and the row carrying `.id(tick)` reports one per value of `tick`.
    @Test("A view whose explicit identity changes is remounted; a stable one is not")
    func changingExplicitIdentityRemountsTheRow() async {
        let ticker = RenderTicker()
        let ledger = BodyEvaluationLedger()
        let harness = await RenderHarness.mount(IdentityHarness(ticker: ticker, ledger: ledger))
        defer { harness.dismount() }

        for _ in 1...3 {
            ticker.tick += 1
            await harness.settle()
        }

        let counts: Comment = "appearances: \(ledger.snapshot)"
        #expect(ledger.count(of: ProbeLabel.stableRow) == 1, counts)
        #expect(ledger.count(of: ProbeLabel.rebuiltRow) >= 2, counts)
    }
}
