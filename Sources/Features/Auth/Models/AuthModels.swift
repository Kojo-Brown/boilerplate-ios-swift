import Foundation

struct LoginRequest: Encodable, Sendable {
    let email: String
    let password: String
}

struct LoginResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    let user: User
}

struct UpdateProfileRequest: Encodable, Sendable {
    let name: String
}
