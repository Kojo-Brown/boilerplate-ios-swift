import SwiftUI

// MARK: - AppButton

/// PreviewProvider-style catalogue for `AppButton`.
/// Demonstrates the `PreviewProvider` protocol as an alternative to the `#Preview` macro.
struct AppButton_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            VStack(spacing: 16) {
                AppButton("Sign In") {}
                AppButton("Sign In", isLoading: true) {}
                AppButton("Sign In", isDisabled: true) {}
            }
            .padding()
            .previewDisplayName("Primary")

            VStack(spacing: 16) {
                AppButton("Cancel", style: .secondary) {}
                AppButton("Cancel", style: .secondary, isLoading: true) {}
            }
            .padding()
            .previewDisplayName("Secondary")

            VStack(spacing: 16) {
                AppButton("Delete Account", style: .destructive) {}
                AppButton("Delete Account", style: .destructive, isLoading: true) {}
            }
            .padding()
            .previewDisplayName("Destructive")
        }
    }
}

// MARK: - AppTextField

/// PreviewProvider-style catalogue for `AppTextField`.
struct AppTextField_Previews: PreviewProvider {
    static var previews: some View {
        Group {
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
            }
            .padding()
            .previewDisplayName("Normal")

            VStack(spacing: 24) {
                AppTextField(
                    "Email",
                    text: .constant("not-an-email"),
                    keyboardType: .emailAddress,
                    autocapitalization: .never,
                    autocorrectionDisabled: true,
                    errorMessage: "Please enter a valid email address."
                )
                AppTextField(
                    "Password",
                    text: .constant(""),
                    isSecure: true,
                    errorMessage: "Password is required."
                )
            }
            .padding()
            .previewDisplayName("Error State")

            AppTextField("Username", text: .constant(""))
                .padding()
                .previewDisplayName("Empty")
        }
    }
}

// MARK: - LoadingView

/// PreviewProvider-style catalogue for `LoadingView` and `InlineLoadingView`.
struct LoadingView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ZStack {
                Color.blue.opacity(0.3).ignoresSafeArea()
                Text("Background content")
                LoadingView(message: "Please wait…")
            }
            .previewDisplayName("Overlay with message")

            ZStack {
                Color.blue.opacity(0.3).ignoresSafeArea()
                LoadingView()
            }
            .previewDisplayName("Overlay – no message")

            InlineLoadingView(message: "Loading items…")
                .frame(height: 200)
                .previewDisplayName("Inline")

            NavigationStack {
                List {
                    Text("Row 1")
                    Text("Row 2")
                }
                .navigationTitle("Home")
                .loadingOverlay(isLoading: true, message: "Syncing…")
            }
            .previewDisplayName("View modifier")
        }
    }
}

// MARK: - AdaptiveStack

/// PreviewProvider-style catalogue for `AdaptiveStack`.
struct AdaptiveStack_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            AdaptiveStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 8).fill(.blue).frame(height: 100)
                RoundedRectangle(cornerRadius: 8).fill(.green).frame(height: 100)
                RoundedRectangle(cornerRadius: 8).fill(.orange).frame(height: 100)
            }
            .padding()
            .previewDisplayName("AdaptiveStack – Compact")
            .environment(\.horizontalSizeClass, .compact)

            AdaptiveStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 8).fill(.blue).frame(height: 100)
                RoundedRectangle(cornerRadius: 8).fill(.green).frame(height: 100)
                RoundedRectangle(cornerRadius: 8).fill(.orange).frame(height: 100)
            }
            .padding()
            .previewDisplayName("AdaptiveStack – Regular")
            .environment(\.horizontalSizeClass, .regular)
        }
    }
}
