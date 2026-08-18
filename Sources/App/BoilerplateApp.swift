import SwiftUI
import SwiftData

@main
struct BoilerplateApp: App {
    @State private var appState = AppState()
    @State private var coordinator = AppCoordinator()

    /// The composition root, built once for the process. Everything below this
    /// line receives its collaborators; nothing below it names one.
    private let dependencies: AppContainer

    private let container: ModelContainer

    /// Spelled as an initialiser rather than as two property initialisers,
    /// because the graph now depends on the store and a stored property's
    /// default expression cannot read another stored property.
    ///
    /// The order is the point: the `ModelContainer` is opened first, its
    /// `mainContext` becomes the `UserPersistenceService`, and that store is
    /// handed to `AppContainer.live()`. Before Phase 8 item 3 the container was
    /// installed in the environment and read by nothing — `docs/solid.md`
    /// finding 6 — and this is the line that stops being true.
    init() {
        let modelContainer: ModelContainer
        do {
            modelContainer = try PersistenceController.makeContainer()
        } catch {
            fatalError("SwiftData container failed to initialise: \(error)")
        }

        container = modelContainer
        dependencies = AppContainer.live(
            userStore: SwiftDataUserPersistenceService(context: modelContainer.mainContext)
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(container: dependencies)
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
    /// Threaded down from `BoilerplateApp` rather than read from the
    /// environment — see `AppContainer` for why an `EnvironmentKey`'s mandatory
    /// `defaultValue` is the wrong shape for a dependency graph.
    let container: AppContainer

    @Environment(AppState.self) private var appState

    /// Spelled out rather than synthesised: a `private` stored property makes
    /// the memberwise initialiser `private` as well, and `private` scopes to the
    /// enclosing declaration rather than to the file — so even `BoilerplateApp`
    /// a few lines up could not call it.
    init(container: AppContainer) {
        self.container = container
    }

    var body: some View {
        if appState.isAuthenticated {
            AppNavigationView(container: container)
        } else {
            LoginView(container: container)
        }
    }
}
