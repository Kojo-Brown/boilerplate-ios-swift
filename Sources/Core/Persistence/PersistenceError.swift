import Foundation

package enum PersistenceError: LocalizedError, Equatable {
    case userNotFound

    package var errorDescription: String? {
        "No user record found in local storage."
    }
}
