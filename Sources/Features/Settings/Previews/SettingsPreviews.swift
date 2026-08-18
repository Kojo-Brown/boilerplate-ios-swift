import SwiftUI

// MARK: - SettingsView

/// PreviewProvider-style catalogue for `SettingsView`.
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            NavigationStack {
                SettingsView(container: .preview)
                    .environment(AppState())
            }
            .preferredColorScheme(.light)
            .previewDisplayName("Light Mode")

            NavigationStack {
                SettingsView(container: .preview)
                    .environment(AppState())
            }
            .preferredColorScheme(.dark)
            .previewDisplayName("Dark Mode")

            NavigationStack {
                SettingsView(container: .preview)
                    .environment(AppState())
            }
            .previewDevice(PreviewDevice(rawValue: "iPad Pro (12.9-inch) (6th generation)"))
            .previewDisplayName("iPad")
        }
    }
}
