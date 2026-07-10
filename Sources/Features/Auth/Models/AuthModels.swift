import Foundation

struct LoginRequest: Encodable, Sendable {
    let email: String
    let password: String

    enum CodingKeys: String, CodingKey {
        case email
        case password
    }
}

struct LoginResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    let user: User

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case user
    }
}

struct UpdateProfileRequest: Encodable, Sendable {
    let name: String

    enum CodingKeys: String, CodingKey {
        case name
    }
}

struct SocialLoginRequest: Encodable, Sendable {
    let provider: String
    let identityToken: String
    let authorizationCode: String?
    let nonce: String?
    let givenName: String?
    let familyName: String?

    enum CodingKeys: String, CodingKey {
        case provider
        case identityToken = "identity_token"
        case authorizationCode = "authorization_code"
        case nonce
        case givenName = "given_name"
        case familyName = "family_name"
    }
}
