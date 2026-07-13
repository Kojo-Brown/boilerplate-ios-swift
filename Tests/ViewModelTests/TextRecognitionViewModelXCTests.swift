import CoreGraphics
import XCTest
@testable import BoilerplateiOSSwift

/// XCTest suite for `TextRecognitionViewModel` with `@MainActor` isolation.
///
/// `MockTextRecognitionService` is injected so tests do not require MLKit or camera
/// hardware. Methods exercising the full camera + MLKit pipeline belong in
/// integration tests; this suite verifies observable state-machine transitions.
@MainActor
final class TextRecognitionViewModelXCTests: XCTestCase {

    // MARK: - Helpers

    private func makeViewModel(
        recognitionResult: RecognitionResult = RecognitionResult(fullText: "", blocks: []),
        recognitionError: Error? = nil
    ) -> TextRecognitionViewModel {
        var mock = MockTextRecognitionService()
        mock.stubbedResult = recognitionResult
        mock.stubbedError = recognitionError
        return TextRecognitionViewModel(
            cameraService: CameraService(),
            recognitionService: mock
        )
    }

    // MARK: - Initial state

    func testInitialIsScanningIsFalse() {
        let sut = makeViewModel()
        XCTAssertFalse(sut.isScanning)
    }

    func testInitialRecognitionResultIsNil() {
        let sut = makeViewModel()
        XCTAssertNil(sut.recognitionResult)
    }

    func testInitialErrorMessageIsNil() {
        let sut = makeViewModel()
        XCTAssertNil(sut.errorMessage)
    }

    func testInitialPermissionDeniedIsFalse() {
        let sut = makeViewModel()
        XCTAssertFalse(sut.permissionDenied)
    }

    func testInitialDidCopyToClipboardIsFalse() {
        let sut = makeViewModel()
        XCTAssertFalse(sut.didCopyToClipboard)
    }

    // MARK: - stop()

    func testStopSetsIsScanningFalse() {
        let sut = makeViewModel()
        sut.stop()
        XCTAssertFalse(sut.isScanning)
    }

    func testStopIsIdempotent() {
        let sut = makeViewModel()
        sut.stop()
        sut.stop()
        XCTAssertFalse(sut.isScanning)
    }

    // MARK: - clearResult()

    func testClearResultNilsRecognitionResult() {
        let sut = makeViewModel()
        sut.clearResult()
        XCTAssertNil(sut.recognitionResult)
    }

    // MARK: - copyToClipboard()

    func testCopyToClipboardDoesNothingWhenNoResult() {
        let sut = makeViewModel()
        sut.copyToClipboard()
        XCTAssertFalse(sut.didCopyToClipboard)
    }

    // MARK: - RecognitionResult model

    func testRecognitionResultIsEmptyWhenTextIsWhitespace() {
        let result = RecognitionResult(fullText: "   ", blocks: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testRecognitionResultIsEmptyWhenTextIsEmptyString() {
        let result = RecognitionResult(fullText: "", blocks: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testRecognitionResultIsNotEmptyWithText() {
        let result = RecognitionResult(fullText: "Hello", blocks: [])
        XCTAssertFalse(result.isEmpty)
    }

    func testRecognitionResultBlockCountMatchesInput() {
        let blocks = [
            RecognizedTextBlock(text: "Line 1", normalizedFrame: CGRect(x: 0, y: 0, width: 0.5, height: 0.1)),
            RecognizedTextBlock(text: "Line 2", normalizedFrame: CGRect(x: 0, y: 0.2, width: 0.6, height: 0.1)),
        ]
        let result = RecognitionResult(fullText: "Line 1\nLine 2", blocks: blocks)
        XCTAssertEqual(result.blocks.count, 2)
    }

    func testRecognitionResultStoresFullText() {
        let result = RecognitionResult(fullText: "Sample text", blocks: [])
        XCTAssertEqual(result.fullText, "Sample text")
    }

    // MARK: - RecognizedTextBlock model

    func testRecognizedTextBlockHasUniqueIDs() {
        let a = RecognizedTextBlock(text: "A", normalizedFrame: .zero)
        let b = RecognizedTextBlock(text: "B", normalizedFrame: .zero)
        XCTAssertNotEqual(a.id, b.id)
    }

    func testRecognizedTextBlockDefaultConfidenceIsOne() {
        let block = RecognizedTextBlock(text: "Test", normalizedFrame: .zero)
        XCTAssertEqual(block.confidence, 1.0, accuracy: 0.001)
    }

    func testRecognizedTextBlockStoresText() {
        let block = RecognizedTextBlock(text: "Hello MLKit", normalizedFrame: .zero)
        XCTAssertEqual(block.text, "Hello MLKit")
    }

    func testRecognizedTextBlockStoresCustomConfidence() {
        let block = RecognizedTextBlock(text: "Test", normalizedFrame: .zero, confidence: 0.95)
        XCTAssertEqual(block.confidence, 0.95, accuracy: 0.001)
    }

    func testRecognizedTextBlockStoresNormalizedFrame() {
        let frame = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.08)
        let block = RecognizedTextBlock(text: "Text", normalizedFrame: frame)
        XCTAssertEqual(block.normalizedFrame, frame)
    }

    // MARK: - TextRecognitionError

    func testNoResultErrorDescriptionIsNonNil() {
        XCTAssertNotNil(TextRecognitionError.noResult.errorDescription)
    }

    func testProcessingFailedDescriptionContainsReason() {
        let error = TextRecognitionError.processingFailed("network timeout")
        XCTAssertTrue(error.errorDescription?.contains("network timeout") == true)
    }

    func testProcessingFailedDescriptionIsNonEmpty() {
        let error = TextRecognitionError.processingFailed("any reason")
        XCTAssertFalse(error.errorDescription?.isEmpty == true)
    }

    // MARK: - CameraError

    func testCameraNotAuthorizedDescriptionIsNonNil() {
        XCTAssertNotNil(CameraError.notAuthorized.errorDescription)
    }

    func testCameraDeviceUnavailableDescriptionIsNonNil() {
        XCTAssertNotNil(CameraError.deviceUnavailable.errorDescription)
    }

    func testCameraConfigurationFailedDescriptionIsNonNil() {
        XCTAssertNotNil(CameraError.configurationFailed.errorDescription)
    }
}
