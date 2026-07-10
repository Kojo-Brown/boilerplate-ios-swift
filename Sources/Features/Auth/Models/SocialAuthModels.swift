import Foundation

// Credential payload returned by a social sign-in provider before backend exchange.
enum SocialAuthCredential: Sendable {
    case apple(
        identityToken: String,
        authorizationCode: String,
        nonce: String,
        fullName: PersonNameComponents?
    )
    case google(idToken: String, accessToken: String)
}

enum SocialAuthError: LocalizedError, Sendable, Equatable {
    case invalidCredential
    case userCancelled
    case notConfigured
    case tokenExchangeFailed

    var errorDescription: String? {
        switch self {
        case .invalidCredential: "The sign-in credential was invalid."
        case .userCancelled: "Sign-in was cancelled."
        case .notConfigured: "This sign-in method is not configured."
        case .tokenExchangeFailed: "Failed to exchange the social token for app credentials."
        }
    }
}
