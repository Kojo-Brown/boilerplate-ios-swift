import Foundation
import Security

// MARK: - Keychain errors

enum KeychainError: Error, Sendable, Equatable {
    case unexpectedData
    case unhandledError(status: OSStatus)
}

// MARK: - Protocol

/// Abstraction over Keychain storage; enables in-memory test doubles.
protocol KeychainStoring: Sendable {
    func string(forKey key: String) throws -> String?
    func set(_ value: String, forKey key: String) throws
    func remove(forKey key: String) throws
    func removeAll() throws
}

// MARK: - KeychainWrapper

/// Thread-safe wrapper around iOS Keychain Services for secure string storage.
///
/// Entries are scoped to `service` (the app's bundle identifier by default)
/// and use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so tokens
/// survive backgrounding but cannot be restored from a device backup.
struct KeychainWrapper: KeychainStoring {
    let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "com.boilerplate.ios-swift") {
        self.service = service
    }

    // MARK: - Read

    func string(forKey key: String) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
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
            throw KeychainError.unhandledError(status: status)
        }
    }

    // MARK: - Write

    func set(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }

        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let insertStatus = SecItemAdd(attributes as CFDictionary, nil)
        if insertStatus == errSecDuplicateItem {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: key,
            ]
            let update: [CFString: Any] = [kSecValueData: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unhandledError(status: updateStatus)
            }
        } else if insertStatus != errSecSuccess {
            throw KeychainError.unhandledError(status: insertStatus)
        }
    }

    // MARK: - Delete

    func remove(forKey key: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    func removeAll() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
    }
}
