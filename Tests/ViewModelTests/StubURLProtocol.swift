import Foundation
import os

// MARK: - A URLSession that never leaves the process

/// Answers every request from a scripted list and records what it was asked.
///
/// `MockAPIClient` is the double this suite reaches for almost everywhere, and
/// it is the wrong one here: it substitutes the client, so everything
/// `URLSessionAPIClient` does — building the `URLRequest`, setting headers,
/// re-sending on a 401 — is exactly what it replaces. An assertion about a
/// header on the wire has to be made against a real `URLSession` carrying a
/// real `URLRequest`, which is what a `URLProtocol` gives without a server.
///
/// ## Why the state is static, and why that costs a `.serialized` suite
///
/// `URLSession` instantiates the protocol class itself, per request, so there
/// is no instance for a test to hold and configure — the script and the log
/// have to be reachable from a type that is constructed out of reach. That is a
/// shared mutable global, so the one suite that uses it is `.serialized`;
/// without that, Swift Testing's default parallelism would let two tests script
/// the same queue.
///
/// The lock is `OSAllocatedUnfairLock` rather than `nonisolated(unsafe)`, like
/// every other piece of shared state in this package: `startLoading()` runs on
/// a `URLSession` delegate thread, so the race is real rather than theoretical.
///
/// Not `final`, unlike every other double here. `URLProtocol`'s entry points are
/// `class func`s that a subclass overrides, and `static_over_final_class` reads
/// a `class func` in a `final class` as one that should have been `static` —
/// which these cannot be, because they override.
class StubURLProtocol: URLProtocol {

    /// One scripted answer.
    struct Exchange: Sendable {
        let statusCode: Int
        let body: Data

        init(statusCode: Int, body: Data = Data()) {
            self.statusCode = statusCode
            self.body = body
        }

        /// A 200 carrying `json`.
        static func success(_ json: String) -> Exchange {
            Exchange(statusCode: 200, body: Data(json.utf8))
        }

        /// A 401 with an empty body — what an expired access token looks like.
        static let unauthorized = Exchange(statusCode: 401)
    }

    private struct State: Sendable {
        var scripted: [Exchange] = []
        var recorded: [URLRequest] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Arms the stub with the answers it will give, oldest first, and clears
    /// anything a previous test recorded.
    static func script(_ exchanges: [Exchange]) {
        state.withLock { $0 = State(scripted: exchanges, recorded: []) }
    }

    /// Every request the stub was handed, in order.
    static var recordedRequests: [URLRequest] {
        state.withLock { $0.recorded }
    }

    /// The value of `header` on each recorded request, `nil` where absent.
    static func recordedValues(of header: String) -> [String?] {
        recordedRequests.map { $0.value(forHTTPHeaderField: header) }
    }

    /// The session that routes everything through this stub.
    ///
    /// Ephemeral, so nothing is written to a URL cache between tests, and the
    /// stub is installed on the configuration rather than through
    /// `URLProtocol.registerClass` so it cannot affect a session some other
    /// suite built.
    ///
    /// One session for the whole suite rather than one per test. A `URLSession`
    /// holds its own delegate queue and retains *itself* until it is
    /// invalidated, and a `@Suite` struct has no teardown hook to invalidate one
    /// in — so a per-test session is a per-test leak, in a bundle that runs its
    /// suites in parallel on a three-core runner. Sharing is safe here for the
    /// same reason the script can be static: the one suite that uses it is
    /// `.serialized`, so no two of its tests are ever in flight together.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }()

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let next = StubURLProtocol.state.withLock { current -> Exchange? in
            current.recorded.append(request)
            return current.scripted.isEmpty ? nil : current.scripted.removeFirst()
        }

        guard let next else {
            // An unscripted request is a test bug, not a network condition, so
            // it fails as one rather than as a `URLError` the code under test
            // would classify and possibly retry.
            client?.urlProtocol(
                self,
                didFailWithError: StubExhaustedError(url: request.url?.absoluteString ?? "?")
            )
            return
        }

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: next.statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: next.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Thrown when the code under test made more requests than the test scripted.
struct StubExhaustedError: Error, CustomStringConvertible {
    let url: String

    var description: String { "StubURLProtocol had no scripted answer for \(url)" }
}
