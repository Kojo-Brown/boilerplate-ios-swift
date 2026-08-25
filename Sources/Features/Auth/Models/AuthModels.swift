import Core
import Foundation

package struct LoginRequest: Encodable, Sendable {
    package let email: String
    package let password: String

    package enum CodingKeys: String, CodingKey {
        case email
        case password
    }
}

package struct LoginResponse: Decodable, Sendable {
    package let accessToken: String
    package let refreshToken: String
    package let user: User

    package enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case user
    }
}

package struct SocialLoginRequest: Encodable, Sendable {
    package let provider: String
    package let identityToken: String
    package let authorizationCode: String?
    package let nonce: String?
    package let givenName: String?
    package let familyName: String?

    package enum CodingKeys: String, CodingKey {
        case provider
        case identityToken = "identity_token"
        case authorizationCode = "authorization_code"
        case nonce
        case givenName = "given_name"
        case familyName = "family_name"
    }
}
