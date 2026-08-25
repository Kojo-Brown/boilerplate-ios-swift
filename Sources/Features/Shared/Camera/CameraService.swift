import AVFoundation
import Core
import CoreMedia

// MARK: - Errors

package enum CameraError: Error, LocalizedError {
    case notAuthorized
    case deviceUnavailable
    case configurationFailed

    package var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Camera access was denied. Enable it in Settings > Privacy > Camera."
        case .deviceUnavailable: return "No camera device is available on this device."
        case .configurationFailed: return "Failed to configure the capture session."
        }
    }
}

// MARK: - CapturedFrame

/// One video frame, handed from the capture queue to a single consumer.
///
/// `CMSampleBuffer` is a CoreFoundation type that carries no `Sendable`
/// annotation, so an `AsyncStream<CMSampleBuffer>` cannot be iterated from an
/// actor-isolated task at all: `next()` would return a non-Sendable value across
/// the isolation boundary, which is exactly what the view models were doing.
///
/// Wrapping the frame makes the single hop it really takes — capture queue to
/// recogniser — expressible. The `@unchecked` is sound for that hop specifically:
/// a buffer is yielded to one stream, is never mutated after capture, and is not
/// retained beyond the recognise call that consumes it.
package struct CapturedFrame: @unchecked Sendable {
    package let buffer: CMSampleBuffer
}

// MARK: - CameraService

/// Manages `AVCaptureSession` and streams raw sample buffers as an `AsyncStream`.
///
/// All session mutations run on `sessionQueue`, and the
/// `AVCaptureVideoDataOutputSampleBufferDelegate` callback fires there too. The
/// frame stream itself is not confined to that queue — `DelegateStream` carries
/// its own lock, so a consumer can ask for a stream from any isolation without a
/// hop, and the delegate can yield into it without knowing who is listening.
///
/// Marked `@unchecked Sendable` because the capture session's thread-safety is
/// enforced by `sessionQueue`, which the compiler cannot see.
package final class CameraService: NSObject, @unchecked Sendable {
    // MARK: - Private state (session confined to sessionQueue; `frames` self-locking)

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.boilerplate.camera.session", qos: .userInitiated)

    /// Newest-wins, depth one: a recogniser that falls behind should resume on
    /// the frame in front of the camera now, not on the backlog it missed.
    ///
    /// Depth is not free here in the ordinary way. Each buffered frame retains a
    /// `CMSampleBuffer` from `AVCaptureVideoDataOutput`'s fixed-size pool, and an
    /// output with no free buffers left stops delivering — so an unbounded
    /// buffer does not grow without limit, it stalls the scan while the preview
    /// keeps running. See `DelegateStream` for the rest of that argument.
    private let frames = DelegateStream<CapturedFrame>(bufferingPolicy: .bufferingNewest(1))

    // MARK: - Public

    /// Preview layer bound to the capture session; safe to read from MainActor.
    package let previewLayer: AVCaptureVideoPreviewLayer

    package override init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        super.init()
    }

    // MARK: - Frame stream

    /// Returns an `AsyncStream` of captured frames, superseding any stream
    /// handed out earlier.
    ///
    /// Frames arrive at the capture rate — ~30 fps — and the stream keeps only
    /// the newest, so a consumer that throttles (both view models do) drops the
    /// frames it skips at the buffer rather than carrying them through the loop.
    ///
    /// Both view models call this again on every `startScanning()`, so a second
    /// call is the ordinary case rather than a misuse: the previous stream is
    /// finished, which is what ends the frame task the previous call started.
    ///
    /// No termination handler is installed. The session outlives any one
    /// consumer and is shared with `previewLayer`, and the view models cancel
    /// the frame task as a way of *switching* streams — stopping the camera on
    /// consumer exit would race the restart that follows it. `stop()` is what
    /// ends the session, and it is the caller's to call.
    package func makeFrameStream() -> AsyncStream<CapturedFrame> {
        frames.makeStream()
    }

    /// What the frame stream's buffering policy has done since this service was
    /// created: frames buffered, frames dropped as the consumer fell behind, and
    /// frames that arrived while nothing was listening.
    ///
    /// Exposed because newest-wins discards silently, and a scan that never
    /// completes looks the same from the view model whether the recogniser is
    /// wrong or the frames never got there.
    package var frameStatistics: DelegateStream<CapturedFrame>.Statistics {
        frames.statistics
    }

    // MARK: - Lifecycle

    package func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    package func start() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == .authorized else { throw CameraError.notAuthorized }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else { return cont.resume(throwing: CameraError.configurationFailed) }
                do {
                    try self.configureSession()
                    self.session.startRunning()
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Ends the frame stream and stops the capture session.
    ///
    /// Safe to call without a matching `start()`, which it was not before. A
    /// view that never got camera permission still tears down on disappear, and
    /// `-[AVCaptureSession stopRunning]` on a session that was never configured
    /// raises an Objective-C exception on the simulator — which, thrown onto
    /// `sessionQueue`, aborts the process rather than failing anything. Nothing
    /// had ever observed that: the existing view-model tests call `stop()` and
    /// then end, so the service was deallocated and the queued block took its
    /// `weak self` exit before reaching the session. Adding a test that outlives
    /// the hop is what ran the line for the first time. `configureSession`
    /// already guards its own entry the same way.
    package func stop() {
        // Finished before the hop rather than on it: the consumer's `for await`
        // should end when `stop()` is called, not whenever `sessionQueue` next
        // gets round to it. Frames already in flight from the delegate land
        // after this and are counted as undelivered, which is what they are.
        frames.finish()
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    // MARK: - Session configuration

    private func configureSession() throws {
        guard !session.isRunning else { return }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .hd1280x720

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        else { throw CameraError.deviceUnavailable }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.configurationFailed }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sessionQueue)
        guard session.canAddOutput(output) else { throw CameraError.configurationFailed }
        session.addOutput(output)

        // Portrait orientation
        output.connection(with: .video)?.videoRotationAngle = 90
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    package func captureOutput(
        _: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from _: AVCaptureConnection
    ) {
        // Returns immediately whatever the consumer is doing. That is the point
        // and also the catch: a delegate that is never late is one AVFoundation
        // never throttles, so the buffering policy on `frames` is the only thing
        // bounding the queue behind it.
        frames.yield(CapturedFrame(buffer: sampleBuffer))
    }
}
