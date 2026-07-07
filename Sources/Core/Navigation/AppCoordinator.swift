import SwiftUI
import Observation

/// Drives all programmatic navigation within the authenticated app.
///
/// Inject at the root via `.environment(coordinator)` and read in child views
/// with `@Environment(AppCoordinator.self) private var coordinator`.
/// Navigate by calling `coordinator.push(.someRoute)`.
@Observable
@MainActor
final class AppCoordinator {
    var path = NavigationPath()

    init() {}

    /// Pushes a new destination onto the navigation stack.
    func push(_ route: Route) {
        path.append(route)
    }

    /// Pops the top destination off the navigation stack.
    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    /// Returns to the root destination, clearing the entire stack.
    func popToRoot() {
        path.removeLast(path.count)
    }

    /// Replaces the entire navigation stack with the given route sequence.
    func replace(with routes: [Route]) {
        path.removeLast(path.count)
        routes.forEach { path.append($0) }
    }
}
