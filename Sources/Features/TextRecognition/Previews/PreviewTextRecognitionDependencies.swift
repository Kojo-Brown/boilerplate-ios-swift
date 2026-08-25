/// The preview stand-in for the composition root. See
/// `PreviewLoginDependencies` for why each feature ships one.
///
/// `CameraService` is real here, as it is in `AppContainer.preview`: there is no
/// double to vend, and construction alone touches no hardware — the session and
/// the preview layer are allocated, and nothing is configured until `start()`.
package struct PreviewTextRecognitionDependencies: TextRecognitionDependencies {

    package init() {}

    @MainActor
    package func makeTextRecognitionViewModel() -> TextRecognitionViewModel {
        TextRecognitionViewModel(
            cameraService: CameraService(),
            recognitionService: MockTextRecognitionService()
        )
    }
}
