import Foundation

// MARK: - URLSession API client

/// Concrete `APIClient` backed by `URLSession`.
///
/// - Attaches `Authorization: Bearer <token>` to every authenticated request.
/// - On a 401 response, calls `/auth/refresh` once via `TokenStore.refreshIfNeeded`,
///   then retries the original request with the new token.
/// - Concurrent 401s coalesce to a single refresh via actor-isolated `TokenStore`.
struct URLSessionAPIClient: APIClient {
    let baseURL: URL
    private let session: URLSession
    private let tokenStore: TokenStore
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    static let shared = URLSessionAPIClient(
        baseURL: URL(string: "https://api.example.com/v1")!
    )

    init(
        baseURL: URL,
        session: URLSession = .shared,
        tokenStore: TokenStore = .shared,
        decoder: JSONDecoder = .apiDecoder,
        encoder: JSONEncoder = .apiEncoder
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenStore = tokenStore
        self.decoder = decoder
        self.encoder = encoder
    }

    // MARK: - APIClient

    func send<Response: Decodable & Sendable>(_ endpoint: APIEndpoint) async throws -> Response {
        let data = try await performRequest(endpoint)
        do {
            return try decoder.decode(Response.self, from: data)
        } catch let error as DecodingError {
            throw APIError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Request execution

    private func performRequest(_ endpoint: APIEndpoint) async throws -> Data {
        let request = try await buildRequest(endpoint)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw APIError.networkUnavailable(urlError)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        // On 401, refresh tokens and retry once.
        if http.statusCode == 401 && endpoint.requiresAuth {
            let newToken = try await refreshTokens()
            var retryRequest = request
            retryRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")

            let (retryData, retryResponse): (Data, URLResponse)
            do {
                (retryData, retryResponse) = try await session.data(for: retryRequest)
            } catch let urlError as URLError {
                throw APIError.networkUnavailable(urlError)
            }
            guard let retryHTTP = retryResponse as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            return try validate(retryData, response: retryHTTP)
        }

        return try validate(data, response: http)
    }

    // MARK: - Request building

    private func buildRequest(_ endpoint: APIEndpoint) async throws -> URLRequest {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(endpoint.path),
            resolvingAgainstBaseURL: false
        )
        if !endpoint.queryItems.isEmpty {
            components?.queryItems = endpoint.queryItems
        }
        guard let url = components?.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body = endpoint.body {
            request.httpBody = body
        }
        if endpoint.requiresAuth {
            let token = try await tokenStore.currentToken()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // MARK: - Token refresh

    private func refreshTokens() async throws -> String {
        try await tokenStore.refreshIfNeeded { [self] refreshToken in
            var request = URLRequest(url: baseURL.appendingPathComponent("/auth/refresh"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(TokenRefreshRequest(refreshToken: refreshToken))

            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: request)
            } catch let urlError as URLError {
                throw APIError.networkUnavailable(urlError)
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw APIError.tokenRefreshFailed
            }
            return try decoder.decode(TokenPair.self, from: data)
        }
    }

    // MARK: - Status validation

    private func validate(_ data: Data, response: HTTPURLResponse) throws -> Data {
        switch response.statusCode {
        case 200...299:
            return data
        case 401:
            throw APIError.unauthorized
        default:
            throw APIError.httpError(statusCode: response.statusCode, data: data)
        }
    }
}
