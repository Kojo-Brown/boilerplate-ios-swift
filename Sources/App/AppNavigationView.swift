import SwiftUI

/// Coordinator-backed `NavigationStack` for the authenticated app flow.
///
/// This is the single source of truth for route→view resolution.
/// Child views navigate by calling `coordinator.push(_:)` rather than
/// embedding `NavigationLink(destination:)` directly — keeping navigation
/// logic out of view bodies and testable in isolation.
struct AppNavigationView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator
        NavigationStack(path: $coordinator.path) {
            HomeView()
                .navigationDestination(for: Route.self) { route in
                    destination(for: route)
                }
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .settings:
            SettingsView()
        case .itemDetail(let id, let title):
            ItemDetailView(id: id, title: title)
        }
    }
}

#Preview {
    AppNavigationView()
        .environment(AppState())
        .environment(AppCoordinator())
}
