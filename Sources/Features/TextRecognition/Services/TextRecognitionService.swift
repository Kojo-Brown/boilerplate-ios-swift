import CoreMedia
import Foundation
import MLKitTextRecognitionV2
import MLKitVision
import UIKit

// MARK: - Errors

enum TextRecognitionError: Error, LocalizedError {
    case noResult
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noResult: return "No text found in the image."
        case .processingFailed(let reason): return "Recognition failed: \(reason)"
        }
    }
}

// MARK: - Protocol

/// Abstracts the text recognizer so tests can inject a predictable mock.
protocol TextRecognizing: Sendable {
    func recognize(sampleBuffer: CMSampleBuffer) async throws -> RecognitionResult
}

// MARK: - Live implementation

/// Wraps `MLKitTextRecognitionV2`'s callback API in async/await.
///
/// `TextRecognizer` is thread-safe; one instance is created at init and reused.
/// Block frames from the image are normalized to 0–1 before storage so the UI
/// can overlay them on any preview layer size without knowing the original resolution.
final class LiveTextRecognitionService: TextRecognizing {
    private let recognizer: TextRecognizer

    init() {
        recognizer = TextRecognizer.textRecognizer(options: TextRecognizerOptions())
    }

    func recognize(sampleBuffer: CMSampleBuffer) async throws -> RecognitionResult {
        let visionImage = VisionImage(buffer: sampleBuffer)
        visionImage.orientation = imageOrientation(from: sampleBuffer)

        return try await withCheckedThrowingContinuation { continuation in
            recognizer.process(visionImage) { text, error in
                if let error {
                    continuation.resume(throwing: TextRecognitionError.processingFailed(error.localizedDescription))
                    return
                }
                guard let text else {
                    continuation.resume(throwing: TextRecognitionError.noResult)
                    return
                }
                continuation.resume(returning: Self.map(text, buffer: sampleBuffer))
            }
        }
    }

    // MARK: - Private helpers

    private static func map(_ text: Text, buffer: CMSampleBuffer) -> RecognitionResult {
        let imageSize = imageSize(from: buffer)
        let blocks = text.blocks.map { block -> RecognizedTextBlock in
            let normalized = normalize(rect: block.frame, imageSize: imageSize)
            let confidence = block.lines.first?.elements.first?.confidence ?? 1.0
            return RecognizedTextBlock(text: block.text, normalizedFrame: normalized, confidence: confidence)
        }
        return RecognitionResult(fullText: text.text, blocks: blocks)
    }

    private static func normalize(rect: CGRect, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        return CGRect(
            x: rect.minX / imageSize.width,
            y: rect.minY / imageSize.height,
            width: rect.width / imageSize.width,
            height: rect.height / imageSize.height
        )
    }

    private static func imageSize(from buffer: CMSampleBuffer) -> CGSize {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(buffer) else { return .zero }
        return CGSize(
            width: CVPixelBufferGetWidth(imageBuffer),
            height: CVPixelBufferGetHeight(imageBuffer)
        )
    }

    private func imageOrientation(from buffer: CMSampleBuffer) -> UIImage.Orientation {
        // Frames captured in portrait mode on back camera arrive rotated 90°.
        // MLKit expects the orientation hint so it can normalize bounding boxes.
        .right
    }
}

// MARK: - Mock implementation

/// Test double that returns a predetermined result without MLKit or camera hardware.
struct MockTextRecognitionService: TextRecognizing {
    var stubbedResult: RecognitionResult = RecognitionResult(
        fullText: "Hello World",
        blocks: [
            RecognizedTextBlock(
                text: "Hello World",
                normalizedFrame: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.08)
            ),
        ]
    )
    var stubbedError: Error?

    func recognize(sampleBuffer _: CMSampleBuffer) async throws -> RecognitionResult {
        try await Task.sleep(for: .milliseconds(50))
        if let error = stubbedError { throw error }
        return stubbedResult
    }
}
