import SwiftUI

/// Settings screen — colour-scheme switching via the `AppColorScheme`
/// preference in `AppState`, and the account section that reads the signed-in
/// user through `ProfileViewModel`.
///
/// The account section is where Phase 8 item 3 becomes visible: the email and
/// name shown here come from a `SyncStrategy` the composition root resolved,
/// and pull-to-refresh asks the factory for a policy that goes to the network.
/// It used to read `appState.currentUserEmail`, which is set by the login
/// response and never refreshed.
struct SettingsView: View {
    @State private var viewModel: ProfileViewModel
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    @MainActor
    init(container: AppContainer) {
        _viewModel = State(wrappedValue: container.makeProfileViewModel())
    }

    var body: some View {
        @Bindable var appState = appState
        List {
            Section("Account") {
                accountRows
                // Was `appState.signOut()`, which cleared two booleans and left
                // both tokens in the Keychain. The view model announces instead
                // and `SessionObserver` does both halves — see `docs/events.md`.
                Button("Sign Out", role: .destructive) {
                    viewModel.signOut()
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
        .task { await viewModel.onAppear() }
        .refreshable { await viewModel.refresh() }
    }

    // MARK: - Account section

    @ViewBuilder
    private var accountRows: some View {
        switch viewModel.state {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading profile…")
                    .foregroundStyle(.secondary)
            }
        case .failure(let error):
            // The email from the login response is still the best thing on
            // hand when the profile fetch fails, so the row keeps working and
            // the failure is stated rather than swallowed.
            LabeledContent("Email", value: appState.currentUserEmail ?? "—")
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .success(let user):
            LabeledContent("Email", value: user.email)
            nameEditor
            if viewModel.origin == .localCache {
                Label("Showing a saved copy — you appear to be offline.", systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let message = viewModel.saveErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var nameEditor: some View {
        HStack {
            TextField("Name", text: $viewModel.draftName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
            if viewModel.isSaving {
                ProgressView()
            } else {
                Button("Save") {
                    Task { await viewModel.saveName() }
                }
                .buttonStyle(.borderless)
                .disabled(!viewModel.canSave)
            }
        }
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
                        .foregroundStyle(AppColors.accent)
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
        SettingsView(container: .preview)
            .environment(AppState())
    }
    .preferredColorScheme(.light)
}

#Preview("Dark mode") {
    NavigationStack {
        SettingsView(container: .preview)
            .environment(AppState())
    }
    .preferredColorScheme(.dark)
}
