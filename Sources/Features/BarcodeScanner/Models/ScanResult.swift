import CoreGraphics
import Foundation

/// The symbology (encoding format) of a detected barcode.
package enum BarcodeSymbology: String, Sendable {
    case qrCode = "QR Code"
    case aztec = "Aztec"
    case code128 = "Code 128"
    case code39 = "Code 39"
    case ean13 = "EAN-13"
    case ean8 = "EAN-8"
    case dataMatrix = "Data Matrix"
    case pdf417 = "PDF417"
    case upce = "UPC-E"
    case itf14 = "ITF-14"
    case unknown = "Unknown"
}

/// A single barcode or QR code detected in one scan frame.
package struct DetectedBarcode: Identifiable, Sendable {
    package let id: UUID
    package let payload: String
    package let symbology: BarcodeSymbology
    /// Bounding box normalized to 0–1 in the preview layer's coordinate space (top-left origin).
    package let normalizedFrame: CGRect

    package init(payload: String, symbology: BarcodeSymbology, normalizedFrame: CGRect) {
        id = UUID()
        self.payload = payload
        self.symbology = symbology
        self.normalizedFrame = normalizedFrame
    }
}

/// The complete output of a single barcode scan pass.
package struct ScanResult: Sendable {
    package let barcodes: [DetectedBarcode]
    package var isEmpty: Bool { barcodes.isEmpty }
    package var primaryBarcode: DetectedBarcode? { barcodes.first }
}
