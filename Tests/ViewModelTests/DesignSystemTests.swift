import SwiftUI
import Testing
@testable import BoilerplateiOSSwift

// MARK: - AppButton Tests

@MainActor
struct AppButtonTests {
    // MARK: - Style enum

    @Test func allStyleCasesAreDistinct() {
        let styles: [AppButtonStyle] = [.primary, .secondary, .destructive]
        #expect(styles.count == 3)
    }

    // MARK: - Instantiation

    @Test func defaultStyleIsPrimary() {
        var capturedAction = false
        let sut = AppButton("Tap me") { capturedAction = true }
        #expect(sut.label == "Tap me")
        #expect(sut.style == .primary)
        #expect(!sut.isLoading)
        #expect(!sut.isDisabled)
        _ = capturedAction // silence warning
    }

    @Test func primaryButtonInstantiates() {
        let sut = AppButton("Submit", style: .primary) {}
        #expect(sut.style == .primary)
    }

    @Test func secondaryButtonInstantiates() {
        let sut = AppButton("Cancel", style: .secondary) {}
        #expect(sut.style == .secondary)
    }

    @Test func destructiveButtonInstantiates() {
        let sut = AppButton("Delete", style: .destructive) {}
        #expect(sut.style == .destructive)
    }

    @Test func loadingFlagIsPreserved() {
        let sut = AppButton("Loading", isLoading: true) {}
        #expect(sut.isLoading)
    }

    @Test func disabledFlagIsPreserved() {
        let sut = AppButton("Disabled", isDisabled: true) {}
        #expect(sut.isDisabled)
    }

    // MARK: - Async convenience initialiser

    @Test func asyncInitialisesWithCorrectLabel() {
        let sut = AppButton("Sign In", asyncAction: {})
        #expect(sut.label == "Sign In")
        #expect(sut.style == .primary)
    }

    @Test func asyncInitialisesWithCustomStyle() {
        let sut = AppButton("Confirm", style: .destructive, asyncAction: {})
        #expect(sut.style == .destructive)
    }

    @Test func asyncLoadingFlagIsPreserved() {
        let sut = AppButton("Working", isLoading: true, asyncAction: {})
        #expect(sut.isLoading)
    }

    // MARK: - Body renders without crash

    @Test func bodyRendersForPrimary() {
        let sut = AppButton("Test", style: .primary) {}
        _ = sut.body
    }

    @Test func bodyRendersForSecondary() {
        let sut = AppButton("Test", style: .secondary) {}
        _ = sut.body
    }

    @Test func bodyRendersForDestructive() {
        let sut = AppButton("Test", style: .destructive) {}
        _ = sut.body
    }

    @Test func bodyRendersWhileLoading() {
        let sut = AppButton("Test", isLoading: true) {}
        _ = sut.body
    }

    @Test func bodyRendersWhileDisabled() {
        let sut = AppButton("Test", isDisabled: true) {}
        _ = sut.body
    }
}

// MARK: - AppTextField Tests

@MainActor
struct AppTextFieldTests {
    // MARK: - Instantiation

    @Test func defaultConfigurationIsPlainText() {
        let binding = Binding.constant("")
        let sut = AppTextField("Username", text: binding)
        #expect(sut.label == "Username")
        #expect(!sut.isSecure)
        #expect(sut.errorMessage == nil)
    }

    @Test func secureFieldFlagIsPreserved() {
        let binding = Binding.constant("")
        let sut = AppTextField("Password", text: binding, isSecure: true)
        #expect(sut.isSecure)
    }

    @Test func errorMessageIsPreserved() {
        let binding = Binding.constant("bad@")
        let sut = AppTextField(
            "Email",
            text: binding,
            errorMessage: "Invalid email address."
        )
        #expect(sut.errorMessage == "Invalid email address.")
    }

    @Test func nilErrorMessageMeansNoError() {
        let binding = Binding.constant("user@example.com")
        let sut = AppTextField("Email", text: binding, errorMessage: nil)
        #expect(sut.errorMessage == nil)
    }

    // MARK: - Body renders without crash

    @Test func bodyRendersPlainField() {
        let binding = Binding.constant("hello")
        let sut = AppTextField("Name", text: binding)
        _ = sut.body
    }

    @Test func bodyRendersSecureField() {
        let binding = Binding.constant("secret")
        let sut = AppTextField("Password", text: binding, isSecure: true)
        _ = sut.body
    }

    @Test func bodyRendersWithError() {
        let binding = Binding.constant("")
        let sut = AppTextField("Email", text: binding, errorMessage: "Required")
        _ = sut.body
    }
}

// MARK: - LoadingView Tests

@MainActor
struct LoadingViewTests {
    // MARK: - Instantiation

    @Test func defaultHasNoMessage() {
        let sut = LoadingView()
        #expect(sut.message == nil)
    }

    @Test func messageIsPreserved() {
        let sut = LoadingView(message: "Saving…")
        #expect(sut.message == "Saving…")
    }

    @Test func emptyStringMessageIsPreserved() {
        let sut = LoadingView(message: "")
        #expect(sut.message == "")
    }

    // MARK: - Inline variant

    @Test func inlineLoadingViewHasNoDefaultMessage() {
        let sut = InlineLoadingView()
        #expect(sut.message == nil)
    }

    @Test func inlineLoadingViewPreservesMessage() {
        let sut = InlineLoadingView(message: "Loading items…")
        #expect(sut.message == "Loading items…")
    }

    // MARK: - Body renders without crash

    @Test func overlayBodyRendersWithoutMessage() {
        _ = LoadingView().body
    }

    @Test func overlayBodyRendersWithMessage() {
        _ = LoadingView(message: "Please wait…").body
    }

    @Test func inlineBodyRenders() {
        _ = InlineLoadingView(message: "Fetching data…").body
    }
}
