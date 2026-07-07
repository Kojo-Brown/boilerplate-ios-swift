import SwiftUI

@main
struct BoilerplateApp: App {
    @State private var appState = AppState()
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(coordinator)
        }
    }
}

/// Routes between authenticated and unauthenticated experiences.
/// The authenticated branch hands off to `AppNavigationView`, which owns the
/// coordinator-backed `NavigationStack`.
struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.isAuthenticated {
            AppNavigationView()
        } else {
            LoginView()
        }
    }
}
