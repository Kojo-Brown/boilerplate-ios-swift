import AVFoundation
import Core
import Foundation
import Observation
import UIKit

/// Drives the barcode/QR scanner screen: manages camera lifecycle, Vision scan throttling,
/// and surfaces detected barcodes for the overlay UI.
///
/// Inject `scannerService` in tests to avoid Vision and hardware dependencies.
@Observable
@MainActor
package final class BarcodeScannerViewModel: ViewModelProtocol {
    // MARK: - Published state

    private(set) var scanResult: ScanResult?
    private(set) var isScanning = false
    private(set) var errorMessage: String?
    private(set) var permissionDenied = false
    private(set) var didCopyToClipboard = false

    // MARK: - Dependencies

    private let cameraService: CameraService
    private let scannerService: any BarcodeScanning

    // MARK: - Private

    private var frameTask: Task<Void, Never>?

    package var previewLayer: AVCaptureVideoPreviewLayer { cameraService.previewLayer }

    // MARK: - Init

    /// Built by `AppContainer.makeBarcodeScannerViewModel()`. See the note on
    /// `TextRecognitionViewModel.init` for why the camera service is passed in
    /// rather than defaulted.
    package init(
        cameraService: CameraService,
        scannerService: any BarcodeScanning
    ) {
        self.cameraService = cameraService
        self.scannerService = scannerService
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
        frameTask?.cancel()
        frameTask = nil
        cameraService.stop()
        isScanning = false
    }

    package func clearResult() {
        scanResult = nil
    }

    package func copyPayload() {
        guard let payload = scanResult?.primaryBarcode?.payload else { return }
        UIPasteboard.general.string = payload
        didCopyToClipboard = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopyToClipboard = false
        }
    }

    // MARK: - Private frame loop

    /// Consumes the camera frame stream and throttles Vision calls to ~3 fps.
    /// Once a barcode is detected the result is surfaced immediately; the stream
    /// keeps processing so a new scan after `clearResult()` picks up the next code.
    private func beginProcessingFrames() {
        frameTask?.cancel()
        let stream = cameraService.makeFrameStream()
        let service = scannerService

        frameTask = Task { [weak self] in
            var lastScannedAt: ContinuousClock.Instant?

            for await frame in stream {
                guard !Task.isCancelled else { break }

                let now = ContinuousClock.now
                if let last = lastScannedAt, (now - last) < .seconds(0.3) { continue }
                lastScannedAt = now

                do {
                    let result = try await service.scan(frame: frame)
                    guard !Task.isCancelled else { break }
                    if !result.isEmpty {
                        self?.scanResult = result
                    }
                } catch is CancellationError {
                    break
                } catch {
                    // Per-frame failures are transient; ignore them
                }
            }
        }
    }
}
