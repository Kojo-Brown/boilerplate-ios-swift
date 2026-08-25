import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Color + light/dark convenience

extension Color {
    /// Creates a colour that resolves to different values in light and dark mode.
    ///
    /// Usage:
    /// ```swift
    /// let teal = Color(light: Color(hex: "0A7EA4"), dark: Color(hex: "3FBDCE"))
    /// ```
    package init(light lightColor: Color, dark darkColor: Color) {
        self.init(UIColor(light: UIColor(lightColor), dark: UIColor(darkColor)))
    }
}

extension UIColor {
    /// Trait-collection–aware colour that switches between `light` and `dark` variants.
    package convenience init(light: UIColor, dark: UIColor) {
        self.init { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        }
    }
}

// MARK: - Semantic colour tokens

/// App-wide semantic colour tokens.
///
/// These complement SwiftUI system colours (`.primary`, `.secondary`, `.accentColor`)
/// with project-specific values that adapt automatically to the active colour scheme.
///
/// Views that need explicit scheme-aware branching can read
/// `@Environment(\.colorScheme)` and pass it to the static helpers below.
///
/// Usage:
/// ```swift
/// struct ExampleView: View {
///     @Environment(\.colorScheme) private var colorScheme
///
///     var body: some View {
///         Text("Hello")
///             .foregroundStyle(AppColors.label)
///             .background(AppColors.surface)
///             .overlay(AppColors.divider(for: colorScheme))
///     }
/// }
/// ```
package struct AppColors {

    // MARK: - Surface

    /// Primary background surface — adapts to system light/dark.
    package static let surface = Color(.systemBackground)

    /// Grouped/secondary background (e.g. list inset sections).
    package static let secondaryBackground = Color(.secondarySystemBackground)

    /// Elevated surface (e.g. cards, sheets).
    package static let elevatedSurface = Color(.tertiarySystemBackground)

    // MARK: - Text

    /// Primary label — matches `Color.primary`.
    package static let label = Color(.label)

    /// Secondary label — matches `Color.secondary`.
    package static let secondaryLabel = Color(.secondaryLabel)

    /// Placeholder / hint text.
    package static let placeholderLabel = Color(.placeholderText)

    // MARK: - Interactive

    /// App accent colour — set in Asset Catalog "AccentColor".
    package static let accent = Color.accentColor

    // MARK: - Status

    /// Semantic success green — brighter in dark mode.
    package static let success = Color(
        light: Color(red: 0.13, green: 0.69, blue: 0.40),
        dark: Color(red: 0.24, green: 0.84, blue: 0.55)
    )

    /// Semantic warning amber — brighter in dark mode.
    package static let warning = Color(
        light: Color(red: 0.95, green: 0.62, blue: 0.07),
        dark: Color(red: 1.00, green: 0.75, blue: 0.20)
    )

    /// Semantic error red — matches `.red` but as a named token.
    package static let destructive = Color(.systemRed)

    // MARK: - Structural

    /// Thin separator/divider line.
    package static func divider(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.08)
    }

    /// Card shadow opacity that reads well in both schemes.
    package static func shadowOpacity(for scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.4 : 0.08
    }
}

// MARK: - Preview

#Preview("Semantic Colours — Light") {
    colorGrid
        .preferredColorScheme(.light)
}

#Preview("Semantic Colours — Dark") {
    colorGrid
        .preferredColorScheme(.dark)
}

@MainActor
private var colorGrid: some View {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 12) {
            swatch("Surface", AppColors.surface)
            swatch("Secondary Bg", AppColors.secondaryBackground)
            swatch("Elevated Surface", AppColors.elevatedSurface)
            swatch("Label", AppColors.label)
            swatch("Secondary Label", AppColors.secondaryLabel)
            swatch("Placeholder", AppColors.placeholderLabel)
            swatch("Accent", AppColors.accent)
            swatch("Success", AppColors.success)
            swatch("Warning", AppColors.warning)
            swatch("Destructive", AppColors.destructive)
        }
        .padding()
    }
    .background(AppColors.secondaryBackground)
}

@MainActor
private func swatch(_ name: String, _ color: Color) -> some View {
    VStack(spacing: 6) {
        RoundedRectangle(cornerRadius: 8)
            .fill(color)
            .frame(height: 56)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
        Text(name)
            .font(.caption2)
            .foregroundStyle(AppColors.secondaryLabel)
            .multilineTextAlignment(.center)
    }
}
