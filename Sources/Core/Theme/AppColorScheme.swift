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

    /// The name shown in the settings picker.
    ///
    /// A `LocalizedStringResource` rather than a `String`, because the three
    /// words here are the ones a reader sees and a `String` returned from a
    /// model type is a string that never gets translated — it is already
    /// resolved by the time any view could have asked for it in another
    /// language. `CoreStrings` holds the key; `Text(_:)` and `.string` resolve.
    package var label: LocalizedStringResource {
        CoreStrings.appearance(self)
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
