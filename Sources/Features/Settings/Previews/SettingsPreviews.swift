import Core
import SwiftUI

// MARK: - SettingsView

/// PreviewProvider-style catalogue for `SettingsView`.
package struct SettingsView_Previews: PreviewProvider {
    package static var previews: some View {
        Group {
            NavigationStack {
                SettingsView(dependencies: PreviewSettingsDependencies())
                    .environment(AppState())
            }
            .preferredColorScheme(.light)
            .previewDisplayName("Light Mode")

            NavigationStack {
                SettingsView(dependencies: PreviewSettingsDependencies())
                    .environment(AppState())
            }
            .preferredColorScheme(.dark)
            .previewDisplayName("Dark Mode")

            NavigationStack {
                SettingsView(dependencies: PreviewSettingsDependencies())
                    .environment(AppState())
            }
            .previewDevice(PreviewDevice(rawValue: "iPad Pro (12.9-inch) (6th generation)"))
            .previewDisplayName("iPad")
        }
    }
}
