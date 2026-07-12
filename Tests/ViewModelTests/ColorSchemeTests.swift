import SwiftUI
import Testing
@testable import BoilerplateiOSSwift

// MARK: - AppColorScheme Tests

struct AppColorSchemeTests {

    // MARK: - All cases

    @Test func allCasesContainsThreeVariants() {
        #expect(AppColorScheme.allCases.count == 3)
    }

    @Test func allCasesContainsSystemLightDark() {
        let cases = AppColorScheme.allCases
        #expect(cases.contains(.system))
        #expect(cases.contains(.light))
        #expect(cases.contains(.dark))
    }

    // MARK: - Identifiable

    @Test func idMatchesRawValue() {
        #expect(AppColorScheme.system.id == "system")
        #expect(AppColorScheme.light.id  == "light")
        #expect(AppColorScheme.dark.id   == "dark")
    }

    // MARK: - Labels

    @Test func systemLabel() {
        #expect(AppColorScheme.system.label == "System")
    }

    @Test func lightLabel() {
        #expect(AppColorScheme.light.label == "Light")
    }

    @Test func darkLabel() {
        #expect(AppColorScheme.dark.label == "Dark")
    }

    // MARK: - System images

    @Test func allCasesHaveNonEmptySystemImage() {
        for scheme in AppColorScheme.allCases {
            #expect(!scheme.systemImage.isEmpty)
        }
    }

    // MARK: - ColorScheme mapping

    @Test func systemMapsToNilColorScheme() {
        #expect(AppColorScheme.system.colorScheme == nil)
    }

    @Test func lightMapsToLightColorScheme() {
        #expect(AppColorScheme.light.colorScheme == .light)
    }

    @Test func darkMapsToDarkColorScheme() {
        #expect(AppColorScheme.dark.colorScheme == .dark)
    }

    // MARK: - RawValue round-trip

    @Test func rawValueRoundTrip() {
        for scheme in AppColorScheme.allCases {
            let recovered = AppColorScheme(rawValue: scheme.rawValue)
            #expect(recovered == scheme)
        }
    }

    @Test func unknownRawValueReturnsNil() {
        #expect(AppColorScheme(rawValue: "unknown") == nil)
    }

    // MARK: - UserDefaults key

    @Test func defaultsKeyIsStable() {
        #expect(AppColorScheme.defaultsKey == "app.colorSchemePreference")
    }
}

// MARK: - AppState colour scheme persistence tests

@MainActor
struct AppStateColorSchemeTests {

    // MARK: - Default preference

    @Test func defaultPreferenceIsSystem() {
        // Wipe any leftover value so the test is isolated
        UserDefaults.standard.removeObject(forKey: AppColorScheme.defaultsKey)
        let sut = AppState()
        #expect(sut.colorSchemePreference == .system)
    }

    // MARK: - Preference mutation + persistence

    @Test func settingLightPreferencePersistsToDefaults() {
        UserDefaults.standard.removeObject(forKey: AppColorScheme.defaultsKey)
        let sut = AppState()
        sut.colorSchemePreference = .light
        let stored = UserDefaults.standard.string(forKey: AppColorScheme.defaultsKey)
        #expect(stored == "light")
    }

    @Test func settingDarkPreferencePersistsToDefaults() {
        UserDefaults.standard.removeObject(forKey: AppColorScheme.defaultsKey)
        let sut = AppState()
        sut.colorSchemePreference = .dark
        let stored = UserDefaults.standard.string(forKey: AppColorScheme.defaultsKey)
        #expect(stored == "dark")
    }

    @Test func settingSystemPreferencePersistsToDefaults() {
        UserDefaults.standard.removeObject(forKey: AppColorScheme.defaultsKey)
        let sut = AppState()
        sut.colorSchemePreference = .system
        let stored = UserDefaults.standard.string(forKey: AppColorScheme.defaultsKey)
        #expect(stored == "system")
    }

    @Test func preferenceRestoredFromDefaultsOnInit() {
        UserDefaults.standard.set("dark", forKey: AppColorScheme.defaultsKey)
        let sut = AppState()
        #expect(sut.colorSchemePreference == .dark)
        // Cleanup
        UserDefaults.standard.removeObject(forKey: AppColorScheme.defaultsKey)
    }

    @Test func invalidDefaultsValueFallsBackToSystem() {
        UserDefaults.standard.set("rainbow", forKey: AppColorScheme.defaultsKey)
        let sut = AppState()
        #expect(sut.colorSchemePreference == .system)
        // Cleanup
        UserDefaults.standard.removeObject(forKey: AppColorScheme.defaultsKey)
    }

    // MARK: - Existing AppState behaviour unaffected

    @Test func signOutClearsAuthState() {
        UserDefaults.standard.removeObject(forKey: AppColorScheme.defaultsKey)
        let sut = AppState()
        sut.isAuthenticated = true
        sut.currentUserEmail = "user@example.com"
        sut.colorSchemePreference = .dark
        sut.signOut()
        #expect(!sut.isAuthenticated)
        #expect(sut.currentUserEmail == nil)
        // Colour preference is unaffected by sign-out
        #expect(sut.colorSchemePreference == .dark)
    }
}
