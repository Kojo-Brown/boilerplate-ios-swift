import CoreMedia
import Foundation
import Vision

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

/// Wraps `VNRecognizeTextRequest` in async/await.
///
/// This used to call Google's ML Kit. It cannot: ML Kit for iOS ships no `arm64`
/// slice for the simulator — the mirror that repackages it states plainly that it
/// builds "`arm64` for iphoneos and `x86_64` for iphonesimulator only" — so the
/// test bundle failed to link on every Apple Silicon Mac and every current CI
/// runner. Building the whole package `x86_64` under Rosetta instead links, and
/// then aborts on launch. Neither is a boilerplate anyone can run.
///
/// Vision is the framework this repo already uses for barcode scanning, needs no
/// dependency at all, and performs text recognition on-device. It also reports a
/// per-observation confidence, which ML Kit's iOS API does not vend — so
/// `RecognizedTextBlock.confidence` carries a real value here rather than a
/// placeholder.
///
/// Bounding boxes arrive normalized with a bottom-left origin; `flipBoundingBox`
/// converts them to the top-left origin the SwiftUI overlay draws in, exactly as
/// `LiveBarcodeScannerService` does.
struct LiveTextRecognitionService: TextRecognizing {
    /// `.accurate` trades latency for quality. The frame loop in
    /// `TextRecognitionViewModel` already throttles to ~2 fps, so the extra time
    /// per pass is absorbed there rather than dropping frames.
    var recognitionLevel: VNRequestTextRecognitionLevel = .accurate

    /// Language correction fixes OCR confusions (`rn` → `m`) using a language
    /// model. Turn it off for content that is not prose — serial numbers, codes.
    var usesLanguageCorrection = true

    func recognize(frame: CapturedFrame) async throws -> RecognitionResult {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(frame.buffer) else {
            throw TextRecognitionError.noResult
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(
                        throwing: TextRecognitionError.processingFailed(error.localizedDescription)
                    )
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                continuation.resume(returning: Self.map(observations))
            }
            request.recognitionLevel = recognitionLevel
            request.usesLanguageCorrection = usesLanguageCorrection

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(
                    throwing: TextRecognitionError.processingFailed(error.localizedDescription)
                )
            }
        }
    }

    // MARK: - Private helpers

    private static func map(_ observations: [VNRecognizedTextObservation]) -> RecognitionResult {
        let blocks = observations.compactMap { observation -> RecognizedTextBlock? in
            // `topCandidates(1)` is the highest-confidence reading of this
            // observation. An observation with no candidate at all is a region
            // Vision located but could not read, which is not a block of text.
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedTextBlock(
                text: candidate.string,
                normalizedFrame: Self.flipBoundingBox(observation.boundingBox),
                confidence: candidate.confidence
            )
        }
        return RecognitionResult(
            fullText: blocks.map(\.text).joined(separator: "\n"),
            blocks: blocks
        )
    }

    /// Vision uses a bottom-left origin; flip to top-left for UIKit/SwiftUI overlays.
    private static func flipBoundingBox(_ box: CGRect) -> CGRect {
        CGRect(
            x: box.minX,
            y: 1.0 - box.maxY,
            width: box.width,
            height: box.height
        )
    }
}

// MARK: - Mock implementation

/// Test double that returns a predetermined result without Vision or camera hardware.
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
