import AVFoundation
import Core
import Foundation
import Observation
import UIKit

/// Drives the text recognition screen: manages camera lifecycle, recognition throttling,
/// and surfaces results for the overlay UI.
///
/// Inject `recognitionService` in tests to avoid camera hardware and Vision.
@Observable
@MainActor
package final class TextRecognitionViewModel: ViewModelProtocol {
    // MARK: - Published state

    private(set) var recognitionResult: RecognitionResult?
    private(set) var isScanning = false
    private(set) var errorMessage: String?
    private(set) var permissionDenied = false
    private(set) var didCopyToClipboard = false

    // MARK: - Dependencies

    private let cameraService: CameraService
    private let recognitionService: any TextRecognizing

    // MARK: - Private

    private var frameProcessingTask: Task<Void, Never>?

    package var previewLayer: AVCaptureVideoPreviewLayer {
        cameraService.previewLayer
    }

    // MARK: - Init

    /// Built by `AppContainer.makeTextRecognitionViewModel()`. The camera
    /// service arrives from the container's factory rather than from a default
    /// here, so two screens cannot silently end up sharing — or silently not
    /// sharing — one `AVCaptureSession`.
    package init(
        cameraService: CameraService,
        recognitionService: any TextRecognizing
    ) {
        self.cameraService = cameraService
        self.recognitionService = recognitionService
    }

    // MARK: - ViewModelProtocol

    package func onAppear() async {
        await requestPermissionAndStart()
    }

    package func onDisappear() {
        stop()
    }

    // MARK: - Public actions

    package func requestPermissionAndStart() async {
        let granted = await cameraService.requestPermission()
        guard granted else {
            permissionDenied = true
            errorMessage = CameraError.notAuthorized.localizedDescription
            return
        }
        await startScanning()
    }

    package func startScanning() async {
        guard !isScanning else { return }
        errorMessage = nil
        do {
            try await cameraService.start()
            isScanning = true
            beginProcessingFrames()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    package func stop() {
        frameProcessingTask?.cancel()
        frameProcessingTask = nil
        cameraService.stop()
        isScanning = false
    }

    package func clearResult() {
        recognitionResult = nil
    }

    package func copyToClipboard() {
        guard let text = recognitionResult?.fullText, !text.isEmpty else { return }
        UIPasteboard.general.string = text
        didCopyToClipboard = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopyToClipboard = false
        }
    }

    // MARK: - Private frame loop

    /// Consumes the camera frame stream and throttles recognition to ~2 fps to stay
    /// within the recognizer's throughput without overwhelming the main actor.
    private func beginProcessingFrames() {
        frameProcessingTask?.cancel()
        let stream = cameraService.makeFrameStream()
        let service = recognitionService

        frameProcessingTask = Task { [weak self] in
            var lastRecognizedAt: ContinuousClock.Instant?

            for await frame in stream {
                guard !Task.isCancelled else { break }

                let now = ContinuousClock.now
                if let last = lastRecognizedAt, (now - last) < .seconds(0.5) { continue }
                lastRecognizedAt = now

                do {
                    let result = try await service.recognize(frame: frame)
                    guard !Task.isCancelled else { break }
                    if !result.isEmpty {
                        self?.recognitionResult = result
                    }
                } catch is CancellationError {
                    break
                } catch {
                    // Per-frame failures are transient; surface only persistent camera errors
                }
            }
        }
    }
}
