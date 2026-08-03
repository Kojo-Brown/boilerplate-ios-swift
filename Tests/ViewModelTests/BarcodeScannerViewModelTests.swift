import CoreGraphics
import Testing
@testable import BoilerplateiOSSwift

// MARK: - BarcodeScannerViewModel Tests

@MainActor
struct BarcodeScannerViewModelTests {
    // MARK: - Initial state

    @Test func initialStateIsNotScanning() {
        let sut = makeViewModel()
        #expect(!sut.isScanning)
        #expect(sut.scanResult == nil)
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

    @Test func clearResultNilsOutScanResult() {
        let sut = makeViewModel()
        sut.clearResult()
        #expect(sut.scanResult == nil)
    }

    // MARK: - copyPayload

    @Test func copyPayloadDoesNothingWhenNoResult() {
        let sut = makeViewModel()
        sut.copyPayload()
        #expect(!sut.didCopyToClipboard)
    }

    // MARK: - ScanResult model

    @Test func scanResultIsEmptyWhenNoBarcodes() {
        let result = ScanResult(barcodes: [])
        #expect(result.isEmpty)
    }

    @Test func scanResultIsNotEmptyWithBarcodes() {
        let result = ScanResult(barcodes: [
            DetectedBarcode(payload: "hello", symbology: .qrCode, normalizedFrame: .zero),
        ])
        #expect(!result.isEmpty)
    }

    @Test func scanResultPrimaryBarcodeIsFirstElement() {
        let first = DetectedBarcode(payload: "first", symbology: .qrCode, normalizedFrame: .zero)
        let second = DetectedBarcode(payload: "second", symbology: .code128, normalizedFrame: .zero)
        let result = ScanResult(barcodes: [first, second])
        #expect(result.primaryBarcode?.payload == "first")
    }

    @Test func scanResultPrimaryBarcodeIsNilWhenEmpty() {
        let result = ScanResult(barcodes: [])
        #expect(result.primaryBarcode == nil)
    }

    // MARK: - DetectedBarcode model

    @Test func detectedBarcodeHasUniqueIDs() {
        let first = DetectedBarcode(payload: "A", symbology: .qrCode, normalizedFrame: .zero)
        let second = DetectedBarcode(payload: "B", symbology: .qrCode, normalizedFrame: .zero)
        #expect(first.id != second.id)
    }

    @Test func detectedBarcodeStoresAllProperties() {
        let frame = CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.3)
        let barcode = DetectedBarcode(payload: "12345", symbology: .ean13, normalizedFrame: frame)
        #expect(barcode.payload == "12345")
        #expect(barcode.symbology == .ean13)
        #expect(barcode.normalizedFrame == frame)
    }

    // MARK: - BarcodeSymbology

    @Test func barcodeSymbologyRawValuesAreHumanReadable() {
        #expect(BarcodeSymbology.qrCode.rawValue == "QR Code")
        #expect(BarcodeSymbology.ean13.rawValue == "EAN-13")
        #expect(BarcodeSymbology.code128.rawValue == "Code 128")
        #expect(BarcodeSymbology.unknown.rawValue == "Unknown")
    }

    // MARK: - BarcodeScanError

    @Test func barcodeScanErrorHasLocalizedDescription() {
        let error = BarcodeScanError.processingFailed("network timeout")
        #expect(error.errorDescription?.contains("network timeout") == true)
    }

    // MARK: - Helpers

    private func makeViewModel() -> BarcodeScannerViewModel {
        BarcodeScannerViewModel(
            cameraService: CameraService(),
            scannerService: MockBarcodeScannerService()
        )
    }
}
