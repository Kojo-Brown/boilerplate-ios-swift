import Foundation

package enum PersistenceError: LocalizedError, Equatable {
    case userNotFound

    package var errorDescription: String? {
        CoreStrings.Persistence.userNotFound.string
    }
}
