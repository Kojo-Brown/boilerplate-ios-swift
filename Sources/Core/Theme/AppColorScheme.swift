import SwiftUI

// MARK: - Preference enum

/// User's preferred colour scheme for the app.
///
/// Persisted to `UserDefaults` via `AppState.colorSchemePreference`.
/// The system default follows `@Environment(\.colorScheme)` at the OS level.
package enum AppColorScheme: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    package var id: String { rawValue }

    package var label: String {
        switch self {
        case .system: "System"
        case .light:  "Light"
        case .dark:   "Dark"
        }
    }

    package var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light:  "sun.max"
        case .dark:   "moon"
        }
    }

    /// Returns `nil` (follow the OS) for `.system`, or an explicit scheme otherwise.
    package var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light:  .light
        case .dark:   .dark
        }
    }

    package static let defaultsKey = "app.colorSchemePreference"
}
