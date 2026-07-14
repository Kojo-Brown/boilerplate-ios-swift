import SwiftUI

// MARK: - HomeView

/// PreviewProvider-style catalogue for `HomeView`.
struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            NavigationStack {
                HomeView()
                    .environment(AppCoordinator())
            }
            .previewDisplayName("Default")

            NavigationStack {
                HomeView()
                    .environment(AppCoordinator())
            }
            .preferredColorScheme(.dark)
            .previewDisplayName("Dark Mode")

            NavigationStack {
                HomeView()
                    .environment(AppCoordinator())
            }
            .previewDevice(PreviewDevice(rawValue: "iPad Pro (12.9-inch) (6th generation)"))
            .previewDisplayName("iPad – Regular Width")
        }
    }
}
