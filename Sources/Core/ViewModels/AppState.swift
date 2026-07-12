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
final class AppState {
    var isAuthenticated = false
    var currentUserEmail: String?

    /// User's preferred colour scheme — persisted across launches.
    var colorSchemePreference: AppColorScheme {
        didSet {
            UserDefaults.standard.set(
                colorSchemePreference.rawValue,
                forKey: AppColorScheme.defaultsKey
            )
        }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: AppColorScheme.defaultsKey) ?? ""
        colorSchemePreference = AppColorScheme(rawValue: saved) ?? .system
    }

    func signOut() {
        isAuthenticated = false
        currentUserEmail = nil
    }
}
