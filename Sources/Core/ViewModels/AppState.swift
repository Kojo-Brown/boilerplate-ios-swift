import Foundation
import Observation

/// Application-wide state shared via the environment.
/// Injected at the root so child views can read auth status without prop drilling.
///
/// Usage in child view:
/// ```swift
/// @Environment(AppState.self) private var appState
/// ```
@Observable
@MainActor
package final class AppState {
    package var isAuthenticated = false
    package var currentUserEmail: String?

    /// User's preferred colour scheme — persisted across launches.
    package var colorSchemePreference: AppColorScheme {
        didSet {
            UserDefaults.standard.set(
                colorSchemePreference.rawValue,
                forKey: AppColorScheme.defaultsKey
            )
        }
    }

    package init() {
        let saved = UserDefaults.standard.string(forKey: AppColorScheme.defaultsKey) ?? ""
        colorSchemePreference = AppColorScheme(rawValue: saved) ?? .system
    }

    package func signOut() {
        isAuthenticated = false
        currentUserEmail = nil
    }
}
