import XCTest
@testable import BoilerplateiOSSwift

/// XCTest suite for `HomeViewModel` with `@MainActor` isolation.
///
/// `HomeViewModel` is `@Observable @MainActor`, so all assertions can be made
/// synchronously after awaiting any async action — the actor guarantees writes
/// are visible on the same context.
@MainActor
final class HomeViewModelXCTests: XCTestCase {

    // MARK: - Initial state

    func testInitialItemsAreEmpty() {
        let sut = HomeViewModel()
        XCTAssertTrue(sut.items.isEmpty)
    }

    func testInitialSearchQueryIsEmpty() {
        let sut = HomeViewModel()
        XCTAssertTrue(sut.searchQuery.isEmpty)
    }

    func testInitialIsLoadingIsFalse() {
        let sut = HomeViewModel()
        XCTAssertFalse(sut.isLoading)
    }

    func testInitialErrorMessageIsNil() {
        let sut = HomeViewModel()
        XCTAssertNil(sut.errorMessage)
    }

    // MARK: - onAppear

    func testOnAppearLoadsItems() async {
        let sut = HomeViewModel()
        XCTAssertTrue(sut.items.isEmpty)

        await sut.onAppear()

        XCTAssertFalse(sut.items.isEmpty)
        XCTAssertFalse(sut.isLoading)
    }

    func testOnAppearSetsIsLoadingFalseAfterCompletion() async {
        let sut = HomeViewModel()

        await sut.onAppear()

        XCTAssertFalse(sut.isLoading)
    }

    func testOnAppearIsIdempotentWhenItemsAlreadyLoaded() async {
        let sut = HomeViewModel()
        await sut.onAppear()
        let firstCount = sut.items.count

        await sut.onAppear()

        XCTAssertEqual(sut.items.count, firstCount)
    }

    // MARK: - refresh

    func testRefreshReplacesExistingItems() async {
        let sut = HomeViewModel()
        await sut.onAppear()
        let firstBatch = sut.items.map(\.id)

        await sut.refresh()

        // Each fetch generates new UUIDs, so IDs must differ
        XCTAssertNotEqual(sut.items.map(\.id), firstBatch)
    }

    func testRefreshClearsIsLoadingOnCompletion() async {
        let sut = HomeViewModel()

        await sut.refresh()

        XCTAssertFalse(sut.isLoading)
    }

    // MARK: - Search filtering

    func testEmptySearchQueryReturnsAllItems() async {
        let sut = HomeViewModel()
        await sut.onAppear()

        sut.searchQuery = ""

        XCTAssertEqual(sut.filteredItems.count, sut.items.count)
    }

    func testSearchQueryFiltersToMatchingItems() async {
        let sut = HomeViewModel()
        await sut.onAppear()

        sut.searchQuery = "Item 1"

        XCTAssertTrue(sut.filteredItems.allSatisfy { $0.title.contains("1") })
    }

    func testNonMatchingQueryReturnsNoItems() async {
        let sut = HomeViewModel()
        await sut.onAppear()

        sut.searchQuery = "xyzzy_nomatch"

        XCTAssertTrue(sut.filteredItems.isEmpty)
    }

    func testClearingQueryRestoresAllItems() async {
        let sut = HomeViewModel()
        await sut.onAppear()
        sut.searchQuery = "xyzzy_nomatch"
        XCTAssertTrue(sut.filteredItems.isEmpty)

        sut.searchQuery = ""

        XCTAssertEqual(sut.filteredItems.count, sut.items.count)
    }

    func testSearchIsCaseInsensitive() async {
        let sut = HomeViewModel()
        await sut.onAppear()

        sut.searchQuery = "item 1"

        XCTAssertFalse(sut.filteredItems.isEmpty)
    }

    // MARK: - deleteItems

    func testDeleteItemsRemovesOneItem() async {
        let sut = HomeViewModel()
        await sut.onAppear()
        let initialCount = sut.filteredItems.count

        sut.deleteItems(at: IndexSet(integer: 0))

        XCTAssertEqual(sut.items.count, initialCount - 1)
    }

    func testDeleteItemsRemovesCorrectItem() async {
        let sut = HomeViewModel()
        await sut.onAppear()
        let targetID = sut.filteredItems[0].id

        sut.deleteItems(at: IndexSet(integer: 0))

        XCTAssertFalse(sut.items.contains(where: { $0.id == targetID }))
    }

    func testDeleteMultipleItemsReducesCountCorrectly() async {
        let sut = HomeViewModel()
        await sut.onAppear()
        let initialCount = sut.filteredItems.count

        sut.deleteItems(at: IndexSet([0, 1, 2]))

        XCTAssertEqual(sut.items.count, initialCount - 3)
    }

    // MARK: - Live updates lifecycle

    func testStopLiveUpdatesDoesNotCrashWhenNeverStarted() {
        let sut = HomeViewModel()
        sut.stopLiveUpdates()
        // No assertion needed — absence of crash is the expectation
    }

    func testStartAndStopLiveUpdatesDoesNotLeakTask() {
        let sut = HomeViewModel()
        sut.startLiveUpdates(interval: .seconds(60))
        sut.stopLiveUpdates()
        // Subsequent stop is a no-op
        sut.stopLiveUpdates()
    }

    func testOnDisappearCancelsLiveUpdates() {
        let sut = HomeViewModel()
        sut.startLiveUpdates(interval: .seconds(60))

        sut.onDisappear()

        // A second onDisappear must not crash
        sut.onDisappear()
    }
}
