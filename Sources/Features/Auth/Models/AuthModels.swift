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
