import SwiftUI
import Testing
@testable import Core
@testable import Features

// MARK: - The invariant

/// Phase 10 item 5, the half that needs no simulator.
///
/// `matchedGeometryEffect` has one rule and gives one warning when it is
/// broken: exactly one view per id may claim to be the geometry source. Two
/// sources and the pair jumps to whichever the framework picked; none and the
/// destination collapses to zero size. Neither failure is visible in the source
/// of either view — each end looks correct on its own — which is why
/// ``HeroProxy`` decides it for both rather than leaving each call site to
/// negate a flag, and why the invariant is worth a test of its own.
@Suite("Hero geometry — exactly one source per pair")
@MainActor
struct HeroProxyTests {

    private static let ids = [1, 2, 3]

    @Test("Exactly one end of a pair is the source, in every state")
    func exactlyOneEndIsTheSource() {
        let namespace = Namespace().wrappedValue

        for expanded in [nil, 1, 2, 9] as [Int?] {
            let proxy = HeroProxy(namespace: namespace, expandedID: expanded)
            for id in Self.ids {
                // Exclusive-or: the two ends never agree, whichever element is
                // open and whether or not it is one of these.
                #expect(proxy.collapsedIsSource(id) != proxy.expandedIsSource(id))
            }
        }
    }

    @Test("The collapsed end owns the geometry until its own card is open")
    func theCollapsedEndOwnsTheGeometryUntilItIsOpen() {
        let namespace = Namespace().wrappedValue
        let proxy = HeroProxy(namespace: namespace, expandedID: 2)

        #expect(proxy.collapsedIsSource(1))
        #expect(proxy.collapsedIsSource(3))
        #expect(!proxy.collapsedIsSource(2))
        #expect(proxy.expandedIsSource(2))
    }

    @Test("With nothing open every collapsed element owns its own geometry")
    func withNothingOpenEveryCellIsASource() {
        let proxy = HeroProxy<Int>(namespace: Namespace().wrappedValue, expandedID: nil)

        for id in Self.ids {
            #expect(proxy.collapsedIsSource(id))
            #expect(!proxy.isExpanded(id))
        }
    }
}

// MARK: - The rendered tree

/// The half that does need one.
///
/// What is measured here is the property that makes a hero overlay worth having
/// over a `NavigationStack` push: the collection stays mounted behind the card.
/// A push replaces the tree, so the grid is rebuilt on the way back and its
/// scroll position, its selection and every row's local state go with it. An
/// overlay only *claims* not to — and the claim is invisible in the source,
/// because a `ZStack` that rebuilds its first child and one that reuses it look
/// identical. `onAppear` counts tell them apart: a collection that survived
/// reports no new appearances across a whole present-and-dismiss cycle.
@Suite("Hero transitions in a rendered tree", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct HeroTransitionRenderTests {

    private static let ids = [1, 2, 3]

    private static func harness(
        _ selection: HeroSelection,
        _ ledger: BodyEvaluationLedger
    ) async -> RenderHarness<HeroProbeHarness> {
        await RenderHarness.mount(
            HeroProbeHarness(selection: selection, ledger: ledger, ids: ids)
        )
    }

    /// The detail closure is not merely hidden while nothing is expanded — it
    /// is never called. A card built eagerly and hidden is a card whose `.task`
    /// has already run and whose images have already been decoded, for a screen
    /// nobody opened.
    @Test("With nothing expanded the card is never built")
    func theCardIsNotBuiltUntilSomethingIsExpanded() async {
        let selection = HeroSelection()
        let ledger = BodyEvaluationLedger()
        let harness = await Self.harness(selection, ledger)
        defer { harness.dismount() }

        await settleUntil(harness) { ledger.count(of: HeroProbeLabel.cell(1)) == 1 }

        for id in Self.ids {
            #expect(ledger.count(of: HeroProbeLabel.cell(id)) == 1)
            #expect(ledger.count(of: HeroProbeLabel.card(id)) == 0)
        }
    }

    @Test("Expanding mounts the card once and leaves the collection standing")
    func expandingDoesNotRemountTheCollection() async {
        let selection = HeroSelection()
        let ledger = BodyEvaluationLedger()
        let harness = await Self.harness(selection, ledger)
        defer { harness.dismount() }

        await settleUntil(harness) { ledger.count(of: HeroProbeLabel.cell(3)) == 1 }

        // Measure the update, not the first render: everything mounted so far
        // was mounted because the tree is new, which is not redundant work.
        ledger.reset()
        selection.expanded = 2
        await settleUntil(harness) { ledger.count(of: HeroProbeLabel.card(2)) == 1 }

        #expect(ledger.count(of: HeroProbeLabel.card(2)) == 1)
        for id in Self.ids {
            #expect(ledger.count(of: HeroProbeLabel.cell(id)) == 0)
        }
    }

    @Test("Dismissing takes the card away and brings the same collection back")
    func dismissingKeepsTheCollection() async {
        let selection = HeroSelection()
        let ledger = BodyEvaluationLedger()
        let harness = await Self.harness(selection, ledger)
        defer { harness.dismount() }

        await settleUntil(harness) { ledger.count(of: HeroProbeLabel.cell(3)) == 1 }
        selection.expanded = 2
        await settleUntil(harness) { ledger.count(of: HeroProbeLabel.card(2)) == 1 }

        ledger.reset()
        selection.expanded = nil

        // A condition that never holds, which spends the whole budget on
        // purpose: this is the one assertion in the suite that wants nothing to
        // happen, and the only way to be sure of that is to keep settling past
        // the removal animation. Twelve steps is 600 ms against a 420 ms
        // spring.
        await settleUntil(harness, attempts: 12) { false }

        // Nothing appeared: the card was removed rather than replaced, and the
        // cells behind it were never unmounted to need remounting.
        #expect(ledger.total == 0)
    }

    /// Opening a second element while one is already open. The card is a
    /// different view — different id, different matched pair — so it is
    /// genuinely rebuilt, and that is the one remount in this suite that is
    /// supposed to happen.
    @Test("Switching directly from one card to another rebuilds only the card")
    func switchingCardsRebuildsOnlyTheCard() async {
        let selection = HeroSelection(expanded: 1)
        let ledger = BodyEvaluationLedger()
        let harness = await Self.harness(selection, ledger)
        defer { harness.dismount() }

        await settleUntil(harness) { ledger.count(of: HeroProbeLabel.card(1)) == 1 }

        ledger.reset()
        selection.expanded = 3
        await settleUntil(harness) { ledger.count(of: HeroProbeLabel.card(3)) == 1 }

        #expect(ledger.count(of: HeroProbeLabel.card(3)) == 1)
        #expect(ledger.count(of: HeroProbeLabel.card(1)) == 0)
        for id in Self.ids {
            #expect(ledger.count(of: HeroProbeLabel.cell(id)) == 0)
        }
    }
}
