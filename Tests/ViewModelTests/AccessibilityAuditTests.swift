import SwiftUI
import Testing
@testable import Core
@testable import Features

// MARK: - Labels and traits

/// Phase 10 item 6, the half about what the controls *say*.
///
/// Every assertion here is read off the tree UIKit publishes rather than off
/// the source, because the two disagree in both directions and the source is
/// the one that looks right. A `.accessibilityLabel` applied to a container
/// with two children may be overridden by the children; a `Button` whose label
/// branch holds no text is a control with no name at all; a `.contentShape` and
/// an `.onTapGesture` look exactly like a button in a diff and publish nothing.
/// None of those is visible without asking what came out the other end, which
/// is what ``AccessibilityTree`` does.
///
/// The suite is `.serialized` for the reason every hosted suite in this bundle
/// is: each test stands up a `UIWindow`, and windows in the same process
/// compete for key-window status.
@Suite("What the shipped controls publish to VoiceOver", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct AccessibilityAuditTests {

    // MARK: - AppButton

    @Test("An idle button is one element carrying its label and the button trait")
    func idleButtonPublishesItsLabel() async throws {
        let published = await publishedElements(of: AppButton("Sign In") {})

        let button = try #require(published.first(where: { $0.isButton }), "published: \(published)")
        #expect(button.label == "Sign In")
        #expect(button.value.isEmpty)
        #expect(!button.isDisabled)
    }

    /// The failure this closes. While a request is in flight the button's
    /// visible content is a spinner, and a spinner is a picture: to somebody
    /// watching it, the button is plainly busy; to VoiceOver it was the same
    /// "Sign In, button" it had been a moment earlier, because the label was
    /// inferred from a `Text` that was still in the tree at zero opacity. The
    /// second press is the duplicate request.
    @Test("A button in flight keeps its name and says so as its value")
    func loadingButtonAnnouncesThatItIsBusy() async throws {
        let published = await publishedElements(of: AppButton("Sign In", isLoading: true) {})

        let button = try #require(published.first(where: { $0.isButton }), "published: \(published)")
        #expect(button.label == "Sign In")
        #expect(button.value == "Loading")
    }

    /// The spinner is hidden rather than left to be combined, so the button
    /// stays a single stop. Two elements here would mean a reader swiping past
    /// a nameless one to reach the control.
    @Test("The spinner adds no element of its own")
    func loadingButtonPublishesOneElement() async {
        let published = await publishedElements(of: AppButton("Sign In", isLoading: true) {})

        #expect(published.count == 1, "published: \(published)")
    }

    @Test("A disabled button says it is disabled")
    func disabledButtonPublishesTheTrait() async throws {
        let published = await publishedElements(of: AppButton("Sign In", isDisabled: true) {})

        let button = try #require(published.first(where: { $0.isButton }), "published: \(published)")
        #expect(button.isDisabled)
    }

    // MARK: - AppTextField

    /// A `TextField` takes its accessibility label from its placeholder, and
    /// `AppTextField` draws that same string above the field as a caption. Both
    /// were elements, so every field on a form announced its own name twice in
    /// a row — "Email. Email, text field." — which is not a cosmetic complaint:
    /// it doubles the length of every form for the people reading it one
    /// element at a time.
    @Test("A field's caption is not a second announcement of its name")
    func textFieldPublishesItsNameOnce() async {
        let published = await publishedElements(
            of: AppTextField("Email", text: .constant(""))
        )

        let named = published.filter { $0.label == "Email" }
        #expect(named.count == 1, "published: \(published)")
    }

    @Test("A field in error carries the rule as a hint and the message as its own element")
    func textFieldInErrorPublishesBoth() async throws {
        let message = "Please enter a valid email address."
        let published = await publishedElements(
            of: AppTextField("Email", text: .constant("nope"), errorMessage: message)
        )

        let field = try #require(published.first(where: { $0.label == "Email" }), "published: \(published)")
        #expect(field.hint == message)
        #expect(published.contains(where: { $0.label == "Error: \(message)" }), "published: \(published)")
    }

    @Test("A field with nothing wrong with it has no hint")
    func validTextFieldHasNoHint() async throws {
        let published = await publishedElements(
            of: AppTextField("Email", text: .constant("someone@example.com"))
        )

        let field = try #require(published.first(where: { $0.label == "Email" }), "published: \(published)")
        #expect(field.hint.isEmpty)
    }

    // MARK: - InlineErrorBanner

    /// The banner that replaced `LoginView`'s inline `HStack`. What the old one
    /// published was an icon and a sentence, with the dismissal — an
    /// `.onTapGesture` on the container — appearing nowhere at all.
    @Test("The error banner is one stop that names itself as an error")
    func errorBannerIsOneElement() async throws {
        let published = await publishedElements(
            of: InlineErrorBanner("Incorrect email or password.") {}
        )

        #expect(published.count == 1, "published: \(published)")
        let banner = try #require(published.first, "published: \(published)")
        #expect(banner.label == "Error: Incorrect email or password.")
        #expect(!banner.isButton)
    }

    // MARK: - AppearanceOptionRow

    /// Three rows, a checkmark on one of them, and — before this item — no way
    /// for VoiceOver to tell them apart or to choose between them: the tap
    /// gesture published no trait and no activation point, and the current
    /// choice was drawn rather than said.
    @Test("The selected appearance row says it is selected, and is a button")
    func selectedAppearanceRowPublishesBothTraits() async throws {
        let published = await publishedElements(
            of: AppearanceOptionRow(scheme: .dark, isSelected: true) {}
        )

        let row = try #require(published.first(where: { $0.label == "Dark" }), "published: \(published)")
        #expect(row.isButton)
        #expect(row.isSelected)
    }

    @Test("An unselected appearance row is a button and is not selected")
    func unselectedAppearanceRowIsNotSelected() async throws {
        let published = await publishedElements(
            of: AppearanceOptionRow(scheme: .light, isSelected: false) {}
        )

        let row = try #require(published.first(where: { $0.label == "Light" }), "published: \(published)")
        #expect(row.isButton)
        #expect(!row.isSelected)
    }

    /// The checkmark draws what `.isSelected` says. Publishing both would make
    /// the row announce its state twice, once as a trait and once as a glyph
    /// named after its asset.
    @Test("The checkmark adds no element of its own")
    func selectedAppearanceRowIsOneElement() async {
        let published = await publishedElements(
            of: AppearanceOptionRow(scheme: .dark, isSelected: true) {}
        )

        #expect(published.count == 1, "published: \(published)")
    }

    // MARK: - TagChip

    @Test("A chip with an action is a button, and says when it is selected")
    func selectedChipPublishesBothTraits() async throws {
        let published = await publishedElements(of: TagChip("Swift", isSelected: true) {})

        let chip = try #require(published.first(where: { $0.label == "Swift" }), "published: \(published)")
        #expect(chip.isButton)
        #expect(chip.isSelected)
    }

    /// The other half of ``TagChip``'s documented contract: a chip with no
    /// action is a label rather than a disabled control, so VoiceOver must not
    /// offer to activate it.
    @Test("A chip with no action is not a button")
    func plainChipIsNotAButton() async {
        let published = await publishedElements(of: TagChip("Swift"))

        #expect(!published.contains(where: { $0.isButton }), "published: \(published)")
    }

    // MARK: - BiometricAuthButton

    @Test("The biometric button is named after the modality, not its glyph")
    func biometricButtonPublishesItsLabel() async throws {
        let service = MockBiometricAuthService()
        service.stubbedBiometricType = .faceID
        let viewModel = BiometricAuthViewModel(service: service)

        let published = await publishedElements(of: BiometricAuthButton(viewModel: viewModel))

        let button = try #require(published.first(where: { $0.isButton }), "published: \(published)")
        #expect(button.label == "Sign in with Face ID")
    }

    // MARK: - Headings

    /// The trait that puts a view on VoiceOver's Headings rotor. Without it the
    /// results panel is reachable only by swiping past everything above it,
    /// every time a new pass finishes.
    @Test("The results heading is published as a heading")
    func resultsHeadingIsAHeading() async throws {
        let published = await publishedElements(of: RecognizedTextHeading(blockCount: 3))

        let heading = try #require(published.first, "published: \(published)")
        #expect(heading.label == "3 blocks detected")
        #expect(heading.isHeader)
    }

    @Test("One block is one block")
    func resultsHeadingIsNotPluralAtOne() async throws {
        let published = await publishedElements(of: RecognizedTextHeading(blockCount: 1))

        let heading = try #require(published.first, "published: \(published)")
        #expect(heading.label == "1 block detected")
    }
}

// MARK: - The rotor

/// Phase 10 item 6, the half about *moving*.
///
/// Labels and traits answer "what is this"; a rotor answers "how do I get back
/// to it". The recognized-text panel is where the difference is largest in this
/// package: forty lines off a receipt are one accessibility element when they
/// are one `Text`, which is a single ninety-second announcement with no way to
/// stop part-way, repeat a line, or skip to the total.
@Suite("Moving through recognized text", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct AccessibilityRotorTests {

    @Test("Each recognized block is its own stop")
    func eachBlockIsItsOwnElement() async {
        let result = RecognitionResult.previewReceipt
        let published = await publishedElements(of: RecognizedTextPanel(result: result))

        for block in result.blocks {
            #expect(published.contains(where: { $0.label == block.text }), "published: \(published)")
        }
    }

    @Test("The panel publishes a rotor over the blocks")
    func theRotorIsPublished() async {
        let names = await publishedRotorNames(of: RecognizedTextPanel(result: .previewReceipt))

        #expect(names.contains("Text blocks"), "rotors: \(names)")
    }

    /// A result carrying text but no blocks still renders — see the note on
    /// ``RecognizedTextPanel``. It is one element then, which is the shape the
    /// rotor exists to improve on and is still better than nothing on screen.
    @Test("A result with no blocks falls back to its joined text")
    func resultWithoutBlocksStillRenders() async {
        let result = RecognitionResult(fullText: "Hello World", blocks: [])
        let published = await publishedElements(of: RecognizedTextPanel(result: result))

        #expect(published.contains(where: { $0.label == "Hello World" }), "published: \(published)")
    }
}
