import AVFoundation
import CoreMedia

// MARK: - Errors

enum CameraError: Error, LocalizedError {
    case notAuthorized
    case deviceUnavailable
    case configurationFailed

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Camera access was denied. Enable it in Settings > Privacy > Camera."
        case .deviceUnavailable: return "No camera device is available on this device."
        case .configurationFailed: return "Failed to configure the capture session."
        }
    }
}

// MARK: - CameraService

/// Manages `AVCaptureSession` and streams raw sample buffers as an `AsyncStream`.
///
/// All session mutations run on `sessionQueue`. The `AVCaptureVideoDataOutputSampleBufferDelegate`
/// callback also fires on `sessionQueue`, ensuring `continuation` access is always serialized.
///
/// Marked `@unchecked Sendable` because thread-safety is enforced by `sessionQueue`.
final class CameraService: NSObject, @unchecked Sendable {
    // MARK: - Private state (accessed only on sessionQueue except previewLayer)

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.boilerplate.camera.session", qos: .userInitiated)
    private var continuation: AsyncStream<CMSampleBuffer>.Continuation?

    // MARK: - Public

    /// Preview layer bound to the capture session; safe to read from MainActor.
    let previewLayer: AVCaptureVideoPreviewLayer

    override init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        super.init()
    }

    // MARK: - Frame stream

    /// Returns a new `AsyncStream` that yields each captured sample buffer.
    /// Frames arrive at ~30 fps; downstream consumers should throttle as needed.
    func makeFrameStream() -> AsyncStream<CMSampleBuffer> {
        AsyncStream { [weak self] continuation in
            self?.sessionQueue.async { self?.continuation = continuation }
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.sessionQueue.async { self?.continuation = nil }
            }
        }
    }

    // MARK: - Lifecycle

    func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    func start() async throws {
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

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.stopRunning()
            self.continuation?.finish()
            self.continuation = nil
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
    func captureOutput(
        _: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from _: AVCaptureConnection
    ) {
        continuation?.yield(sampleBuffer)
    }
}
