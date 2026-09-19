import Foundation

package enum APIError: LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case unauthorized
    case tokenRefreshFailed
    case httpError(statusCode: Int, data: Data)
    case decodingFailed(String)
    case networkUnavailable(URLError)

    package var errorDescription: String? {
        switch self {
        case .invalidURL:
            CoreStrings.API.invalidURL.string
        case .invalidResponse:
            CoreStrings.API.invalidResponse.string
        case .unauthorized:
            CoreStrings.API.unauthorized.string
        case .tokenRefreshFailed:
            CoreStrings.API.tokenRefreshFailed.string
        case let .httpError(statusCode, _):
            CoreStrings.API.httpStatus(statusCode).string
        case let .decodingFailed(message):
            CoreStrings.API.decodingFailed(message).string
        case let .networkUnavailable(error):
            // `URLError` is already localised by Foundation, in the reader's
            // language, and with more detail than a catalog entry here could
            // carry. Re-wording it would be a worse sentence in fewer
            // languages.
            error.localizedDescription
        }
    }
}
