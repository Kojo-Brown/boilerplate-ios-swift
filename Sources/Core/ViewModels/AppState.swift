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

    /// Forgets the one preference this type persists.
    ///
    /// Phase 12 item 4. The UI test host calls this at launch, through
    /// `UITestLaunch`, so a journey starts from the appearance a new install
    /// has rather than from whatever the previous journey left in the
    /// simulator's defaults.
    ///
    /// It lives here rather than in the composition root for the reason the
    /// writes above it do: this type owns the key, and a second place that
    /// knew the key's name would be a second place to update when it changes.
    /// It is also what keeps `UserDefaults` — a required-reason API — declared
    /// in exactly the one target's privacy manifest that already declares it.
    /// See `docs/privacy-manifest.md`.
    ///
    /// `removeObject` rather than a write of `.system`: the next read then
    /// takes the default in `init()` above, which is the first-launch path.
    ///
    /// `nonisolated` because it touches none of this type's state — the
    /// alternative is every caller of it inheriting the main actor for a
    /// `removeObject`, which is isolation bought for nothing.
    package nonisolated static func forgetPersistedPreferences() {
        UserDefaults.standard.removeObject(forKey: AppColorScheme.defaultsKey)
    }
}
