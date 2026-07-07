import SwiftUI

/// Settings screen — a coordinator-reachable destination demonstrating deep navigation.
struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        List {
            Section("Account") {
                LabeledContent("Email", value: appState.currentUserEmail ?? "—")
                Button("Sign Out", role: .destructive) {
                    appState.signOut()
                }
            }
            Section("App") {
                LabeledContent("Version", value: Bundle.main.appVersion)
                LabeledContent("Build", value: Bundle.main.buildNumber)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - Bundle helpers

private extension Bundle {
    var appVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }

    var buildNumber: String {
        (infoDictionary?["CFBundleVersion"] as? String) ?? "—"
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        SettingsView()
            .environment(AppState())
    }
}
