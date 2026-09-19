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
            Section(FeatureStrings.Settings.accountSection.string) {
                accountRows
                // Was `appState.signOut()`, which cleared two booleans and left
                // both tokens in the Keychain. The effect announces instead and
                // `SessionObserver` does both halves — see `docs/events.md`.
                Button(FeatureStrings.Settings.signOut.string, role: .destructive) {
                    store.send(.signOutTapped)
                }
            }

            Section {
                appearancePicker(selection: $appState.colorSchemePreference)
            } header: {
                Text(FeatureStrings.Settings.appearanceSection)
            } footer: {
                Text(FeatureStrings.Settings.appearanceFooter(appState.colorSchemePreference))
            }

            Section(FeatureStrings.Settings.appSection.string) {
                LabeledContent(FeatureStrings.Settings.version.string, value: Bundle.main.appVersion)
                LabeledContent(FeatureStrings.Settings.build.string, value: Bundle.main.buildNumber)
            }
        }
        .navigationTitle(Text(FeatureStrings.Settings.title))
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
            LabeledContent(FeatureStrings.Settings.email.string, value: user.email)
            nameEditor
            if store.state.origin == .localCache {
                Label(FeatureStrings.Settings.offlineCopy.string, systemImage: "wifi.slash")
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
            LabeledContent(FeatureStrings.Settings.email.string, value: appState.currentUserEmail ?? "—")
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text(FeatureStrings.Settings.loadingProfile)
                    .foregroundStyle(.secondary)
            }
            // A spinner beside a sentence is two stops, the first of them
            // nameless. Combined it is one, and the sentence is the name.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(FeatureStrings.Settings.loadingProfileLabel))
        }
    }

    private var nameEditor: some View {
        HStack {
            TextField(FeatureStrings.Settings.name.string, text: draftName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
            if store.state.isSaving {
                // The Save button is gone while this is on screen, so the
                // spinner is the only thing left to say what happened to it.
                ProgressView()
                    .accessibilityLabel(Text(FeatureStrings.Settings.saving))
            } else {
                Button(FeatureStrings.Settings.save.string) {
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
            AppearanceOptionRow(
                scheme: scheme,
                isSelected: selection.wrappedValue == scheme
            ) {
                selection.wrappedValue = scheme
            }
        }
    }
}

// MARK: - Appearance row

/// One row of the appearance picker: a control that says what it is, that it is
/// a control, and whether it is the one currently in effect.
///
/// It was an `HStack` with `.contentShape(Rectangle())` and
/// `.onTapGesture { selection.wrappedValue = scheme }`, which is three separate
/// failures wearing one costume. A tap gesture publishes no `.isButton` trait,
/// so VoiceOver announced the row as text and never offered to activate it; it
/// is not an activation point either, so double-tapping did nothing; and the
/// current choice was a drawn checkmark, which means the selected row and the
/// other two sounded exactly alike. The screen had a picker nobody using
/// VoiceOver could operate or read the state of.
///
/// A `Button` fixes the first two by being one. The third is
/// `.isSelected`, which is what VoiceOver reads as "selected" and what the
/// checkmark is drawing — so the glyph is hidden, since a row that announced
/// both would say it twice.
///
/// Its own type rather than a closure inside `appearancePicker`, because the
/// three things above are a contract a row either keeps or does not, and a
/// named type is where that contract can be written down and read. It is
/// internal rather than private so a test can reach it without a store, an
/// `AppState` and a `List` around it — see `docs/accessibility.md` for why
/// that test reads the source rather than the published tree.
struct AppearanceOptionRow: View {

    let scheme: AppColorScheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(scheme.label.string, systemImage: scheme.systemImage)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(AppColors.accent)
                        .fontWeight(.semibold)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(scheme.label))
        .accessibilityAddTraits(traits)
    }

    /// Built up rather than written as a ternary over two literals, for the
    /// reason ``TagChip`` does the same: `AccessibilityTraits` is a set, and
    /// spelling the union out is what keeps "selected" additive to "button"
    /// instead of replacing it.
    private var traits: AccessibilityTraits {
        var resolved: AccessibilityTraits = .isButton
        if isSelected {
            resolved.formUnion(.isSelected)
        }
        return resolved
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
        SettingsView(dependencies: PreviewSettingsDependencies())
            .environment(AppState())
    }
    .preferredColorScheme(.light)
}

#Preview("Dark mode") {
    NavigationStack {
        SettingsView(dependencies: PreviewSettingsDependencies())
            .environment(AppState())
    }
    .preferredColorScheme(.dark)
}
