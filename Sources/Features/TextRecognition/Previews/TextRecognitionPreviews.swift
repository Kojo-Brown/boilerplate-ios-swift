import Core
import SwiftUI

// MARK: - TextRecognitionView

/// PreviewProvider-style catalogue for `TextRecognitionView`.
/// Renders within a NavigationStack to match the runtime embedding context.
package struct TextRecognitionView_Previews: PreviewProvider {
    package static var previews: some View {
        Group {
            NavigationStack {
                TextRecognitionView(dependencies: PreviewTextRecognitionDependencies())
                    .environment(AppCoordinator())
            }
            .previewDisplayName("Text Scanner")

            NavigationStack {
                TextRecognitionView(dependencies: PreviewTextRecognitionDependencies())
                    .environment(AppCoordinator())
            }
            .preferredColorScheme(.dark)
            .previewDisplayName("Text Scanner – Dark")
        }
    }
}
