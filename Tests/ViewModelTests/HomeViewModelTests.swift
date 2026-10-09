import Foundation
import Testing
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Features
@testable import Networking

/// `HomeViewModel` is `@Observable @MainActor`, so every assertion can be made
/// synchronously after awaiting an action: the actor guarantees the writes are
/// visible on the same context, and no expectation-and-wait dance is needed.
///
/// This suite absorbed `HomeViewModelXCTests`, the XCTest mirror of it. The
/// mirror held thirteen cases this file did not — the initial-state reads, the
/// non-matching and case-insensitive search paths, which row `deleteItems`
/// actually removes, and the live-update lifecycle — and seven that were the
/// same assertions written twice. The unique ones are below; the duplicates are not,
/// because two spellings of one assertion are one test and one maintenance
/// cost. See `docs/testing.md`.
@MainActor
struct HomeViewModelTests {

    // MARK: - Initial state

    @Test func newViewModelHoldsNoRows() {
        let sut = HomeViewModel()

        #expect(sut.items.isEmpty)
        #expect(sut.itemsVersion == 0)
    }

    @Test func newViewModelIsIdleWithNoQueryAndNoError() {
        let sut = HomeViewModel()

        #expect(sut.searchQuery.isEmpty)
        #expect(!sut.isLoading)
        #expect(sut.errorMessage == nil)
    }

    // MARK: - onAppear

    @Test func onAppearLoadsItems() async {
        let sut = HomeViewModel()
        #expect(sut.items.isEmpty)

        await sut.onAppear()

        #expect(!sut.items.isEmpty)
        #expect(!sut.isLoading)
    }

    @Test func onAppearIsIdempotent() async {
        let sut = HomeViewModel()
        await sut.onAppear()
        let firstCount = sut.items.count

        await sut.onAppear()

        #expect(sut.items.count == firstCount)
    }

    // MARK: - refresh

    /// This assertion used to read the other way round — "IDs should differ
    /// because each fetch creates new UUIDs" — and it was describing a defect
    /// rather than a requirement. `ForEach` matches rows by `id`, so a refresh
    /// that reissued every id meant SwiftUI removed ten rows and inserted ten
    /// others: row state discarded, the diff animating as a full replacement,
    /// and nothing in a test that counts rows able to see it. Identity belongs
    /// to the row, not to the request that read it.
    @Test func refreshKeepsRowIdentityStable() async {
        let sut = HomeViewModel()
        await sut.onAppear()
        let firstBatch = sut.items

        await sut.refresh()

        #expect(sut.items.map(\.id) == firstBatch.map(\.id))
        #expect(sut.items == firstBatch)
    }

    @Test func refreshClearsIsLoadingOnCompletion() async {
        let sut = HomeViewModel()

        await sut.refresh()

        #expect(!sut.isLoading)
        #expect(sut.errorMessage == nil)
    }

    // MARK: - Search filtering

    @Test func searchFiltersItems() async {
        let sut = HomeViewModel()
        await sut.onAppear()

        sut.searchQuery = "Item 1"

        #expect(sut.filteredItems.allSatisfy { $0.title.contains("1") })
    }

    @Test func searchIsCaseInsensitive() async {
        let sut = HomeViewModel()
        await sut.onAppear()

        sut.searchQuery = "item 1"

        #expect(!sut.filteredItems.isEmpty)
    }

    @Test func nonMatchingQueryReturnsNoItems() async {
        let sut = HomeViewModel()
        await sut.onAppear()

        sut.searchQuery = "xyzzy_nomatch"

        #expect(sut.filteredItems.isEmpty)
    }

    @Test func clearingQueryRestoresAllItems() async {
        let sut = HomeViewModel()
        await sut.onAppear()
        sut.searchQuery = "xyzzy_nomatch"
        #expect(sut.filteredItems.isEmpty)

        sut.searchQuery = ""

        #expect(sut.filteredItems.count == sut.items.count)
    }

    // MARK: - deleteItems

    @Test func deleteItemsRemovesFromList() async {
        let sut = HomeViewModel()
        await sut.onAppear()
        let initialCount = sut.filteredItems.count

        sut.deleteItems(at: IndexSet(integer: 0))

        #expect(sut.items.count == initialCount - 1)
    }

    /// Offsets are into the *filtered* list — what the user swiped — so the
    /// row that disappears has to be the row they aimed at, not the row at
    /// the same index of the unfiltered corpus.
    @Test func deleteItemsRemovesTheRowAtThatOffset() async {
        let sut = HomeViewModel()
        await sut.onAppear()
        let targetID = sut.filteredItems[0].id

        sut.deleteItems(at: IndexSet(integer: 0))

        #expect(!sut.items.contains(where: { $0.id == targetID }))
    }

    @Test func deletingSeveralRowsRemovesAllOfThem() async {
        let sut = HomeViewModel()
        await sut.onAppear()
        let doomed = Set(sut.filteredItems[0...2].map(\.id))
        let initialCount = sut.filteredItems.count

        sut.deleteItems(at: IndexSet([0, 1, 2]))

        #expect(sut.items.count == initialCount - 3)
        #expect(sut.items.allSatisfy { !doomed.contains($0.id) })
    }

    // MARK: - Live updates lifecycle

    /// Stopping a stream that was never started, and stopping one twice, are
    /// both things a disappearing view does — `onDisappear` can arrive without
    /// a matching `startLiveUpdates`, and twice if the view is torn down while
    /// already off screen. Neither may trap, and neither may leave a row
    /// behind: the assertions are there because a test whose only expectation
    /// is "it did not crash" passes just as happily when the call it was
    /// guarding has been deleted.
    @Test func stoppingLiveUpdatesThatNeverStartedIsHarmless() {
        let sut = HomeViewModel()

        sut.stopLiveUpdates()
        sut.stopLiveUpdates()

        #expect(sut.items.isEmpty)
        #expect(sut.itemsVersion == 0)
    }

    @Test func stoppingLiveUpdatesTwiceIsHarmless() {
        let sut = HomeViewModel()
        sut.startLiveUpdates(interval: .seconds(60))

        sut.stopLiveUpdates()
        sut.stopLiveUpdates()

        // The polling task is a child of this `@MainActor` context and the
        // body never suspends between the three calls, so it cannot have run:
        // what is asserted is that cancellation happened before any batch
        // could land, not that the stream is merely slow.
        #expect(sut.items.isEmpty)
        #expect(sut.itemsVersion == 0)
    }

    @Test func onDisappearCancelsLiveUpdatesAndIsRepeatable() {
        let sut = HomeViewModel()
        sut.startLiveUpdates(interval: .seconds(60))

        sut.onDisappear()
        sut.onDisappear()

        #expect(sut.items.isEmpty)
        #expect(sut.itemsVersion == 0)
    }
}
