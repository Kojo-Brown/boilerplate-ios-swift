import Foundation
import Testing
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Features
@testable import Networking

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
