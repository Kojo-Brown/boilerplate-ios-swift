import SwiftUI

// MARK: - Banner

/// The message a screen shows when something it tried has failed, and the way
/// past it.
///
/// It is a component because of the shape it replaces: an `HStack` carrying
/// `.onTapGesture { clearError() }`, written inline in `LoginView`. A tap
/// gesture on a container is a dismissal VoiceOver can neither perform nor
/// report — the gesture publishes no trait, no action and nothing to
/// activate — so the only way to get the banner off the screen was unavailable
/// to the people most likely to be reading it slowly. The gesture was not
/// *hard* to reach; it was absent from the tree.
///
/// Three properties make it reachable, and all three are why this is a type
/// rather than four more modifiers at the call site:
///
/// * **The icon is hidden.** It repeats the word the label already says, and a
///   warning triangle that announces itself as "exclamation mark triangle
///   fill" is noise in front of the sentence that matters.
/// * **The banner is one element, not two.** Combined, it is a single stop
///   that reads the whole message; left as an icon beside a string it is two
///   stops, and the first says nothing.
/// * **Dismissal is an `.accessibilityAction(named:)`.** That is how VoiceOver
///   offers something which is not an element's primary activation, and it
///   runs the same closure the tap gesture does, so the two cannot drift.
///
/// The banner deliberately stays static text rather than becoming a button.
/// Its job is to be read; dismissing it is a convenience on top, and a
/// `.isButton` trait would promise that activating it does something the
/// reader wants, when what it does is take the message away.
package struct InlineErrorBanner: View {

    private let message: String
    private let onDismiss: (() -> Void)?

    /// - Parameter onDismiss: `nil` makes the banner a statement rather than
    ///   something to dismiss. A screen that clears its own error on the next
    ///   attempt has nothing to offer here, and an action that does nothing is
    ///   worse than no action at all: VoiceOver announces it either way.
    package init(_ message: String, onDismiss: (() -> Void)? = nil) {
        self.message = message
        self.onDismiss = onDismiss
    }

    @ViewBuilder
    package var body: some View {
        if let onDismiss {
            banner
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(spokenMessage)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityAction(named: Text(FeatureStrings.Component.dismiss), onDismiss)
        } else {
            banner
                .accessibilityElement(children: .combine)
                .accessibilityLabel(spokenMessage)
                .accessibilityAddTraits(.isStaticText)
        }
    }

    // MARK: - Private

    /// "Error" is said rather than drawn, because the triangle that says it to
    /// everybody else is hidden. Without it the banner reads as a bare
    /// sentence and sounds like any other paragraph on the screen.
    private var spokenMessage: Text {
        Text(FeatureStrings.Component.spokenError(message))
    }

    private var banner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline)
        }
        .foregroundStyle(.red)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Previews

#Preview("Dismissible") {
    InlineErrorBanner("Incorrect email or password.") {}
        .padding()
}

#Preview("Statement only") {
    InlineErrorBanner("We could not reach the server.")
        .padding()
}

#Preview("At an accessibility text size") {
    InlineErrorBanner("Incorrect email or password. Please try again.") {}
        .padding()
        .dynamicTypeSize(.accessibility3)
}
