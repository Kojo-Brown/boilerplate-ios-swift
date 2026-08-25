import Core

/// What `SettingsView` needs from the composition root. See `LoginDependencies`
/// for why each screen declares this rather than taking `AppContainer`.
package protocol SettingsDependencies {
    @MainActor func makeProfileStore() -> Store<ProfileFeature>
}
