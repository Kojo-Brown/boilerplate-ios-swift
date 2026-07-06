import Testing
@testable import BoilerplateiOSSwift

@MainActor
struct HomeViewModelTests {
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

    @Test func refreshReplacesItems() async {
        let sut = HomeViewModel()
        await sut.onAppear()
        let firstBatch = sut.items.map(\.id)

        await sut.refresh()

        // IDs should differ because each fetch creates new UUIDs
        #expect(sut.items.map(\.id) != firstBatch)
    }

    @Test func searchFiltersItems() async {
        let sut = HomeViewModel()
        await sut.onAppear()

        sut.searchQuery = "Item 1"

        #expect(sut.filteredItems.allSatisfy { $0.title.contains("1") })
    }

    @Test func emptySearchReturnsAllItems() async {
        let sut = HomeViewModel()
        await sut.onAppear()
        sut.searchQuery = "xyz"

        sut.searchQuery = ""

        #expect(sut.filteredItems.count == sut.items.count)
    }

    @Test func deleteItemsRemovesFromList() async {
        let sut = HomeViewModel()
        await sut.onAppear()
        let initialCount = sut.filteredItems.count

        sut.deleteItems(at: IndexSet(integer: 0))

        #expect(sut.items.count == initialCount - 1)
    }
}
