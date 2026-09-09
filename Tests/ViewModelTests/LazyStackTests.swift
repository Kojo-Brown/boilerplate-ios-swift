import Foundation
import SwiftUI
import Testing
@testable import Core
@testable import Features

// MARK: - Realisation and identity

/// Phase 10 item 2, first half. What a lazy stack builds, and what it considers
/// a row to *be*.
///
/// Both are measured from inside a tree the framework is driving, for the reason
/// `ViewIdentityTests` gives: calling `body` by hand is the evaluation, so a
/// hand-driven tree can never answer "would SwiftUI have skipped this?". The
/// counts come out of a ``BodyEvaluationLedger`` after the fact.
///
/// The two probes count different things on purpose. `BodyEvaluationProbe`
/// records once per *evaluation*, which is what realisation costs;
/// `AppearanceCountingRow` records once per *lifetime*, which is the only signal
/// that reports identity — a body that re-runs a hundred times reports one
/// appearance, and a row that is torn down and rebuilt reports two.
@Suite("Lazy stack realisation and identity", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct LazyStackIdentityTests {

    // MARK: - Laziness

    /// The property the container is chosen for, and the one that is easiest to
    /// lose by accident: `LazyVStack` is lazy because a scroll view tells it
    /// what is visible, and a plain `VStack` in the same position builds every
    /// row whether or not anyone will ever see it.
    ///
    /// The bound is deliberately loose. How far beyond the viewport SwiftUI
    /// realises is not documented, varies by OS version, and is not what this
    /// asserts — "a fraction of four hundred" is the claim, and pinning it to a
    /// number would be asserting an implementation detail that is free to
    /// change under a green suite.
    @Test("A lazy stack realises a fraction of its rows where a plain stack builds all of them")
    func lazyStackRealisesOnlyWhatIsNearTheViewport() async {
        let rows = 400

        let lazyLedger = BodyEvaluationLedger()
        let lazyHarness = await RenderHarness.mount(
            LazyRealisationHarness(count: rows, rowHeight: 44, ledger: lazyLedger)
        )
        let realised = lazyLedger.count(of: LazyProbeLabel.lazyRow)
        lazyHarness.dismount()

        let eagerLedger = BodyEvaluationLedger()
        let eagerHarness = await RenderHarness.mount(
            EagerRealisationHarness(count: rows, rowHeight: 44, ledger: eagerLedger)
        )
        let built = eagerLedger.count(of: LazyProbeLabel.eagerRow)
        eagerHarness.dismount()

        let counts: Comment = "lazy realised \(realised) of \(rows); the plain VStack built \(built)"
        #expect(realised >= 1, counts)
        #expect(realised < rows, counts)
        #expect(built >= rows, counts)
    }

    // MARK: - Stable ids versus positions

    /// The finding. Inserting a row at the front of the collection is the
    /// cheapest way to tell the two keying schemes apart, because it moves every
    /// item to a new position without changing any of them.
    ///
    /// Under stable ids the inserted row is a view SwiftUI has not seen before,
    /// so it mounts and every other row carries on being itself. Under index
    /// ids nothing new appears at the front at all — position 0 already existed
    /// and simply renders different text now — and a row mounts at the *end*
    /// instead, holding an item that was already on screen a moment ago under a
    /// different identity.
    ///
    /// Read that second sentence as a bug report and it is the familiar one: the
    /// state a row was holding stays with the position rather than following the
    /// row, so an expanded disclosure, a half-typed field or a running animation
    /// ends up attached to whichever item slid into that slot.
    @Test("A prepend mounts the new row under stable ids and remounts the tail under index ids")
    func prependMountsTheNewRowOnlyUnderStableIdentity() async {
        let driver = LazyRowDriver(items: PagedItem.range(1...5))
        let ledger = BodyEvaluationLedger()
        let harness = await RenderHarness.mount(LazyIdentityHarness(driver: driver, ledger: ledger))
        defer { harness.dismount() }

        // The mount itself. Asserted before the change so that a harness whose
        // rows never appeared reads as a broken harness rather than as a finding.
        #expect(ledger.count(of: LazyProbeLabel.stable(1)) == 1)
        #expect(ledger.count(of: LazyProbeLabel.indexed(1)) == 1)

        driver.items.insert(PagedItem(id: 0), at: 0)
        await harness.settle()

        let counts: Comment = "appearances: \(ledger.snapshot)"
        #expect(ledger.count(of: LazyProbeLabel.stable(0)) == 1, counts)
        #expect(ledger.count(of: LazyProbeLabel.indexed(0)) == 0, counts)
        #expect(ledger.count(of: LazyProbeLabel.stable(5)) == 1, counts)
        #expect(ledger.count(of: LazyProbeLabel.indexed(5)) >= 2, counts)
    }

    // MARK: - The `.id()` pitfall

    /// `.id(changingValue)` on a row is the wrong fix for a row that will not
    /// redraw, and this is what it costs: every row in the stack becomes a view
    /// the framework has never seen, so the realised range is torn down and
    /// mounted again from nothing.
    ///
    /// The two stacks beside it are the control. They are rendered by the same
    /// body, invalidated by the same change, and neither remounts anything —
    /// which is the point. A body re-running is not a row being replaced, and
    /// only one of those throws away what the row was holding.
    @Test("Keying a row on a changing value remounts every row; a stable id does not")
    func changingTheRowTagRemountsEveryRow() async {
        let driver = LazyRowDriver(items: PagedItem.range(1...5))
        let ledger = BodyEvaluationLedger()
        let harness = await RenderHarness.mount(LazyIdentityHarness(driver: driver, ledger: ledger))
        defer { harness.dismount() }

        #expect(ledger.count(of: LazyProbeLabel.tagged(3)) == 1)

        driver.token += 1
        await harness.settle()

        let counts: Comment = "appearances: \(ledger.snapshot)"
        #expect(ledger.count(of: LazyProbeLabel.tagged(3)) >= 2, counts)
        #expect(ledger.count(of: LazyProbeLabel.stable(3)) == 1, counts)
        #expect(ledger.count(of: LazyProbeLabel.indexed(3)) == 1, counts)
    }
}

// MARK: - Prefetch

/// Phase 10 item 2, second half. When a lazy stack asks for the next page.
///
/// The trigger is `onAppear` per row, so what decides whether a page loads is
/// which rows the stack realised — and that is a function of how tall a page is
/// relative to the viewport, not of anything the paginator can see. Both
/// directions are measured here against the same 402 × 874 harness window and
/// the same catalogue, with the row height as the only variable.
@Suite("Lazy stack prefetch", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct LazyStackPrefetchTests {

    /// The catalogue every test here pages through. Large enough that walking
    /// all of it is unmistakable in an assertion.
    private static let catalogue = 300

    /// The behaviour a paginated screen is supposed to have: one page on mount,
    /// and nothing further until the reader does something.
    ///
    /// At 200 points a row, forty rows are eight thousand points of content in
    /// an 874-point window, so the trigger row — five from the end — is roughly
    /// eight screens down and is never realised.
    @Test("A page taller than the viewport loads once and waits for the reader")
    func aPageTallerThanTheViewportDoesNotChain() async {
        let policy = PrefetchPolicy(pageSize: 40, distanceFromEnd: 5)
        let paginator = CursorPaginator(
            source: InMemoryCursorPageSource(PagedItem.range(1...Self.catalogue)),
            policy: policy
        )
        let harness = await RenderHarness.mount(
            LazyPaginationHarness(paginator: paginator, rowHeight: 200)
        )
        defer { harness.dismount() }

        await settleUntil(harness) { !paginator.items.isEmpty }
        await paginator.settled()

        // A second pass, so that a prefetch triggered by the rows the first page
        // realised has somewhere to happen before the count is read. Without it
        // this test would pass by being asked too early.
        await harness.settle()
        await paginator.settled()

        let loaded: Comment = "loaded \(paginator.items.count) of \(Self.catalogue), phase \(paginator.phase)"
        #expect(paginator.items.count == policy.pageSize, loaded)
        #expect(paginator.phase == .ready, loaded)
    }

    /// The trap, and the reason ``PrefetchPolicy``'s page size is a decision
    /// rather than a default to accept.
    ///
    /// At 44 points a row a twelve-row page is 528 points, which fits inside the
    /// window with room to spare. The last row of the page therefore appears the
    /// moment the page lands, the trigger fires, and the next page arrives
    /// without the reader having touched anything. It settles once the loaded
    /// content is taller than the viewport, which is the only thing stopping it
    /// — a page size chosen against a shorter row would not stop there.
    ///
    /// The assertion is bounded on both sides deliberately. That it loaded more
    /// than one page is the finding; that it stopped well short of the whole
    /// catalogue is what says the paginator's guards held while it happened.
    @Test("A page that fits on screen triggers the next one with nobody scrolling")
    func aPageThatFitsOnScreenChains() async {
        let policy = PrefetchPolicy(pageSize: 12, distanceFromEnd: 3)
        let paginator = CursorPaginator(
            source: InMemoryCursorPageSource(PagedItem.range(1...Self.catalogue)),
            policy: policy
        )
        let harness = await RenderHarness.mount(
            LazyPaginationHarness(paginator: paginator, rowHeight: 44)
        )
        defer { harness.dismount() }

        await settleUntil(harness) { paginator.items.count > policy.pageSize }
        await paginator.settled()

        let loaded: Comment = "loaded \(paginator.items.count) of \(Self.catalogue) at page size \(policy.pageSize)"
        #expect(paginator.items.count > policy.pageSize, loaded)
        #expect(paginator.items.count < Self.catalogue, loaded)
    }

    /// De-duplication is what makes the chain above safe rather than merely
    /// bounded: every trigger that fires while a load is in flight is turned
    /// away synchronously, so the rows that arrive are each other's successors
    /// and not the same page several times over.
    @Test("Chained prefetches deliver each row exactly once")
    func chainedPrefetchesDoNotDuplicateRows() async {
        let policy = PrefetchPolicy(pageSize: 12, distanceFromEnd: 3)
        let paginator = CursorPaginator(
            source: InMemoryCursorPageSource(PagedItem.range(1...Self.catalogue)),
            policy: policy
        )
        let harness = await RenderHarness.mount(
            LazyPaginationHarness(paginator: paginator, rowHeight: 44)
        )
        defer { harness.dismount() }

        await settleUntil(harness) { paginator.items.count > policy.pageSize }
        await paginator.settled()

        let ids = paginator.items.map(\.id)
        let loaded: Comment = "loaded ids: \(ids)"
        // Built from the count rather than as `1...ids.count`, because a load
        // that failed leaves no ids at all and `1...0` traps rather than failing.
        let expected = (0..<ids.count).map { $0 + 1 }
        #expect(Set(ids).count == ids.count, loaded)
        #expect(ids == expected, loaded)
    }
}
