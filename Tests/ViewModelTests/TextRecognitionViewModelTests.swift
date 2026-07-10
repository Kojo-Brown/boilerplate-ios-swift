import CoreGraphics
import Testing
@testable import BoilerplateiOSSwift

// MARK: - Tests

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
        let a = RecognizedTextBlock(text: "A", normalizedFrame: .zero)
        let b = RecognizedTextBlock(text: "B", normalizedFrame: .zero)
        #expect(a.id != b.id)
    }

    @Test func recognizedTextBlockDefaultConfidenceIsOne() {
        let block = RecognizedTextBlock(text: "Test", normalizedFrame: .zero)
        #expect(block.confidence == 1.0)
    }

    @Test func recognizedTextBlockStoresText() {
        let block = RecognizedTextBlock(text: "Hello MLKit", normalizedFrame: .zero, confidence: 0.95)
        #expect(block.text == "Hello MLKit")
        #expect(block.confidence == 0.95)
    }

    // MARK: - TextRecognitionError

    @Test func textRecognitionErrorHasLocalizedDescriptions() {
        #expect(TextRecognitionError.noResult.errorDescription != nil)
        #expect(TextRecognitionError.processingFailed("reason").errorDescription?.contains("reason") == true)
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
