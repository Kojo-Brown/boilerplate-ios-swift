import SwiftUI

// MARK: - Preference enum

/// User's preferred colour scheme for the app.
///
/// Persisted to `UserDefaults` via `AppState.colorSchemePreference`.
/// The system default follows `@Environment(\.colorScheme)` at the OS level.
enum AppColorScheme: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light:  "Light"
        case .dark:   "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light:  "sun.max"
        case .dark:   "moon"
        }
    }

    /// Returns `nil` (follow the OS) for `.system`, or an explicit scheme otherwise.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light:  .light
        case .dark:   .dark
        }
    }

    static let defaultsKey = "app.colorSchemePreference"
}
