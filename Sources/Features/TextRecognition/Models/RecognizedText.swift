import CoreGraphics
import Foundation

/// A single block of text recognized by MLKit, with its bounding box in image coordinates.
struct RecognizedTextBlock: Identifiable, Sendable {
    let id: UUID
    let text: String
    /// Bounding box in the coordinate space of the preview layer (normalized 0–1 on each axis).
    let normalizedFrame: CGRect
    let confidence: Float

    init(text: String, normalizedFrame: CGRect, confidence: Float = 1.0) {
        id = UUID()
        self.text = text
        self.normalizedFrame = normalizedFrame
        self.confidence = confidence
    }
}

/// The full output of a single text recognition pass.
struct RecognitionResult: Sendable {
    let fullText: String
    let blocks: [RecognizedTextBlock]

    var isEmpty: Bool { fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
