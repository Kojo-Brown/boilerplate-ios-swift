import SwiftUI

// MARK: - Component

/// Reusable design-system text field with label, error state, and secure-input variant.
///
/// Usage:
/// ```swift
/// // Plain text
/// AppTextField("Email", text: $email, keyboardType: .emailAddress)
///
/// // Secure (password)
/// AppTextField("Password", text: $password, isSecure: true)
///
/// // With error
/// AppTextField("Email", text: $email, errorMessage: viewModel.emailError)
/// ```
struct AppTextField: View {
    let label: String
    @Binding var text: String
    var isSecure: Bool = false
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType? = nil
    var autocapitalization: TextInputAutocapitalization = .sentences
    var autocorrectionDisabled: Bool = false
    var errorMessage: String? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(labelColor)

            inputField
                .textContentType(textContentType)
                .keyboardType(keyboardType)
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled(autocorrectionDisabled)
                .focused($isFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background(fieldBackground)
                .overlay(fieldBorder)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .animation(.easeInOut(duration: 0.15), value: isFocused)
                .animation(.easeInOut(duration: 0.15), value: errorMessage)

            if let error = errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .imageScale(.small)
                    Text(error)
                        .font(.caption)
                }
                .foregroundStyle(.red)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.default, value: errorMessage)
    }

    // MARK: - Private

    @ViewBuilder
    private var inputField: some View {
        if isSecure {
            SecureField(label, text: $text)
        } else {
            TextField(label, text: $text)
        }
    }

    private var fieldBackground: some ShapeStyle {
        if errorMessage != nil {
            return AnyShapeStyle(Color.red.opacity(0.06))
        }
        return AnyShapeStyle(Material.regularMaterial)
    }

    private var fieldBorder: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(borderColor, lineWidth: isFocused ? 2 : 1)
    }

    private var borderColor: Color {
        if errorMessage != nil { return .red }
        if isFocused { return .accentColor }
        return Color.secondary.opacity(0.2)
    }

    private var labelColor: Color {
        if errorMessage != nil { return .red }
        if isFocused { return .accentColor }
        return .secondary
    }
}

// MARK: - Previews

#Preview("States") {
    VStack(spacing: 24) {
        AppTextField(
            "Email",
            text: .constant("user@example.com"),
            keyboardType: .emailAddress,
            autocapitalization: .never,
            autocorrectionDisabled: true
        )

        AppTextField(
            "Password",
            text: .constant("secret"),
            isSecure: true,
            textContentType: .password
        )

        AppTextField(
            "Email",
            text: .constant("bad-email"),
            keyboardType: .emailAddress,
            autocapitalization: .never,
            autocorrectionDisabled: true,
            errorMessage: "Please enter a valid email address."
        )
    }
    .padding()
}
