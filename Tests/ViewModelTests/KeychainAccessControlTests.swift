import Foundation
import Security
import Testing
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Features
@testable import Networking

// MARK: - The policy table

/// `KeychainAccessPolicy` is a mapping onto two Security-framework attributes,
/// and the attributes are the part nothing else can check: a written item does
/// not hand its access control back, so a policy that maps to the wrong flags
/// is invisible at runtime and stays that way until somebody reads data they
/// should have been asked for. These tests are that check.
@Suite("Keychain access policies map onto the Security attributes")
struct KeychainAccessPolicyTests {

    private func accessibilityName(_ policy: KeychainAccessPolicy) -> String {
        policy.accessibility as String
    }

    @Test("Exactly the gated cases require authentication")
    func gatedCasesRequireAuthentication() {
        let gated = KeychainAccessPolicy.allCases.filter(\.requiresAuthentication)
        #expect(Set(gated) == [
            .userPresence,
            .biometryAny,
            .biometryCurrentSet,
            .biometryCurrentSetOrPasscode,
            .devicePasscode,
        ])
        #expect(KeychainAccessPolicy.allCases.count == 7)
    }

    /// The pairing `KeychainAccessPolicy` documents: an authentication
    /// constraint is only as durable as the passcode under it, so every gated
    /// case rests on the accessibility that is destroyed when the passcode is
    /// removed.
    @Test("Every gated policy rests on WhenPasscodeSetThisDeviceOnly")
    func gatedPoliciesRestOnPasscodeSet() {
        let expected = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String
        for policy in KeychainAccessPolicy.allCases where policy.requiresAuthentication {
            #expect(accessibilityName(policy) == expected)
        }
    }

    @Test("The two ungated policies keep their own accessibility")
    func ungatedPoliciesKeepTheirAccessibility() {
        #expect(
            accessibilityName(.afterFirstUnlockThisDeviceOnly)
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        #expect(
            accessibilityName(.whenUnlockedThisDeviceOnly)
                == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
    }

    @Test("Each policy carries the flags its name claims")
    func flagsMatchTheNames() {
        #expect(KeychainAccessPolicy.afterFirstUnlockThisDeviceOnly.accessControlFlags == [])
        #expect(KeychainAccessPolicy.whenUnlockedThisDeviceOnly.accessControlFlags == [])
        #expect(KeychainAccessPolicy.userPresence.accessControlFlags == .userPresence)
        #expect(KeychainAccessPolicy.biometryAny.accessControlFlags == .biometryAny)
        #expect(KeychainAccessPolicy.biometryCurrentSet.accessControlFlags == .biometryCurrentSet)
        #expect(KeychainAccessPolicy.devicePasscode.accessControlFlags == .devicePasscode)
        #expect(
            KeychainAccessPolicy.biometryCurrentSetOrPasscode.accessControlFlags
                == [.biometryCurrentSet, .or, .devicePasscode]
        )
    }

    /// The distinction the shipped policy is chosen for: a re-enrolment — the
    /// move available to somebody who has the passcode — must not carry the
    /// old item with it.
    @Test("Only the currentSet policies are invalidated by a new enrolment")
    func onlyCurrentSetPoliciesAreInvalidatedByEnrolment() {
        let invalidated = KeychainAccessPolicy.allCases.filter(\.invalidatedByBiometricEnrolment)
        #expect(Set(invalidated) == [.biometryCurrentSet, .biometryCurrentSetOrPasscode])
    }

    @Test("An ungated policy builds no access control")
    func ungatedPolicyBuildsNoAccessControl() throws {
        #expect(try KeychainAccessPolicy.afterFirstUnlockThisDeviceOnly.makeAccessControl() == nil)
        #expect(try KeychainAccessPolicy.whenUnlockedThisDeviceOnly.makeAccessControl() == nil)
    }

    /// `SecAccessControlCreateWithFlags` is the call that rejects a flag
    /// combination this platform will not honour, and it rejects it at write
    /// time with a `CFError` nobody sees. Building each one here means an
    /// unbuildable policy fails a test rather than a sign-in.
    @Test("Every gated policy builds an access control the Security framework accepts")
    func gatedPoliciesBuildAnAccessControl() throws {
        for policy in KeychainAccessPolicy.allCases where policy.requiresAuthentication {
            #expect(try policy.makeAccessControl() != nil, "\(policy) produced no access control")
        }
    }
}

// MARK: - The gate, as the double enforces it

/// `InMemoryKeychain` stands in for the daemon in every other test in this
/// suite, so the gate has to mean something to it. A double that ignored the
/// policy would let every one of those tests pass against behaviour the device
/// does not have.
@Suite("The in-memory Keychain enforces the gate it was written under")
struct InMemoryKeychainGateTests {

    @Test("An unauthenticated read of a gated item is refused, not prompted")
    func unauthenticatedReadOfGatedItemIsRefused() throws {
        let keychain = InMemoryKeychain()
        try keychain.set("gated-secret", forKey: "unlock", policy: .biometryCurrentSetOrPasscode)

        #expect(throws: KeychainError.authenticationRequired) {
            _ = try keychain.string(forKey: "unlock")
        }
        #expect(keychain.authenticationCount == 0)
    }

    @Test("An authenticated read returns the value and records the reason")
    func authenticatedReadReturnsTheValue() throws {
        let keychain = InMemoryKeychain()
        try keychain.set("gated-secret", forKey: "unlock", policy: .biometryCurrentSet)

        let value = try keychain.string(forKey: "unlock", authenticationReason: "Unlock your account")
        #expect(value == "gated-secret")
        #expect(keychain.authenticationCount == 1)
        #expect(keychain.lastAuthenticationReason == "Unlock your account")
    }

    /// The real Keychain does not consult `LAContext` for an item that carries
    /// no access control, so neither does this: a reason passed to an
    /// ungated read is ignored rather than counted as a prompt.
    @Test("Reading an ungated item with a reason prompts nobody")
    func ungatedReadWithAReasonDoesNotPrompt() throws {
        let keychain = InMemoryKeychain()
        try keychain.set("plain", forKey: "session", policy: .afterFirstUnlockThisDeviceOnly)

        #expect(try keychain.string(forKey: "session", authenticationReason: "why") == "plain")
        #expect(keychain.authenticationCount == 0)
    }

    @Test("A cancelled prompt surfaces as userCancelled")
    func cancelledPromptSurfaces() throws {
        let keychain = InMemoryKeychain()
        try keychain.set("gated-secret", forKey: "unlock", policy: .userPresence)
        keychain.stubbedAuthenticationOutcome = .userCancelled

        #expect(throws: KeychainError.userCancelled) {
            _ = try keychain.string(forKey: "unlock", authenticationReason: "Unlock")
        }
    }

    @Test("Existence is answerable without opening the gate")
    func existenceDoesNotPrompt() throws {
        let keychain = InMemoryKeychain()
        try keychain.set("gated-secret", forKey: "unlock", policy: .biometryCurrentSet)

        #expect(try keychain.contains("unlock"))
        #expect(!(try keychain.contains("absent")))
        #expect(keychain.authenticationCount == 0)
    }

    /// The property that makes `KeychainWrapper.set` a delete-then-add: a
    /// second write has to replace the policy, not merely the bytes.
    @Test("Rewriting an item replaces its policy")
    func rewritingReplacesThePolicy() throws {
        let keychain = InMemoryKeychain()
        try keychain.set("first", forKey: "item", policy: .biometryCurrentSet)
        try keychain.set("second", forKey: "item", policy: .afterFirstUnlockThisDeviceOnly)

        #expect(keychain.policy(forKey: "item") == .afterFirstUnlockThisDeviceOnly)
        #expect(try keychain.string(forKey: "item") == "second")
    }

    /// The device with no passcode, which cannot hold a gated item at all.
    @Test("A gated write can fail while an ungated one succeeds")
    func gatedWriteCanFail() throws {
        let keychain = InMemoryKeychain()
        keychain.stubbedGatedWriteFailure = .unhandledError(status: errSecDecode)

        #expect(throws: KeychainError.unhandledError(status: errSecDecode)) {
            try keychain.set("secret", forKey: "unlock", policy: .biometryCurrentSet)
        }
        try keychain.set("plain", forKey: "session", policy: .afterFirstUnlockThisDeviceOnly)
        #expect(try keychain.string(forKey: "session") == "plain")
    }
}

// MARK: - The unlock record

@Suite("TokenStore protects its tokens the way the policy says")
struct TokenStoreAccessControlTests {

    private func pair(_ suffix: String = "") -> TokenPair {
        TokenPair(accessToken: "mock-access-token\(suffix)", refreshToken: "mock-refresh-token\(suffix)")
    }

    @Test("Session tokens are written ungated, on purpose")
    func sessionTokensAreUngated() async throws {
        let keychain = InMemoryKeychain()
        let store = TokenStore(keychain: keychain, biometricUnlock: .deviceOwner)
        try await store.setTokens(pair())

        #expect(keychain.policy(forKey: TokenStore.Keys.accessToken) == TokenStore.sessionPolicy)
        #expect(keychain.policy(forKey: TokenStore.Keys.refreshToken) == TokenStore.sessionPolicy)
        #expect(!TokenStore.sessionPolicy.requiresAuthentication)
    }

    @Test("No unlock record exists unless the container asked for one")
    func unlockRecordIsOptIn() async throws {
        let keychain = InMemoryKeychain()
        let store = TokenStore(keychain: keychain)
        try await store.setTokens(pair())

        let enrolled = await store.isBiometricUnlockEnrolled
        #expect(!(try keychain.contains(TokenStore.Keys.biometricRefreshToken)))
        #expect(!enrolled)
    }

    @Test("The unlock record carries the refresh token behind the gate")
    func unlockRecordIsGated() async throws {
        let keychain = InMemoryKeychain()
        let store = TokenStore(keychain: keychain, biometricUnlock: .deviceOwner)
        try await store.setTokens(pair())

        let enrolled = await store.isBiometricUnlockEnrolled
        #expect(keychain.policy(forKey: TokenStore.Keys.biometricRefreshToken) == .biometryCurrentSetOrPasscode)
        #expect(enrolled)
        #expect(throws: KeychainError.authenticationRequired) {
            _ = try keychain.string(forKey: TokenStore.Keys.biometricRefreshToken)
        }
    }

    /// A rotated refresh token leaves a stale gated copy behind unless every
    /// write refreshes it — an unlock that authenticates the user and then
    /// fails the exchange, which is the worst of both.
    @Test("A rotated token rewrites the record")
    func rotationRewritesTheRecord() async throws {
        let keychain = InMemoryKeychain()
        let store = TokenStore(keychain: keychain, biometricUnlock: .deviceOwner)
        try await store.setTokens(pair())
        try await store.setTokens(pair("-2"))

        let unlocked = try await store.biometricRefreshToken(reason: "Unlock")
        #expect(unlocked == "mock-refresh-token-2")
    }

    @Test("An unlock reads the record and says why it is asking")
    func unlockReadsTheRecord() async throws {
        let keychain = InMemoryKeychain()
        let store = TokenStore(keychain: keychain, biometricUnlock: .deviceOwner)
        try await store.setTokens(pair())

        let token = try await store.biometricRefreshToken(reason: "Unlock your account")
        #expect(token == "mock-refresh-token")
        #expect(keychain.authenticationCount == 1)
        #expect(keychain.lastAuthenticationReason == "Unlock your account")
    }

    @Test("A declined prompt is reported as the user's answer")
    func declinedPromptIsReported() async throws {
        let keychain = InMemoryKeychain()
        let store = TokenStore(keychain: keychain, biometricUnlock: .deviceOwner)
        try await store.setTokens(pair())
        keychain.stubbedAuthenticationOutcome = .userCancelled

        await #expect(throws: KeychainError.userCancelled) {
            _ = try await store.biometricRefreshToken(reason: "Unlock")
        }
    }

    @Test("A store with no unlock policy has nothing to unlock")
    func storeWithoutPolicyHasNothingToUnlock() async throws {
        let keychain = InMemoryKeychain()
        let store = TokenStore(keychain: keychain)
        try await store.setTokens(pair())

        await #expect(throws: APIError.self) {
            _ = try await store.biometricRefreshToken(reason: "Unlock")
        }
    }

    /// `.enabled(.afterFirstUnlockThisDeviceOnly)` is a policy that reads as
    /// protection and provides none. It is refused at the one place that can
    /// still refuse it.
    @Test("An ungated unlock policy reads as disabled")
    func ungatedUnlockPolicyReadsAsDisabled() async throws {
        #expect(BiometricUnlockPolicy.enabled(.afterFirstUnlockThisDeviceOnly).gatedPolicy == nil)
        #expect(BiometricUnlockPolicy.disabled.gatedPolicy == nil)
        #expect(BiometricUnlockPolicy.deviceOwner.gatedPolicy == .biometryCurrentSetOrPasscode)

        let keychain = InMemoryKeychain()
        let store = TokenStore(keychain: keychain, biometricUnlock: .enabled(.whenUnlockedThisDeviceOnly))
        try await store.setTokens(pair())
        #expect(!(try keychain.contains(TokenStore.Keys.biometricRefreshToken)))
    }

    @Test("Signing out takes the gated copy with it")
    func signOutClearsTheRecord() async throws {
        let keychain = InMemoryKeychain()
        let store = TokenStore(keychain: keychain, biometricUnlock: .deviceOwner)
        try await store.setTokens(pair())
        await store.clearTokens()

        #expect(!(try keychain.contains(TokenStore.Keys.biometricRefreshToken)))
        #expect(!(try keychain.contains(TokenStore.Keys.accessToken)))
    }

    @Test("Disabling the unlock leaves the session alone")
    func disablingLeavesTheSession() async throws {
        let keychain = InMemoryKeychain()
        let store = TokenStore(keychain: keychain, biometricUnlock: .deviceOwner)
        try await store.setTokens(pair())
        await store.disableBiometricUnlock()

        let token = try await store.currentToken()
        #expect(!(try keychain.contains(TokenStore.Keys.biometricRefreshToken)))
        #expect(token == "mock-access-token")
    }

    /// A device with no passcode cannot hold the record. Sign-in still works
    /// there, and the reason it could not be written is legible rather than
    /// swallowed.
    @Test("A record that cannot be written does not fail the sign-in")
    func failedRecordDoesNotFailSignIn() async throws {
        let keychain = InMemoryKeychain()
        keychain.stubbedGatedWriteFailure = .unhandledError(status: errSecDecode)
        let store = TokenStore(keychain: keychain, biometricUnlock: .deviceOwner)

        try await store.setTokens(pair())

        let token = try await store.currentToken()
        let failure = await store.lastBiometricUnlockError
        #expect(token == "mock-access-token")
        #expect(!(try keychain.contains(TokenStore.Keys.biometricRefreshToken)))
        #expect(failure == .unhandledError(status: errSecDecode))
    }

    @Test("A record written after a failure clears the recorded reason")
    func successfulRecordClearsTheReason() async throws {
        let keychain = InMemoryKeychain()
        keychain.stubbedGatedWriteFailure = .unhandledError(status: errSecDecode)
        let store = TokenStore(keychain: keychain, biometricUnlock: .deviceOwner)
        try await store.setTokens(pair())

        keychain.stubbedGatedWriteFailure = nil
        try await store.setTokens(pair("-2"))

        let failure = await store.lastBiometricUnlockError
        let enrolled = await store.isBiometricUnlockEnrolled
        #expect(failure == nil)
        #expect(enrolled)
    }
}
