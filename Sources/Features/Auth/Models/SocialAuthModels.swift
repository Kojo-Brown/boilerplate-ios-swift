import Core
import Foundation

// Credential payload returned by a social sign-in provider before backend exchange.
package enum SocialAuthCredential: Sendable {
    case apple(
        identityToken: String,
        authorizationCode: String,
        nonce: String,
        fullName: PersonNameComponents?
    )
    case google(idToken: String, accessToken: String)
}

package enum SocialAuthError: LocalizedError, Sendable, Equatable {
    case invalidCredential
    case userCancelled
    case notConfigured
    case tokenExchangeFailed

    package var errorDescription: String? {
        switch self {
        case .invalidCredential: FeatureStrings.SocialError.invalidCredential.string
        case .userCancelled: FeatureStrings.SocialError.userCancelled.string
        case .notConfigured: FeatureStrings.SocialError.notConfigured.string
        case .tokenExchangeFailed: FeatureStrings.SocialError.tokenExchangeFailed.string
        }
    }
}
