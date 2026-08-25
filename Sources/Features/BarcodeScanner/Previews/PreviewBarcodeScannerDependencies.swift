/// The preview stand-in for the composition root. See
/// `PreviewLoginDependencies` for why each feature ships one, and
/// `PreviewTextRecognitionDependencies` for why the camera service is real.
package struct PreviewBarcodeScannerDependencies: BarcodeScannerDependencies {

    package init() {}

    @MainActor
    package func makeBarcodeScannerViewModel() -> BarcodeScannerViewModel {
        BarcodeScannerViewModel(
            cameraService: CameraService(),
            scannerService: MockBarcodeScannerService()
        )
    }
}
