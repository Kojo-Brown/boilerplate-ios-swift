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
        // `id:` is explicit because `\.self` is unambiguous, but the errors this
        // block produced were not about `ForEach` at all: one invalid expression
        // inside the closure made the body fail to type-check as a `View`, which
        // knocked out every value-based `ForEach` overload and left only the
        // `Binding<C>` one. That is why the compiler reported "cannot convert
        // '[AppColorScheme]' to 'Binding<C>'" on this line rather than pointing at
        // the real culprit two lines down.
        ForEach(AppColorScheme.allCases, id: \.self) { scheme in
            HStack {
                Label(scheme.label, systemImage: scheme.systemImage)
                Spacer()
                if selection.wrappedValue == scheme {
                    Image(systemName: "checkmark")
                        // `.accent` is not a `ShapeStyle`; SwiftUI offers
                        // `Color.accentColor` and `.tint`, not `.accent`.
                        .foregroundStyle(Color.accentColor)
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
