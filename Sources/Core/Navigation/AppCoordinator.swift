import SwiftUI
import Observation

/// Drives all programmatic navigation within the authenticated app.
///
/// Inject at the root via `.environment(coordinator)` and read in child views
/// with `@Environment(AppCoordinator.self) private var coordinator`.
/// Navigate by calling `coordinator.push(.someRoute)`.
@Observable
@MainActor
package final class AppCoordinator {
    package var path = NavigationPath()

    package init() {}

    /// Pushes a new destination onto the navigation stack.
    package func push(_ route: Route) {
        path.append(route)
    }

    /// Pops the top destination off the navigation stack.
    package func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    /// Returns to the root destination, clearing the entire stack.
    package func popToRoot() {
        path.removeLast(path.count)
    }

    /// Replaces the entire navigation stack with the given route sequence.
    package func replace(with routes: [Route]) {
        path.removeLast(path.count)
        routes.forEach { path.append($0) }
    }
}
