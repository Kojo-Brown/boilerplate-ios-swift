import CoreMedia
import Foundation
import Vision

// MARK: - Error

enum BarcodeScanError: Error, LocalizedError {
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .processingFailed(let reason): return "Scan failed: \(reason)"
        }
    }
}

// MARK: - Protocol

/// Abstracts the barcode recognizer so tests can inject a predictable mock.
protocol BarcodeScanning: Sendable {
    func scan(sampleBuffer: CMSampleBuffer) async throws -> ScanResult
}

// MARK: - Live implementation

/// Wraps `VNDetectBarcodesRequest` in async/await.
///
/// Vision's bounding boxes are in a coordinate space with the origin at the bottom-left.
/// `normalizedFrame` flips the Y-axis so overlays can be applied directly to the
/// UIKit/SwiftUI preview layer, which uses a top-left origin.
final class LiveBarcodeScannerService: BarcodeScanning {
    private let supportedSymbologies: [VNBarcodeSymbology] = [
        .qr, .aztec, .code128, .code39, .code39Checksum, .code39FullASCII,
        .code93, .code93i, .dataMatrix, .ean13, .ean8,
        .i2of5, .itf14, .microQR, .pdf417, .upce,
    ]

    func scan(sampleBuffer: CMSampleBuffer) async throws -> ScanResult {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return ScanResult(barcodes: [])
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNDetectBarcodesRequest { request, error in
                if let error {
                    continuation.resume(throwing: BarcodeScanError.processingFailed(error.localizedDescription))
                    return
                }
                let observations = request.results as? [VNBarcodeObservation] ?? []
                let barcodes = observations.compactMap { obs -> DetectedBarcode? in
                    guard let payload = obs.payloadStringValue else { return nil }
                    return DetectedBarcode(
                        payload: payload,
                        symbology: Self.mapSymbology(obs.symbology),
                        normalizedFrame: Self.flipBoundingBox(obs.boundingBox)
                    )
                }
                continuation.resume(returning: ScanResult(barcodes: barcodes))
            }
            request.symbologies = supportedSymbologies

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: BarcodeScanError.processingFailed(error.localizedDescription))
            }
        }
    }

    // MARK: - Helpers

    /// Vision uses bottom-left origin; flip to top-left for UIKit/SwiftUI overlays.
    private static func flipBoundingBox(_ box: CGRect) -> CGRect {
        CGRect(
            x: box.minX,
            y: 1.0 - box.maxY,
            width: box.width,
            height: box.height
        )
    }

    private static func mapSymbology(_ symbology: VNBarcodeSymbology) -> BarcodeSymbology {
        switch symbology {
        case .qr: return .qr
        case .aztec: return .aztec
        case .code128: return .code128
        case .code39, .code39Checksum, .code39FullASCII: return .code39
        case .ean13: return .ean13
        case .ean8: return .ean8
        case .dataMatrix: return .dataMatrix
        case .pdf417: return .pdf417
        case .upce: return .upce
        case .itf14: return .itf14
        default: return .unknown
        }
    }
}

// MARK: - Mock implementation

/// Test double that returns a predetermined result without Vision or camera hardware.
struct MockBarcodeScannerService: BarcodeScanning {
    var stubbedResult: ScanResult = ScanResult(barcodes: [
        DetectedBarcode(
            payload: "https://example.com",
            symbology: .qr,
            normalizedFrame: CGRect(x: 0.2, y: 0.25, width: 0.6, height: 0.5)
        ),
    ])
    var stubbedError: Error?

    func scan(sampleBuffer _: CMSampleBuffer) async throws -> ScanResult {
        try await Task.sleep(for: .milliseconds(50))
        if let error = stubbedError { throw error }
        return stubbedResult
    }
}
