import CoreGraphics
import Testing
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Features
@testable import Networking

// MARK: - Tests

/// `MockTextRecognitionService` is injected so these run without Vision or
/// camera hardware: what is asserted here is the observable state-machine
/// transitions and the value types a recognition pass is projected into. The
/// full camera + Vision pipeline belongs to an integration test.
///
/// This suite absorbed `TextRecognitionViewModelXCTests`, the XCTest mirror of
/// it. Five of its twenty-five cases asserted something this file did not —
/// `stop()` being idempotent, the empty string as well as whitespace, that
/// `fullText` and `normalizedFrame` survive the initialiser, and that the
/// processing-failure description is non-empty rather than merely non-nil —
/// and the rest were the same assertions in the other dialect, split
/// one-per-case. See `docs/testing.md`.
@MainActor
struct TextRecognitionViewModelTests {
    // MARK: - Initial state

    @Test func initialStateIsNotScanning() {
        let sut = makeViewModel()
        #expect(!sut.isScanning)
        #expect(sut.recognitionResult == nil)
        #expect(sut.errorMessage == nil)
        #expect(!sut.permissionDenied)
        #expect(!sut.didCopyToClipboard)
    }

    // MARK: - Stop

    @Test func stopSetsIsScanningToFalse() {
        let sut = makeViewModel()
        sut.stop()
        #expect(!sut.isScanning)
    }

    /// `stop()` arrives from `onDisappear` as well as from the button, so it
    /// can land twice with no `start()` between.
    @Test func stopIsIdempotent() {
        let sut = makeViewModel()
        sut.stop()
        sut.stop()
        #expect(!sut.isScanning)
    }

    // MARK: - clearResult

    @Test func clearResultRemovesRecognitionResult() {
        let sut = makeViewModel()
        sut.clearResult()
        #expect(sut.recognitionResult == nil)
    }

    // MARK: - copyToClipboard

    @Test func copyToClipboardDoesNothingWhenNoResult() {
        let sut = makeViewModel()
        sut.copyToClipboard()
        #expect(!sut.didCopyToClipboard)
    }

    // MARK: - RecognitionResult model

    @Test func recognitionResultIsEmptyWhenTextIsBlank() {
        let result = RecognitionResult(fullText: "   ", blocks: [])
        #expect(result.isEmpty)
    }

    /// Whitespace and the empty string reach `isEmpty` by different routes —
    /// one is trimmed to nothing, the other is already nothing — so a
    /// `trimmingCharacters` that went missing would still pass the other case.
    @Test func recognitionResultIsEmptyWhenTextIsAnEmptyString() {
        let result = RecognitionResult(fullText: "", blocks: [])
        #expect(result.isEmpty)
    }

    @Test func recognitionResultStoresFullText() {
        let result = RecognitionResult(fullText: "Sample text", blocks: [])
        #expect(result.fullText == "Sample text")
    }

    @Test func recognitionResultIsNotEmptyWithText() {
        let result = RecognitionResult(fullText: "Hello", blocks: [])
        #expect(!result.isEmpty)
    }

    @Test func recognitionResultBlockCountMatchesInput() {
        let blocks = [
            RecognizedTextBlock(text: "Line 1", normalizedFrame: CGRect(x: 0, y: 0, width: 0.5, height: 0.1)),
            RecognizedTextBlock(text: "Line 2", normalizedFrame: CGRect(x: 0, y: 0.2, width: 0.6, height: 0.1)),
        ]
        let result = RecognitionResult(fullText: "Line 1\nLine 2", blocks: blocks)
        #expect(result.blocks.count == 2)
    }

    // MARK: - RecognizedTextBlock model

    @Test func recognizedTextBlockHasUniqueIDs() {
        let first = RecognizedTextBlock(text: "A", normalizedFrame: .zero)
        let second = RecognizedTextBlock(text: "B", normalizedFrame: .zero)
        #expect(first.id != second.id)
    }

    @Test func recognizedTextBlockDefaultConfidenceIsOne() {
        let block = RecognizedTextBlock(text: "Test", normalizedFrame: .zero)
        #expect(block.confidence == 1.0)
    }

    @Test func recognizedTextBlockStoresText() {
        let block = RecognizedTextBlock(text: "Hello Vision", normalizedFrame: .zero, confidence: 0.95)
        #expect(block.text == "Hello Vision")
        #expect(block.confidence == 0.95)
    }

    @Test func recognizedTextBlockStoresNormalizedFrame() {
        let frame = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.08)

        let block = RecognizedTextBlock(text: "Text", normalizedFrame: frame)

        #expect(block.normalizedFrame == frame)
    }

    // MARK: - TextRecognitionError

    @Test func textRecognitionErrorHasLocalizedDescriptions() {
        #expect(TextRecognitionError.noResult.errorDescription != nil)
        #expect(TextRecognitionError.processingFailed("reason").errorDescription?.contains("reason") == true)
    }

    /// `errorDescription?.isEmpty == false` was how the XCTest mirror put
    /// this, and it is a check that cannot fail: a nil description makes the
    /// comparison false too, so the assertion reads as satisfied exactly when
    /// there is no message to show the user. `#require` fails on nil instead.
    @Test func processingFailedDescriptionIsNotEmpty() throws {
        let error = TextRecognitionError.processingFailed("any reason")

        let description = try #require(error.errorDescription)

        #expect(!description.isEmpty)
    }

    // MARK: - CameraError

    @Test func cameraErrorHasLocalizedDescriptions() {
        #expect(CameraError.notAuthorized.errorDescription != nil)
        #expect(CameraError.deviceUnavailable.errorDescription != nil)
        #expect(CameraError.configurationFailed.errorDescription != nil)
    }

    // MARK: - Helpers

    private func makeViewModel() -> TextRecognitionViewModel {
        TextRecognitionViewModel(
            cameraService: CameraService(),
            recognitionService: MockTextRecognitionService()
        )
    }
}
