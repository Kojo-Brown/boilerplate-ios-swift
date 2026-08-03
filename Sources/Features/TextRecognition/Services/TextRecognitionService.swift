import CoreMedia
import Foundation
import MLKitTextRecognition
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
    func recognize(frame: CapturedFrame) async throws -> RecognitionResult
}

// MARK: - Live implementation

/// Wraps `MLKitTextRecognition`'s callback API in async/await.
///
/// `TextRecognizer` is thread-safe; one instance is created at init and reused.
/// Block frames from the image are normalized to 0–1 before storage so the UI
/// can overlay them on any preview layer size without knowing the original resolution.
///
/// `@unchecked Sendable` is needed because `MLKTextRecognizer` is an Objective-C
/// class that predates Swift concurrency and carries no `Sendable` annotation, so
/// holding one in a `Sendable` type is an error. The narrow opt-out is deliberate:
/// `@preconcurrency import MLKitTextRecognition` — which the compiler suggests —
/// would downgrade *every* Sendable error from the whole ML Kit module to a
/// warning, including ones worth hearing about. What is being asserted here is
/// only that Google documents `MLKTextRecognizer` as safe to call from any
/// thread, and that the single instance is immutable after `init`.
final class LiveTextRecognitionService: TextRecognizing, @unchecked Sendable {
    private let recognizer: TextRecognizer

    init() {
        recognizer = TextRecognizer.textRecognizer(options: TextRecognizerOptions())
    }

    func recognize(frame: CapturedFrame) async throws -> RecognitionResult {
        let sampleBuffer = frame.buffer
        let visionImage = VisionImage(buffer: sampleBuffer)
        visionImage.orientation = Self.imageOrientation(from: sampleBuffer)

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
            // ML Kit for iOS vends no per-element confidence: `MLKTextElement` has
            // `text`, `frame`, `cornerPoints` and `recognizedLanguages` and nothing
            // else, unlike the Android API this line was written against. Blocks
            // take `RecognizedTextBlock`'s default rather than an invented number.
            return RecognizedTextBlock(text: block.text, normalizedFrame: normalized)
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

    private static func imageOrientation(from _: CMSampleBuffer) -> UIImage.Orientation {
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
    var stubbedError: (any Error & Sendable)?

    func recognize(frame _: CapturedFrame) async throws -> RecognitionResult {
        try await Task.sleep(for: .milliseconds(50))
        if let error = stubbedError { throw error }
        return stubbedResult
    }
}
