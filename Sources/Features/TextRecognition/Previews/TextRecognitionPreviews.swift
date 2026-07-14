import SwiftUI

// MARK: - TextRecognitionView

/// PreviewProvider-style catalogue for `TextRecognitionView`.
/// Renders within a NavigationStack to match the runtime embedding context.
struct TextRecognitionView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            NavigationStack {
                TextRecognitionView()
                    .environment(AppCoordinator())
            }
            .previewDisplayName("Text Scanner")

            NavigationStack {
                TextRecognitionView()
                    .environment(AppCoordinator())
            }
            .preferredColorScheme(.dark)
            .previewDisplayName("Text Scanner – Dark")
        }
    }
}
