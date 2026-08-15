import SwiftUI

// MARK: - TextRecognitionView

/// PreviewProvider-style catalogue for `TextRecognitionView`.
/// Renders within a NavigationStack to match the runtime embedding context.
struct TextRecognitionView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            NavigationStack {
                TextRecognitionView(container: .preview)
                    .environment(AppCoordinator())
            }
            .previewDisplayName("Text Scanner")

            NavigationStack {
                TextRecognitionView(container: .preview)
                    .environment(AppCoordinator())
            }
            .preferredColorScheme(.dark)
            .previewDisplayName("Text Scanner – Dark")
        }
    }
}
