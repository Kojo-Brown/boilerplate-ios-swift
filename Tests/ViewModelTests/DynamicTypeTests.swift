import SwiftUI
import Testing
@testable import Core
@testable import Features

// MARK: - Dynamic Type

/// Phase 10 item 6, the half about *size*.
///
/// Dynamic Type is the accessibility feature with the widest reach and the
/// least visible failures: nothing warns, no test goes red, and every preview
/// in the package renders at `.large`, where a control pinned to 50 points and
/// one with a 50-point floor are pixel-identical. They differ only at the sizes
/// nobody on the team has the simulator set to.
///
/// So the assertions here are comparisons between two renders of the same view
/// rather than absolute numbers. A height of 50 at `.large` is not a bug and a
/// height of 50 at `AX5` is; only reading both says which one you have. An
/// absolute assertion would also encode the font metrics of one iOS version
/// into the suite, and those are Apple's to change.
///
/// What each test would have caught, before this item: every one of these
/// controls sat inside `.frame(height: 50)`, which is a ceiling as much as a
/// floor, so all three numbers below were 50 at every text size and the labels
/// were clipped through the middle.
@Suite("Controls grow with the reader's text size", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct DynamicTypeTests {

    /// The tallest element published under `content` at `typeSize`.
    ///
    /// The tallest rather than the first: a control is one element in these
    /// harnesses, but taking a maximum means a test does not silently start
    /// measuring a label that happens to be published ahead of the button it
    /// belongs to.
    private static func height(
        of content: some View,
        at typeSize: DynamicTypeSize
    ) async -> CGFloat {
        let published = await publishedElements(at: typeSize, of: content)
        return published.map(\.frame.height).max() ?? 0
    }

    // MARK: - AppButton

    @Test("A button is taller at an accessibility text size than at the default")
    func appButtonGrowsWithTheTextSize() async {
        let atDefault = await Self.height(of: AppButton("Sign In") {}, at: .large)
        let atAccessibility = await Self.height(of: AppButton("Sign In") {}, at: .accessibility5)

        #expect(atDefault > 0, "nothing was published at .large")
        #expect(
            atAccessibility > atDefault,
            "AX5: \(atAccessibility), large: \(atDefault) — a pinned height reads the same at both"
        )
    }

    /// The floor the scaling is applied to. 44 points is the minimum target
    /// size in the Human Interface Guidelines; this control asks for 50 and the
    /// assertion is against the guideline, so a future change to the constant
    /// is free and a change that goes below the guideline is not.
    @Test("A button clears the minimum target size at the default text size")
    func appButtonClearsTheMinimumTargetSize() async {
        let atDefault = await Self.height(of: AppButton("Sign In") {}, at: .large)

        #expect(atDefault >= 44, "height: \(atDefault)")
    }

    /// A button mid-request has a spinner where its label was, and a spinner's
    /// intrinsic size does not move with the text size. So this is the case
    /// where the height can only be coming from the scaled floor — there is
    /// nothing else in the control that grew — which makes it the sharpest of
    /// the three: a pinned 50-point frame reads exactly 50 here.
    @Test("A button in flight is sized by the scaled floor, not by its spinner")
    func loadingButtonKeepsItsHeight() async {
        let loading = await Self.height(
            of: AppButton("Sign In", isLoading: true) {},
            at: .accessibility3
        )

        #expect(loading > 50, "loading: \(loading)")
    }

    // MARK: - BiometricAuthButton

    @Test("The biometric button grows with the text size too")
    func biometricButtonGrowsWithTheTextSize() async {
        let atDefault = await Self.height(of: Self.biometricButton(), at: .large)
        let atAccessibility = await Self.height(of: Self.biometricButton(), at: .accessibility5)

        #expect(atDefault > 0, "nothing was published at .large")
        #expect(atAccessibility > atDefault, "AX5: \(atAccessibility), large: \(atDefault)")
    }

    private static func biometricButton() -> BiometricAuthButton {
        let service = MockBiometricAuthService()
        service.stubbedBiometricType = .faceID
        return BiometricAuthButton(viewModel: BiometricAuthViewModel(service: service))
    }

    // MARK: - AppTextField

    /// Not a regression this item fixed — a text field has always grown with
    /// its own font — but the one control on the sign-in form that was already
    /// right, and worth holding there: a fixed height added to it later would
    /// fail here rather than in somebody's hands.
    @Test("A text field grows with the text size")
    func appTextFieldGrowsWithTheTextSize() async {
        let field = AppTextField("Email", text: .constant("someone@example.com"))
        let atDefault = await Self.height(of: field, at: .large)
        let atAccessibility = await Self.height(of: field, at: .accessibility5)

        #expect(atDefault > 0, "nothing was published at .large")
        #expect(atAccessibility > atDefault, "AX5: \(atAccessibility), large: \(atDefault)")
    }

    // MARK: - InlineErrorBanner

    @Test("The error banner grows with the text size")
    func errorBannerGrowsWithTheTextSize() async {
        let banner = InlineErrorBanner("Incorrect email or password.")
        let atDefault = await Self.height(of: banner, at: .large)
        let atAccessibility = await Self.height(of: banner, at: .accessibility5)

        #expect(atDefault > 0, "nothing was published at .large")
        #expect(atAccessibility > atDefault, "AX5: \(atAccessibility), large: \(atDefault)")
    }
}
