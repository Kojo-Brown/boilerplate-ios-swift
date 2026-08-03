import AVFoundation
import Foundation
import Observation
import UIKit

/// Drives the text recognition screen: manages camera lifecycle, recognition throttling,
/// and surfaces results for the overlay UI.
///
/// Inject `recognitionService` in tests to avoid hardware and MLKit dependencies.
@Observable
@MainActor
final class TextRecognitionViewModel: ViewModelProtocol {
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

    var previewLayer: AVCaptureVideoPreviewLayer {
        cameraService.previewLayer
    }

    // MARK: - Init

    init(
        cameraService: CameraService = CameraService(),
        recognitionService: any TextRecognizing = LiveTextRecognitionService()
    ) {
        self.cameraService = cameraService
        self.recognitionService = recognitionService
    }

    // MARK: - ViewModelProtocol

    func onAppear() async {
        await requestPermissionAndStart()
    }

    func onDisappear() {
        stop()
    }

    // MARK: - Public actions

    func requestPermissionAndStart() async {
        let granted = await cameraService.requestPermission()
        guard granted else {
            permissionDenied = true
            errorMessage = CameraError.notAuthorized.localizedDescription
            return
        }
        await startScanning()
    }

    func startScanning() async {
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

    func stop() {
        frameProcessingTask?.cancel()
        frameProcessingTask = nil
        cameraService.stop()
        isScanning = false
    }

    func clearResult() {
        recognitionResult = nil
    }

    func copyToClipboard() {
        guard let text = recognitionResult?.fullText, !text.isEmpty else { return }
        UIPasteboard.general.string = text
        didCopyToClipboard = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopyToClipboard = false
        }
    }

    // MARK: - Private frame loop

    /// Consumes the camera frame stream and throttles MLKit calls to ~2 fps to stay
    /// within the recognizer's throughput without overwhelming the main actor.
    private func beginProcessingFrames() {
        frameProcessingTask?.cancel()
        let camera = cameraService
        let service = recognitionService

        frameProcessingTask = Task { [weak self] in
            for await result in Self.recognitionResults(camera: camera, service: service) {
                self?.recognitionResult = result
            }
        }
    }

    /// Camera frames are consumed entirely off the main actor; only a `Sendable`
    /// `RecognitionResult` crosses back to it.
    ///
    /// This is not only what strict concurrency requires — `CMSampleBuffer` is not
    /// `Sendable`, so iterating the frame stream from this `@MainActor` type is an
    /// error — it is also what the throttling comment above always claimed was
    /// happening. Consuming frames on the main actor would put every MLKit call
    /// on it.
    ///
    /// The frame stream is created *inside* the nonisolated task rather than
    /// passed in, so no `CMSampleBuffer` is ever reachable from main-actor code.
    private nonisolated static func recognitionResults(
        camera: CameraService,
        service: any TextRecognizing
    ) -> AsyncStream<RecognitionResult> {
        AsyncStream { continuation in
            let task = Task {
                var lastRecognizedAt: ContinuousClock.Instant?

                for await frame in camera.makeFrameStream() {
                    guard !Task.isCancelled else { break }

                    let now = ContinuousClock.now
                    if let last = lastRecognizedAt, (now - last) < .seconds(0.5) { continue }
                    lastRecognizedAt = now

                    do {
                        let result = try await service.recognize(sampleBuffer: frame.buffer)
                        guard !Task.isCancelled else { break }
                        if !result.isEmpty {
                            continuation.yield(result)
                        }
                    } catch is CancellationError {
                        break
                    } catch {
                        // Per-frame failures are transient; surface only persistent camera errors
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
