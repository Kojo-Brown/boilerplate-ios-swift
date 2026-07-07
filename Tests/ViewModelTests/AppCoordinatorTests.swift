import Testing
import SwiftUI
@testable import BoilerplateiOSSwift

@MainActor
struct AppCoordinatorTests {

    @Test("push appends a route to the path")
    func pushAppendsRoute() {
        let coordinator = AppCoordinator()
        coordinator.push(.settings)
        #expect(coordinator.path.count == 1)
    }

    @Test("pop removes the top route")
    func popRemovesTopRoute() {
        let coordinator = AppCoordinator()
        coordinator.push(.settings)
        coordinator.pop()
        #expect(coordinator.path.count == 0)
    }

    @Test("pop is a no-op on an empty path")
    func popOnEmptyPathIsNoOp() {
        let coordinator = AppCoordinator()
        coordinator.pop()
        #expect(coordinator.path.count == 0)
    }

    @Test("popToRoot clears all routes")
    func popToRootClearsAll() {
        let coordinator = AppCoordinator()
        coordinator.push(.settings)
        coordinator.push(.itemDetail(id: UUID(), title: "Test"))
        coordinator.popToRoot()
        #expect(coordinator.path.count == 0)
    }

    @Test("replace rebuilds the stack with new routes")
    func replaceRebuildsStack() {
        let coordinator = AppCoordinator()
        coordinator.push(.settings)

        let id = UUID()
        coordinator.replace(with: [.itemDetail(id: id, title: "New"), .settings])
        #expect(coordinator.path.count == 2)
    }

    @Test("replace on empty path builds stack from scratch")
    func replaceOnEmptyPath() {
        let coordinator = AppCoordinator()
        coordinator.replace(with: [.settings])
        #expect(coordinator.path.count == 1)
    }
}
