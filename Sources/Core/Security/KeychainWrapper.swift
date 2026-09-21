import Foundation
import LocalAuthentication
import os
import Security

// MARK: - Keychain errors

package enum KeychainError: Error, Sendable, Equatable {
    case unexpectedData

    /// The item exists and is gated, and the read that found it offered no way
    /// to satisfy the gate. Never a prompt the caller did not ask for: see
    /// `KeychainWrapper.string(forKey:)`.
    case authenticationRequired

    /// The user was asked and could not prove who they were — a face the
    /// sensor rejected, or biometry locked out after too many attempts.
    case authenticationFailed

    /// The user was asked and declined, by dismissing the sheet or by taking
    /// the fallback button. Not a failure to report as one.
    case userCancelled

    case unhandledError(status: OSStatus)

    /// A failure that arrived without an `OSStatus` behind it — a double, or a
    /// conformer that threw something of its own. Kept distinct rather than
    /// folded into `unhandledError` with an invented status, which would read
    /// in a log as a Keychain error that never happened.
    case unknown

    /// Narrows an arbitrary error to this vocabulary.
    ///
    /// `KeychainStoring` promises to throw `KeychainError`, and a `catch` that
    /// wants to record why a write did not happen should not have to widen its
    /// storage to `any Error` to hold the case where something else did.
    package static func wrapping(_ error: any Error) -> KeychainError {
        (error as? KeychainError) ?? .unknown
    }

    /// Translates the handful of `OSStatus` values that mean something
    /// specific to a caller, so that "the user tapped Cancel" does not arrive
    /// as an opaque `-128`.
    package static func from(_ status: OSStatus) -> KeychainError {
        switch status {
        case errSecInteractionNotAllowed: .authenticationRequired
        case errSecAuthFailed:            .authenticationFailed
        case errSecUserCanceled:          .userCancelled
        default:                          .unhandledError(status: status)
        }
    }
}

// MARK: - Protocol

/// Abstraction over Keychain storage; enables in-memory test doubles.
///
/// Reading is two methods rather than one with a flag, because the two are
/// different operations with different costs. `string(forKey:)` cannot put a
/// prompt on screen; `string(forKey:authenticationReason:)` can, and blocks
/// until the user answers.
package protocol KeychainStoring: Sendable {

    /// Reads an item that needs no authentication.
    ///
    /// - Returns: `nil` when there is no such item.
    /// - Throws: `KeychainError.authenticationRequired` when the item exists
    ///   but is gated. It does **not** prompt.
    func string(forKey key: String) throws -> String?

    /// Reads an item, satisfying its gate if it has one.
    ///
    /// Blocks the calling thread for as long as the system prompt is on
    /// screen, which is user time rather than machine time. Never call it from
    /// the main actor; `TokenStore` hops off its own actor with
    /// `OffMainActor.run` before it does.
    ///
    /// - Parameter reason: What the prompt tells the user the app wants. Shown
    ///   verbatim, so it has to be localised prose rather than a key.
    func string(forKey key: String, authenticationReason reason: String) throws -> String?

    /// Whether an item exists, without reading it and without prompting.
    ///
    /// Answerable for a gated item too: the gate protects the data, not the
    /// fact that there is some.
    func contains(_ key: String) throws -> Bool

    /// Writes an item under `policy`, replacing whatever was there.
    ///
    /// There is no overload without a policy. See `KeychainAccessPolicy`.
    func set(_ value: String, forKey key: String, policy: KeychainAccessPolicy) throws

    func remove(forKey key: String) throws
    func removeAll() throws
}

// MARK: - KeychainWrapper

/// Thread-safe wrapper around iOS Keychain Services for secure string storage.
///
/// Entries are scoped to `service` (the app's bundle identifier by default).
/// What protects each one is the `KeychainAccessPolicy` its write names; there
/// is no house default, because the weakest policy is also the one a forgotten
/// argument would have picked.
///
/// ## Three decisions worth knowing about
///
/// **An unauthenticated read never prompts.** `string(forKey:)` attaches an
/// `LAContext` with `interactionNotAllowed`, so a gated item answers
/// `errSecInteractionNotAllowed` — surfaced as
/// `KeychainError.authenticationRequired` — instead of putting a Face ID sheet
/// in front of whatever happened to be running. Without it, a background
/// refresh that reached for the wrong key would block on a prompt nobody is
/// there to answer, on a screen the app does not own.
///
/// **A write is a delete followed by an add.** `SecItemUpdate` cannot change
/// an item's access control, and on a gated item it has to satisfy the
/// existing one first — so updating in place would both fail to apply a new
/// policy and prompt the user in the middle of a write. Deleting first makes
/// `set` mean the same thing whatever was there before.
///
/// **Errors that name a user action keep that name.** `errSecUserCanceled` and
/// `errSecAuthFailed` are answers, not faults: a caller has to be able to tell
/// "they said no" from "the Keychain is broken" without matching on integers.
package struct KeychainWrapper: KeychainStoring {
    package let service: String

    package init(service: String = Bundle.main.bundleIdentifier ?? "com.boilerplate.ios-swift") {
        self.service = service
    }

    // MARK: - Read

    package func string(forKey key: String) throws -> String? {
        try read(key: key, context: Self.silentContext())
    }

    package func string(forKey key: String, authenticationReason reason: String) throws -> String? {
        let context = LAContext()
        // `localizedReason` rather than `kSecUseOperationPrompt`, which has
        // been deprecated since iOS 14 and would fail the no-warnings gate.
        context.localizedReason = reason
        return try read(key: key, context: context)
    }

    package func contains(_ key: String) throws -> Bool {
        var query = baseQuery(for: key)
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext] = Self.silentContext()

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        case errSecInteractionNotAllowed:
            // A query that asks for no data should not need the gate opened,
            // but the answer is unambiguous if it ever does: something is
            // there to refuse.
            return true
        default:
            throw KeychainError.from(status)
        }
    }

    // MARK: - Write

    package func set(_ value: String, forKey key: String, policy: KeychainAccessPolicy) throws {
        // `String.data(using: .utf8)` cannot fail; `Data(_:)` says so in the type.
        let data = Data(value.utf8)

        var attributes = baseQuery(for: key)
        attributes[kSecValueData] = data

        if let accessControl = try policy.makeAccessControl() {
            attributes[kSecAttrAccessControl] = accessControl
        } else {
            attributes[kSecAttrAccessible] = policy.accessibility
        }

        // See the type's documentation: replace rather than update, so that a
        // change of policy actually applies and no write can prompt.
        try remove(forKey: key)

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.from(status) }
    }

    // MARK: - Delete

    package func remove(forKey key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.from(status)
        }
    }

    package func removeAll() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.from(status)
        }
    }

    // MARK: - Private

    private func baseQuery(for key: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
    }

    /// A context that refuses to show anything. Attached to every read that did
    /// not ask for a prompt, so a gated item fails instead of interrupting.
    private static func silentContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private func read(key: String, context: LAContext) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let string = String(data: data, encoding: .utf8)
            else { throw KeychainError.unexpectedData }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.from(status)
        }
    }
}

// MARK: - Double for previews & tests

/// Lock-protected in-memory `KeychainStoring` implementation.
///
/// Avoids a dependency on the Keychain daemon, which is unavailable in CI
/// and simulators without entitlements.
///
/// It lives in `Sources` rather than in the test target because
/// `AppContainer.preview` needs it: a preview graph that reached the real
/// Keychain would be writing to the developer's own login items. That is the
/// same place every other double in this package lives.
///
/// The storage lives inside the lock rather than beside it, which leaves this
/// class with one `let` stored property of `Sendable` type and so a conformance
/// the compiler checks instead of one it is told to assume.
///
/// ## It enforces the gate
///
/// It would be easier to keep a `[String: String]` and ignore the policy, and
/// that is precisely the double that certifies a bug: every test would pass
/// against a store where an unauthenticated read of a gated item succeeds, and
/// the app would be the first thing to discover it does not. So the policy is
/// stored with the value, `string(forKey:)` refuses a gated item, and
/// `stubbedAuthenticationOutcome` is how a test spells "the user cancelled"
/// without a device. It cannot reproduce the parts that are the daemon's — a
/// destroyed `biometryCurrentSet` item, a passcode removed mid-session — and
/// `docs/security.md` says which those are.
package final class InMemoryKeychain: KeychainStoring, Sendable {
    package init() {}

    private struct Entry: Sendable {
        var value: String
        var policy: KeychainAccessPolicy
    }

    private struct State: Sendable {
        var entries: [String: Entry] = [:]
        var authenticationOutcome: KeychainError?
        var gatedWriteFailure: KeychainError?
        var authenticationCount = 0
        var lastAuthenticationReason: String?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    // MARK: - Stubs

    /// Thrown by the next authenticated read of a gated item. `nil` is a user
    /// who authenticates successfully.
    package var stubbedAuthenticationOutcome: KeychainError? {
        get { state.withLock { $0.authenticationOutcome } }
        set { state.withLock { $0.authenticationOutcome = newValue } }
    }

    /// Thrown by any write that names a gated policy — the device with no
    /// passcode, which cannot hold one at all.
    package var stubbedGatedWriteFailure: KeychainError? {
        get { state.withLock { $0.gatedWriteFailure } }
        set { state.withLock { $0.gatedWriteFailure = newValue } }
    }

    // MARK: - Recordings

    /// How many times a gate has actually been presented. An ungated read does
    /// not count, because the real Keychain would not have asked either.
    package var authenticationCount: Int { state.withLock { $0.authenticationCount } }

    package var lastAuthenticationReason: String? { state.withLock { $0.lastAuthenticationReason } }

    /// The policy an item was written under. Not on `KeychainStoring`: the real
    /// Keychain cannot answer it, and a protocol requirement only the double
    /// can satisfy is a test asserting against itself.
    package func policy(forKey key: String) -> KeychainAccessPolicy? {
        state.withLock { $0.entries[key]?.policy }
    }

    // MARK: - KeychainStoring

    package func string(forKey key: String) throws -> String? {
        try state.withLock { current -> String? in
            guard let entry = current.entries[key] else { return nil }
            guard !entry.policy.requiresAuthentication else {
                throw KeychainError.authenticationRequired
            }
            return entry.value
        }
    }

    package func string(forKey key: String, authenticationReason reason: String) throws -> String? {
        try state.withLock { current -> String? in
            guard let entry = current.entries[key] else { return nil }
            guard entry.policy.requiresAuthentication else { return entry.value }

            current.authenticationCount += 1
            current.lastAuthenticationReason = reason
            if let outcome = current.authenticationOutcome { throw outcome }
            return entry.value
        }
    }

    package func contains(_ key: String) throws -> Bool {
        state.withLock { $0.entries[key] != nil }
    }

    package func set(_ value: String, forKey key: String, policy: KeychainAccessPolicy) throws {
        try state.withLock { current in
            if policy.requiresAuthentication, let failure = current.gatedWriteFailure {
                throw failure
            }
            current.entries[key] = Entry(value: value, policy: policy)
        }
    }

    package func remove(forKey key: String) throws {
        state.withLock { $0.entries[key] = nil }
    }

    package func removeAll() throws {
        state.withLock { $0.entries.removeAll() }
    }
}
