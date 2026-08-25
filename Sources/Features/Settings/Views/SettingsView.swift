import Core
import SwiftUI

/// Settings screen — colour-scheme switching via the `AppColorScheme`
/// preference in `AppState`, and the account section driven by
/// `ProfileFeature`.
///
/// The account section is where Phase 8 item 3 becomes visible: the email and
/// name shown here come from a `SyncStrategy` the composition root resolved,
/// and pull-to-refresh asks the factory for a policy that goes to the network.
/// It used to read `appState.currentUserEmail`, which is set by the login
/// response and never refreshed.
///
/// Since Phase 8 item 6 it holds a `Store` rather than a view model, and the
/// difference is visible in this file: every gesture below is one `send`, and
/// there is no call anywhere in it that changes what the screen shows. The
/// rows read derived properties of one state value, so the branch that renders
/// a cached profile cannot disagree with the branch that renders the name.
package struct SettingsView: View {
    @State private var store: Store<ProfileFeature>
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    @MainActor
    package init(dependencies: any SettingsDependencies) {
        _store = State(wrappedValue: dependencies.makeProfileStore())
    }

    package var body: some View {
        @Bindable var appState = appState
        List {
            Section("Account") {
                accountRows
                // Was `appState.signOut()`, which cleared two booleans and left
                // both tokens in the Keychain. The effect announces instead and
                // `SessionObserver` does both halves — see `docs/events.md`.
                Button("Sign Out", role: .destructive) {
                    store.send(.signOutTapped)
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
        .task { await store.send(.appeared) }
        .refreshable { await store.send(.refreshRequested) }
    }

    // MARK: - Account section

    /// Rendered from derived properties rather than from a `switch` over the
    /// phase, which is what lets a reload keep the rows on screen: during a
    /// refresh the state still carries the user it was showing, so there is a
    /// user to render and no separate "refreshing" branch to keep in step.
    @ViewBuilder
    private var accountRows: some View {
        if let user = store.state.user {
            LabeledContent("Email", value: user.email)
            nameEditor
            if store.state.origin == .localCache {
                Label("Showing a saved copy — you appear to be offline.", systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let message = store.state.saveErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } else if let message = store.state.loadErrorMessage {
            // The email from the login response is still the best thing on
            // hand when the profile fetch fails, so the row keeps working and
            // the failure is stated rather than swallowed.
            LabeledContent("Email", value: appState.currentUserEmail ?? "—")
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading profile…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var nameEditor: some View {
        HStack {
            TextField("Name", text: draftName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
            if store.state.isSaving {
                ProgressView()
            } else {
                Button("Save") {
                    store.send(.saveTapped)
                }
                .buttonStyle(.borderless)
                .disabled(!store.state.canSave)
            }
        }
    }

    /// Every keystroke is an action. The store reduces it before the setter
    /// returns, which is what keeps the field from snapping back — see
    /// `Store.binding(_:sending:)`.
    private var draftName: Binding<String> {
        store.binding(\.draftName, sending: ProfileFeature.Action.draftNameEdited)
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
