import SwiftUI

@main
struct BoilerplateApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
        }
    }
}

/// Routes between authenticated and unauthenticated experiences.
/// `AppState` is `@Observable`, so `RootView` re-renders only when
/// `isAuthenticated` changes — no manual `objectWillChange` needed.
struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.isAuthenticated {
            HomeView()
        } else {
            LoginView()
        }
    }
}
