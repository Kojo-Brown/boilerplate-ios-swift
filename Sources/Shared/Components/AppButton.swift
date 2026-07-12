import SwiftUI

// MARK: - Style

/// Visual and semantic role of an `AppButton`.
enum AppButtonStyle: Equatable {
    case primary
    case secondary
    case destructive
}

// MARK: - Component

/// Reusable design-system button with loading, disabled, and multi-variant support.
///
/// Usage:
/// ```swift
/// AppButton("Sign In", isLoading: viewModel.isLoading) {
///     await viewModel.login()
/// }
///
/// AppButton("Delete", style: .destructive) {
///     viewModel.delete()
/// }
/// ```
struct AppButton: View {
    let label: String
    var style: AppButtonStyle = .primary
    var isLoading: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // Keep label invisible (not removed) while loading so the
                // button width doesn't collapse.
                Text(label)
                    .font(.body.bold())
                    .opacity(isLoading ? 0 : 1)

                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(spinnerTint)
                        .controlSize(.regular)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
        }
        .buttonStyle(AppButtonPressStyle(appStyle: style))
        .disabled(isDisabled || isLoading)
        .animation(.default, value: isLoading)
    }

    // MARK: - Private

    private var spinnerTint: Color {
        switch style {
        case .primary:      .white
        case .secondary:    .accentColor
        case .destructive:  .white
        }
    }
}

// MARK: - Async convenience

extension AppButton {
    /// Creates an `AppButton` whose action is an `async` closure.
    /// Wraps the call in a detached `Task` so the button itself stays synchronous.
    init(
        _ label: String,
        style: AppButtonStyle = .primary,
        isLoading: Bool = false,
        isDisabled: Bool = false,
        asyncAction: @escaping @Sendable () async -> Void
    ) {
        self.label = label
        self.style = style
        self.isLoading = isLoading
        self.isDisabled = isDisabled
        self.action = { Task { await asyncAction() } }
    }
}

// MARK: - ButtonStyle

/// Custom `ButtonStyle` that applies the correct colours for each `AppButtonStyle`.
private struct AppButtonPressStyle: ButtonStyle {
    let appStyle: AppButtonStyle

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(background(pressed: configuration.isPressed))
            .foregroundStyle(foreground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }

    // MARK: - Colors

    private var foreground: Color {
        switch appStyle {
        case .primary:      .white
        case .secondary:    .accentColor
        case .destructive:  .white
        }
    }

    private func background(pressed: Bool) -> Color {
        let opacity: Double = pressed ? 0.8 : 1
        switch appStyle {
        case .primary:      return Color.accentColor.opacity(opacity)
        case .secondary:    return Color.accentColor.opacity(0.12 * (pressed ? 0.7 : 1))
        case .destructive:  return Color.red.opacity(opacity)
        }
    }
}

// MARK: - Previews

#Preview("Primary") {
    VStack(spacing: 16) {
        AppButton("Sign In") {}
        AppButton("Sign In", isLoading: true) {}
        AppButton("Sign In", isDisabled: true) {}
    }
    .padding()
}

#Preview("Secondary") {
    VStack(spacing: 16) {
        AppButton("Cancel", style: .secondary) {}
        AppButton("Cancel", style: .secondary, isLoading: true) {}
    }
    .padding()
}

#Preview("Destructive") {
    VStack(spacing: 16) {
        AppButton("Delete Account", style: .destructive) {}
        AppButton("Delete Account", style: .destructive, isLoading: true) {}
    }
    .padding()
}
