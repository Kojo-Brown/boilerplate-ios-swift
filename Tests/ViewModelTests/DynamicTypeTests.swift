import SwiftUI
import Testing
import UIKit
@testable import Core
@testable import Features

// MARK: - Measuring

/// One control and the text size to render it at — nothing around it, so the
/// size that comes back is the control's own.
struct MeasuredControl<Content: View>: View {

    let typeSize: DynamicTypeSize
    let content: Content

    var body: some View {
        content.dynamicTypeSize(typeSize)
    }
}

/// The height `content` asks for at `typeSize`, given `width`.
///
/// No window, no scene, no settling, and deliberately nothing to do with the
/// accessibility tree. `UIHostingController.sizeThatFits(in:)` is the layout
/// system answering a layout question — the same call SwiftUI makes of a hosted
/// view in an app — and whether a control grows with the reader's text size is
/// a layout question.
///
/// The independence is not incidental. These assertions were first written to
/// read heights off accessibility elements, and every one of them failed for a
/// reason that had nothing to do with Dynamic Type: a single unrelated
/// mechanism held the whole suite hostage. Not mounting a window also keeps
/// this suite from competing for the main actor with the body-evaluation
/// suites, which measure timing-sensitive counts.
@MainActor
func measuredHeight(
    of content: some View,
    at typeSize: DynamicTypeSize,
    width: CGFloat = 320
) -> CGFloat {
    let controller = UIHostingController(
        rootView: MeasuredControl(typeSize: typeSize, content: content)
    )
    // A large finite proposal rather than `.greatestFiniteMagnitude`: a control
    // here is sized by its contents, and an infinity is the one value a layout
    // can turn into a NaN.
    return controller.sizeThatFits(in: CGSize(width: width, height: 10_000)).height
}

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

    /// Shorthand for ``measuredHeight(of:at:width:)`` at this suite's width.
    private static func height(
        of content: some View,
        at typeSize: DynamicTypeSize
    ) -> CGFloat {
        measuredHeight(of: content, at: typeSize)
    }

    // MARK: - AppButton

    @Test("A button is taller at an accessibility text size than at the default")
    func appButtonGrowsWithTheTextSize() {
        let atDefault = Self.height(of: AppButton("Sign In") {}, at: .large)
        let atAccessibility = Self.height(of: AppButton("Sign In") {}, at: .accessibility5)

        #expect(atDefault > 0, "the control measured zero at .large")
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
    func appButtonClearsTheMinimumTargetSize() {
        let atDefault = Self.height(of: AppButton("Sign In") {}, at: .large)

        #expect(atDefault >= 44, "height: \(atDefault)")
    }

    /// A button mid-request has a spinner where its label was, and a spinner's
    /// intrinsic size does not move with the text size. So this is the case
    /// where the height can only be coming from the scaled floor — there is
    /// nothing else in the control that grew — which makes it the sharpest of
    /// the three: a pinned 50-point frame reads exactly 50 here.
    @Test("A button in flight is sized by the scaled floor, not by its spinner")
    func loadingButtonKeepsItsHeight() {
        let loading = Self.height(
            of: AppButton("Sign In", isLoading: true) {},
            at: .accessibility3
        )

        #expect(loading > 50, "loading: \(loading)")
    }

    // MARK: - BiometricAuthButton

    @Test("The biometric button grows with the text size too")
    func biometricButtonGrowsWithTheTextSize() {
        let atDefault = Self.height(of: Self.biometricButton(), at: .large)
        let atAccessibility = Self.height(of: Self.biometricButton(), at: .accessibility5)

        #expect(atDefault > 0, "the control measured zero at .large")
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
    func appTextFieldGrowsWithTheTextSize() {
        let field = AppTextField("Email", text: .constant("someone@example.com"))
        let atDefault = Self.height(of: field, at: .large)
        let atAccessibility = Self.height(of: field, at: .accessibility5)

        #expect(atDefault > 0, "the control measured zero at .large")
        #expect(atAccessibility > atDefault, "AX5: \(atAccessibility), large: \(atDefault)")
    }

    // MARK: - InlineErrorBanner

    @Test("The error banner grows with the text size")
    func errorBannerGrowsWithTheTextSize() {
        let banner = InlineErrorBanner("Incorrect email or password.")
        let atDefault = Self.height(of: banner, at: .large)
        let atAccessibility = Self.height(of: banner, at: .accessibility5)

        #expect(atDefault > 0, "the control measured zero at .large")
        #expect(atAccessibility > atDefault, "AX5: \(atAccessibility), large: \(atDefault)")
    }
}
