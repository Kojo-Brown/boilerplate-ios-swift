import Foundation

enum APIError: LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case unauthorized
    case tokenRefreshFailed
    case httpError(statusCode: Int, data: Data)
    case decodingFailed(String)
    case networkUnavailable(URLError)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The request URL is invalid."
        case .invalidResponse:
            "The server returned an unexpected response."
        case .unauthorized:
            "You are not authorised. Please sign in again."
        case .tokenRefreshFailed:
            "Your session has expired. Please sign in again."
        case let .httpError(statusCode, _):
            "Request failed with status \(statusCode)."
        case let .decodingFailed(message):
            "Failed to decode response: \(message)"
        case let .networkUnavailable(error):
            error.localizedDescription
        }
    }
}
