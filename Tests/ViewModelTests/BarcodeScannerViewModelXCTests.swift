import CoreGraphics
import XCTest
@testable import BoilerplateiOSSwift

/// XCTest suite for `BarcodeScannerViewModel` with `@MainActor` isolation.
///
/// `CameraService` and `MockBarcodeScannerService` are injected so tests run without
/// AVFoundation hardware access. Tests that exercise the full camera + Vision pipeline
/// belong in integration tests; this suite verifies state-machine transitions that
/// are observable without live camera frames.
@MainActor
final class BarcodeScannerViewModelXCTests: XCTestCase {

    // MARK: - Helpers

    private func makeViewModel(
        scannerResult: ScanResult = ScanResult(barcodes: []),
        scannerError: Error? = nil
    ) -> BarcodeScannerViewModel {
        var mock = MockBarcodeScannerService()
        mock.stubbedResult = scannerResult
        mock.stubbedError = scannerError
        return BarcodeScannerViewModel(
            cameraService: CameraService(),
            scannerService: mock
        )
    }

    // MARK: - Initial state

    func testInitialIsScanningIsFalse() {
        let sut = makeViewModel()
        XCTAssertFalse(sut.isScanning)
    }

    func testInitialScanResultIsNil() {
        let sut = makeViewModel()
        XCTAssertNil(sut.scanResult)
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

    func testClearResultNilsScanResult() {
        let sut = makeViewModel()
        sut.clearResult()
        XCTAssertNil(sut.scanResult)
    }

    // MARK: - copyPayload()

    func testCopyPayloadDoesNothingWhenNoResult() {
        let sut = makeViewModel()
        sut.copyPayload()
        XCTAssertFalse(sut.didCopyToClipboard)
    }

    // MARK: - ScanResult model

    func testScanResultIsEmptyWithNoBarcodes() {
        let result = ScanResult(barcodes: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testScanResultIsNotEmptyWithBarcodes() {
        let barcode = DetectedBarcode(payload: "https://example.com", symbology: .qr, normalizedFrame: .zero)
        let result = ScanResult(barcodes: [barcode])
        XCTAssertFalse(result.isEmpty)
    }

    func testScanResultPrimaryBarcodeIsFirstElement() {
        let first = DetectedBarcode(payload: "first", symbology: .qr, normalizedFrame: .zero)
        let second = DetectedBarcode(payload: "second", symbology: .code128, normalizedFrame: .zero)
        let result = ScanResult(barcodes: [first, second])
        XCTAssertEqual(result.primaryBarcode?.payload, "first")
    }

    func testScanResultPrimaryBarcodeIsNilWhenEmpty() {
        let result = ScanResult(barcodes: [])
        XCTAssertNil(result.primaryBarcode)
    }

    // MARK: - DetectedBarcode model

    func testDetectedBarcodeHasUniqueIDs() {
        let a = DetectedBarcode(payload: "A", symbology: .qr, normalizedFrame: .zero)
        let b = DetectedBarcode(payload: "B", symbology: .qr, normalizedFrame: .zero)
        XCTAssertNotEqual(a.id, b.id)
    }

    func testDetectedBarcodeStoresPayload() {
        let barcode = DetectedBarcode(payload: "12345", symbology: .ean13, normalizedFrame: .zero)
        XCTAssertEqual(barcode.payload, "12345")
    }

    func testDetectedBarcodeStoresSymbology() {
        let barcode = DetectedBarcode(payload: "data", symbology: .dataMatrix, normalizedFrame: .zero)
        XCTAssertEqual(barcode.symbology, .dataMatrix)
    }

    func testDetectedBarcodeStoresNormalizedFrame() {
        let frame = CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.3)
        let barcode = DetectedBarcode(payload: "test", symbology: .qr, normalizedFrame: frame)
        XCTAssertEqual(barcode.normalizedFrame, frame)
    }

    // MARK: - BarcodeSymbology raw values

    func testQRCodeRawValue() {
        XCTAssertEqual(BarcodeSymbology.qr.rawValue, "QR Code")
    }

    func testEAN13RawValue() {
        XCTAssertEqual(BarcodeSymbology.ean13.rawValue, "EAN-13")
    }

    func testCode128RawValue() {
        XCTAssertEqual(BarcodeSymbology.code128.rawValue, "Code 128")
    }

    func testUnknownRawValue() {
        XCTAssertEqual(BarcodeSymbology.unknown.rawValue, "Unknown")
    }

    // MARK: - BarcodeScanError

    func testBarcodeScanErrorDescriptionContainsReason() {
        let error = BarcodeScanError.processingFailed("timeout")
        XCTAssertTrue(error.errorDescription?.contains("timeout") == true)
    }

    func testBarcodeScanErrorDescriptionIsNonEmpty() {
        let error = BarcodeScanError.processingFailed("any reason")
        XCTAssertFalse(error.errorDescription?.isEmpty == true)
    }
}
