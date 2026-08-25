import CoreGraphics
import Foundation

/// A single block of text recognized by Vision, with its bounding box in image coordinates.
package struct RecognizedTextBlock: Identifiable, Sendable {
    package let id: UUID
    package let text: String
    /// Bounding box in the coordinate space of the preview layer (normalized 0–1 on each axis).
    package let normalizedFrame: CGRect
    package let confidence: Float

    package init(text: String, normalizedFrame: CGRect, confidence: Float = 1.0) {
        id = UUID()
        self.text = text
        self.normalizedFrame = normalizedFrame
        self.confidence = confidence
    }
}

/// The full output of a single text recognition pass.
package struct RecognitionResult: Sendable {
    package let fullText: String
    package let blocks: [RecognizedTextBlock]

    package var isEmpty: Bool { fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
