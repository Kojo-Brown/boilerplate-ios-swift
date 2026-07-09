import Testing
@testable import BoilerplateiOSSwift

// MARK: - InMemoryKeychain (shared test double)

/// Lock-protected in-memory `KeychainStoring` implementation for unit tests.
///
/// Avoids a dependency on the Keychain daemon, which is unavailable in CI
/// and simulators without entitlements.
final class InMemoryKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func string(forKey key: String) throws -> String? {
        lock.withLock { storage[key] }
    }

    func set(_ value: String, forKey key: String) throws {
        lock.withLock { storage[key] = value }
    }

    func remove(forKey key: String) throws {
        lock.withLock { storage[key] = nil }
    }

    func removeAll() throws {
        lock.withLock { storage.removeAll() }
    }
}

// MARK: - KeychainWrapper unit tests (via InMemoryKeychain)

struct KeychainWrapperTests {

    @Test func storeAndRetrieveString() throws {
        let keychain = InMemoryKeychain()
        try keychain.set("secret", forKey: "token")
        let retrieved = try keychain.string(forKey: "token")
        #expect(retrieved == "secret")
    }

    @Test func returnsNilForMissingKey() throws {
        let keychain = InMemoryKeychain()
        let result = try keychain.string(forKey: "nonexistent")
        #expect(result == nil)
    }

    @Test func overwritesExistingValue() throws {
        let keychain = InMemoryKeychain()
        try keychain.set("first", forKey: "key")
        try keychain.set("second", forKey: "key")
        let result = try keychain.string(forKey: "key")
        #expect(result == "second")
    }

    @Test func removeDeletesKey() throws {
        let keychain = InMemoryKeychain()
        try keychain.set("value", forKey: "key")
        try keychain.remove(forKey: "key")
        let result = try keychain.string(forKey: "key")
        #expect(result == nil)
    }

    @Test func removeMissingKeyDoesNotThrow() throws {
        let keychain = InMemoryKeychain()
        try keychain.remove(forKey: "absent")
    }

    @Test func removeAllClearsStorage() throws {
        let keychain = InMemoryKeychain()
        try keychain.set("a", forKey: "k1")
        try keychain.set("b", forKey: "k2")
        try keychain.removeAll()
        #expect(try keychain.string(forKey: "k1") == nil)
        #expect(try keychain.string(forKey: "k2") == nil)
    }

    @Test func multipleKeysAreIndependent() throws {
        let keychain = InMemoryKeychain()
        try keychain.set("alpha", forKey: "access")
        try keychain.set("beta", forKey: "refresh")
        #expect(try keychain.string(forKey: "access") == "alpha")
        #expect(try keychain.string(forKey: "refresh") == "beta")
    }

    // MARK: - TokenStore integration

    @Test func tokenStorePersiststoKeychainOnSet() async throws {
        let keychain = InMemoryKeychain()
        let store = TokenStore(keychain: keychain)
        try await store.setTokens(TokenPair(accessToken: "at", refreshToken: "rt"))

        // Verify the values landed in the backing store directly.
        #expect(try keychain.string(forKey: "com.boilerplate.accessToken") == "at")
        #expect(try keychain.string(forKey: "com.boilerplate.refreshToken") == "rt")
    }

    @Test func tokenStoreReadsFromKeychainOnInit() async throws {
        let keychain = InMemoryKeychain()
        // Pre-populate Keychain before creating the store (simulates app restart).
        try keychain.set("persisted", forKey: "com.boilerplate.accessToken")
        try keychain.set("persisted_rt", forKey: "com.boilerplate.refreshToken")

        let store = TokenStore(keychain: keychain)
        let token = try await store.currentToken()
        #expect(token == "persisted")
    }

    @Test func tokenStoreClearRemovesKeychainEntries() async throws {
        let keychain = InMemoryKeychain()
        let store = TokenStore(keychain: keychain)
        try await store.setTokens(TokenPair(accessToken: "at", refreshToken: "rt"))
        await store.clearTokens()

        #expect(try keychain.string(forKey: "com.boilerplate.accessToken") == nil)
        #expect(try keychain.string(forKey: "com.boilerplate.refreshToken") == nil)
    }
}
