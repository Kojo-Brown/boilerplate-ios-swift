import Core
import SwiftUI

// MARK: - HomeView

/// PreviewProvider-style catalogue for `HomeView`.
package struct HomeView_Previews: PreviewProvider {
    package static var previews: some View {
        Group {
            NavigationStack {
                HomeView(dependencies: PreviewHomeDependencies())
                    .environment(AppCoordinator())
            }
            .previewDisplayName("Default")

            NavigationStack {
                HomeView(dependencies: PreviewHomeDependencies())
                    .environment(AppCoordinator())
            }
            .preferredColorScheme(.dark)
            .previewDisplayName("Dark Mode")

            NavigationStack {
                HomeView(dependencies: PreviewHomeDependencies())
                    .environment(AppCoordinator())
            }
            .previewDevice(PreviewDevice(rawValue: "iPad Pro (12.9-inch) (6th generation)"))
            .previewDisplayName("iPad – Regular Width")
        }
    }
}
