import SwiftUI

/// Settings screen — demonstrates colour-scheme switching via
/// `@Environment(\.colorScheme)` and the `AppColorScheme` preference stored
/// in `AppState`.
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        @Bindable var appState = appState
        List {
            Section("Account") {
                LabeledContent("Email", value: appState.currentUserEmail ?? "—")
                Button("Sign Out", role: .destructive) {
                    appState.signOut()
                }
            }

            Section {
                appearancePicker(selection: $appState.colorSchemePreference)
            } header: {
                Text("Appearance")
            } footer: {
                Text(appearanceFooter)
            }

            Section("App") {
                LabeledContent("Version", value: Bundle.main.appVersion)
                LabeledContent("Build", value: Bundle.main.buildNumber)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - Appearance section

    @ViewBuilder
    private func appearancePicker(selection: Binding<AppColorScheme>) -> some View {
        ForEach(AppColorScheme.allCases) { scheme in
            HStack {
                Label(scheme.label, systemImage: scheme.systemImage)
                Spacer()
                if selection.wrappedValue == scheme {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.accent)
                        .fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { selection.wrappedValue = scheme }
        }
    }

    private var appearanceFooter: String {
        switch appState.colorSchemePreference {
        case .system: "Matches your device's appearance setting."
        case .light:  "Always uses the light appearance."
        case .dark:   "Always uses the dark appearance."
        }
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

// MARK: - Previews

#Preview("Light mode") {
    NavigationStack {
        SettingsView()
            .environment(AppState())
    }
    .preferredColorScheme(.light)
}

#Preview("Dark mode") {
    NavigationStack {
        SettingsView()
            .environment(AppState())
    }
    .preferredColorScheme(.dark)
}
