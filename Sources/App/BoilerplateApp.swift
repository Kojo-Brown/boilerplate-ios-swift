import Core
import Features
import SwiftData
import SwiftUI
import os

@main
struct BoilerplateApp: App {
    @State private var appState: AppState
    @State private var coordinator = AppCoordinator()

    /// Watched so the background refresh is (re)scheduled the moment the app
    /// stops being in front of somebody.
    ///
    /// Scheduling on the way *out* rather than at launch is Apple's documented
    /// placement and is the one that matches what the request means: the
    /// earliest-begin date is a floor measured from now, and "now" at launch is
    /// a moment the app is about to spend in the foreground anyway. It also
    /// keeps the first `BGTaskScheduler.submit` of a build off the launch path,
    /// which matters more than it looks — an identifier missing from
    /// `BGTaskSchedulerPermittedIdentifiers` raises rather than throws, so on a
    /// misconfigured app this is the difference between a background feature
    /// that does not work and an app that cannot start.
    @Environment(\.scenePhase) private var scenePhase

    /// The composition root, built once for the process. Everything below this
    /// line receives its collaborators; nothing below it names one.
    private let dependencies: AppContainer

    private let container: ModelContainer

    /// The app's one subscriber to its own session events.
    ///
    /// Held for the life of the process rather than attached to a view, because
    /// what it applies must happen whether or not the screen that announced it
    /// is still on screen — and `RootView` swaps its entire subtree on the very
    /// state this observer sets, so a `.task` on either branch would be torn
    /// down by the event it had just delivered. `consumers` holds `self` weakly,
    /// so this stored property is also what keeps it alive.
    private let session: SessionObserver

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

        let state = AppState()
        let graph = AppContainer.live(
            userStore: SwiftDataUserPersistenceService(context: modelContainer.mainContext)
        )

        // Subscribed here, before a single view exists, which is what makes the
        // first event unmissable: `EventBus` registers synchronously, so the app
        // is listening before anything can be tapped. See `SessionObserver`.
        let observer = graph.makeSessionObserver(appState: state)
        observer.start()

        container = modelContainer
        dependencies = graph
        session = observer
        _appState = State(wrappedValue: state)
    }

    var body: some Scene {
        // Bound to a local before the scene, so the handler below captures the
        // coordinator and not `self`. The action is `@Sendable` and this type
        // holds `@State`; more to the point, that closure can run in a process
        // the system launched for nothing but this task, and a handler that
        // reached back into the `App` value would be rebuilding the graph
        // inside the one code path nobody is watching.
        let refresher = dependencies.backgroundRefresh

        WindowGroup {
            RootView(container: dependencies)
                .environment(appState)
                .environment(coordinator)
                // Apply the user's colour scheme preference at the window level.
                // `nil` means "follow the system setting".
                .preferredColorScheme(appState.colorSchemePreference.colorScheme)
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .background else { return }
                    BoilerplateApp.scheduleBackgroundRefresh(refresher)
                }
        }
        .modelContainer(container)
        // Registration, launch and completion in one modifier. Written by hand
        // this is `BGTaskScheduler.register(forTaskWithIdentifier:using:)` in an
        // app delegate, a `Task` bridged to `task.expirationHandler`, and a
        // `setTaskCompleted(success:)` on every exit path — and it is the last
        // of those that is usually missing, which the system answers by never
        // launching the task again. SwiftUI does all three, and cancels the
        // surrounding task on expiration, which is the signal
        // `BackgroundRefreshCoordinator` reports as `.expired`.
        .backgroundTask(.appRefresh(AppContainer.backgroundRefreshIdentifier)) {
            _ = await refresher.handle()
        }
    }

    /// Submits the next request, and says so in the log when it cannot.
    ///
    /// `scheduleNext()` throws on purpose — see its documentation — and this is
    /// the one caller with somewhere to put the failure. There is nothing to
    /// show a person: they backgrounded the app, and a refresh that will not
    /// happen is not an alert. What it must not be is silent, because the
    /// symptom is a feature that simply stops.
    private static func scheduleBackgroundRefresh(_ refresher: BackgroundRefreshCoordinator) {
        do {
            try refresher.scheduleNext()
        } catch {
            let message = "Could not schedule the background refresh: \(error.localizedDescription)"
            logger.error("\(message, privacy: .public)")
        }
    }

    private static let logger = Logger(
        subsystem: AppContainer.logSubsystem,
        category: "Lifecycle"
    )
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
            LoginView(dependencies: container)
        }
    }
}
