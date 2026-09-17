import SwiftUI

// MARK: - Component

/// Full-screen loading overlay rendered on top of existing content.
///
/// Attach with `.overlay` or via the `.loadingOverlay` modifier:
/// ```swift
/// ContentView()
///     .loadingOverlay(isLoading: viewModel.isLoading)
///
/// // Or with a custom message:
///     .loadingOverlay(isLoading: viewModel.isLoading, message: "Saving…")
/// ```
///
/// The overlay dims the background, shows a spinner and an optional message,
/// and blocks user interaction while visible.
package struct LoadingView: View {
    package var message: String?

    package var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.large)
                    .tint(.white)

                if let message {
                    Text(message)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
        .transition(.opacity)
        // One element, so the spinner and its message are a single stop rather
        // than a nameless one followed by a sentence.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message ?? "Loading")
        // The half that is not cosmetic. This overlay blocks touches for
        // everybody — that is what it is for — and blocked nothing at all for
        // VoiceOver, which went on swiping through the screen underneath and
        // activating controls that were, to every other user, unreachable.
        // `.isModal` is how a SwiftUI view says "ignore my siblings", and it is
        // the trait that makes the block mean the same thing to both.
        .accessibilityAddTraits(.isModal)
    }
}

// MARK: - Inline variant

/// Lightweight inline loading indicator for embedding inside list rows or
/// partial-content areas, without a full-screen overlay.
package struct InlineLoadingView: View {
    package var message: String?

    package var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.regular)

            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message ?? "Loading")
    }
}

// MARK: - View modifier

extension View {
    /// Overlays a `LoadingView` whenever `isLoading` is true.
    /// Animates in/out with a spring transition.
    package func loadingOverlay(isLoading: Bool, message: String? = nil) -> some View {
        overlay {
            if isLoading {
                LoadingView(message: message)
                    .animation(.spring(duration: 0.25), value: isLoading)
            }
        }
        .animation(.spring(duration: 0.25), value: isLoading)
    }
}

// MARK: - Previews

#Preview("Overlay") {
    ZStack {
        Color.blue.opacity(0.3).ignoresSafeArea()
        Text("Background content")
        LoadingView(message: "Please wait…")
    }
}

#Preview("Overlay – no message") {
    ZStack {
        Color.blue.opacity(0.3).ignoresSafeArea()
        LoadingView()
    }
}

#Preview("Inline") {
    InlineLoadingView(message: "Loading items…")
        .frame(height: 200)
        .border(.secondary)
}

#Preview("View modifier") {
    NavigationStack {
        List {
            Text("Row 1")
            Text("Row 2")
        }
        .navigationTitle("Home")
        .loadingOverlay(isLoading: true, message: "Syncing…")
    }
}
