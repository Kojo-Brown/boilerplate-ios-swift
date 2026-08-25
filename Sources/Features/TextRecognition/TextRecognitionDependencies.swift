/// What `TextRecognitionView` needs from the composition root. See
/// `LoginDependencies` for why each screen declares this rather than taking
/// `AppContainer`.
package protocol TextRecognitionDependencies {
    @MainActor func makeTextRecognitionViewModel() -> TextRecognitionViewModel
}
