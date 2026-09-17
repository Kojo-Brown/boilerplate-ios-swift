import SwiftUI

// MARK: - Dynamic Type for controls

/// A full-width control's minimum height, scaled with the reader's text size.
///
/// `.frame(height: 50)` is the shape this replaces, and it is wrong in one way
/// that never shows up at the default text size: a fixed height is a *maximum*
/// as well as a minimum. Fifty points hold a 17-point label with room to spare
/// and hold a 53-point one — roughly what the body font becomes at
/// `AX5` — not at all, so the label is clipped through the middle on exactly
/// the screens where it most needs to be legible. Nothing warns about it. The
/// build is green, the layout is valid, and every preview in the file renders
/// at `.large`.
///
/// `minHeight` lets the box grow to whatever its contents need.
/// `@ScaledMetric` keeps the floor itself in proportion, so a control does not
/// stop being a comfortable target the moment its text outgrows it: 50 points
/// at `.large` clears the 44-point minimum in the Human Interface Guidelines
/// with margin, and scales from there.
package struct ScaledControlHeight: ViewModifier {

    @ScaledMetric(relativeTo: .body) private var minimumHeight: CGFloat = 50

    package func body(content: Content) -> some View {
        content.frame(minHeight: minimumHeight)
    }
}

// MARK: - View extensions

extension View {

    /// Gives a control a floor rather than a ceiling — see ``ScaledControlHeight``.
    package func scaledControlHeight() -> some View {
        modifier(ScaledControlHeight())
    }

    /// States that a control is busy, as its accessibility *value*.
    ///
    /// A spinner is a picture. It says "wait" to somebody who can see it and
    /// nothing whatsoever to VoiceOver, which goes on reading the label the
    /// spinner replaced — so a button mid-request and a button waiting to be
    /// pressed sound identical, and the second press is the one that produces
    /// the duplicate request. The controls in this package hide the spinner
    /// from the accessibility tree (it carries no information the label does
    /// not) and say the wait here instead.
    ///
    /// The value, specifically, and not the label: a label is what a control
    /// *is*, which has not changed, and VoiceOver reads a changed value on the
    /// element the reader is already focused on. Folding "Loading" into the
    /// label would also make the button a different control every time it was
    /// pressed.
    ///
    /// - Parameter activity: what the control is doing, in the present
    ///   participle — "Signing in", not "Sign in". It is read after the label,
    ///   so "Sign In, Signing in" is the sentence to write it against.
    package func accessibilityBusy(_ isBusy: Bool, doing activity: String) -> some View {
        accessibilityValue(isBusy ? Text(activity) : Text(verbatim: ""))
    }
}
