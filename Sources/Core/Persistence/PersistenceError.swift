import Foundation

enum PersistenceError: LocalizedError, Equatable {
    case userNotFound

    var errorDescription: String? {
        "No user record found in local storage."
    }
}
