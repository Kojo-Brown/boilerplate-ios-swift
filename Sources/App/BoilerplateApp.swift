import SwiftUI
import SwiftData

@main
struct BoilerplateApp: App {
    @State private var appState = AppState()
    @State private var coordinator = AppCoordinator()

    private let container: ModelContainer = {
        do {
            return try PersistenceController.makeContainer()
        } catch {
            fatalError("SwiftData container failed to initialise: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(coordinator)
                // Apply the user's colour scheme preference at the window level.
                // `nil` means "follow the system setting".
                .preferredColorScheme(appState.colorSchemePreference.colorScheme)
        }
        .modelContainer(container)
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
