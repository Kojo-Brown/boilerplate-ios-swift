import CoreGraphics
import Foundation

/// The symbology (encoding format) of a detected barcode.
enum BarcodeSymbology: String, Sendable {
    case qr = "QR Code"
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
struct DetectedBarcode: Identifiable, Sendable {
    let id: UUID
    let payload: String
    let symbology: BarcodeSymbology
    /// Bounding box normalized to 0–1 in the preview layer's coordinate space (top-left origin).
    let normalizedFrame: CGRect

    init(payload: String, symbology: BarcodeSymbology, normalizedFrame: CGRect) {
        id = UUID()
        self.payload = payload
        self.symbology = symbology
        self.normalizedFrame = normalizedFrame
    }
}

/// The complete output of a single barcode scan pass.
struct ScanResult: Sendable {
    let barcodes: [DetectedBarcode]
    var isEmpty: Bool { barcodes.isEmpty }
    var primaryBarcode: DetectedBarcode? { barcodes.first }
}
