import Foundation
@testable import Core
@testable import Networking

// MARK: - Items

/// The row type the pagination suites page through.
///
/// `Decodable` as well as `Identifiable`, because the same type has to arrive
/// two ways: constructed directly for `ScriptedPageSource`, and decoded out of a
/// `CursorPage` envelope for `APICursorPageSource`.
struct PagedItem: Identifiable, Sendable, Equatable, Decodable {
    let id: Int

    static func range(_ ids: ClosedRange<Int>) -> [PagedItem] {
        ids.map { PagedItem(id: $0) }
    }
}

/// A failure with a message a test can assert on.
///
/// `LocalizedError` rather than a bare `Error`: `CursorPaginator` reduces a
/// caught error to `error.localizedDescription`, and a bare `Error` would arrive
/// as Foundation's generic "operation couldn't be completed" string, which would
/// make the phase assertions test nothing.
struct ScriptedPageFailure: LocalizedError, Equatable {
    let reason: String

    var errorDescription: String? { reason }
}

/// One scripted answer from ``ScriptedPageSource``.
enum ScriptedPageOutcome: Sendable {
    case page(items: [PagedItem], next: String?)
    case failure(ScriptedPageFailure)
}

// MARK: - A page source a test writes in advance

/// A `CursorPageSource` whose answers are written in advance and whose requests
/// are recorded.
///
/// Answers are indexed by *call number* rather than taken off the front of a
/// queue. That distinction is the whole reason the superseded-page test can be
/// written at all: two loads are in flight at once there, and with a queue the
/// page each of them received would depend on which one reached the front
/// first — which is the scheduling detail the test exists to be independent of.
actor ScriptedPageSource: CursorPageSource {

    struct Request: Equatable, Sendable {
        let cursor: String?
        let limit: Int
    }

    private let outcomes: [ScriptedPageOutcome]
    private let gate: TaskGate?
    private let ignoresCancellation: Bool

    private(set) var requests: [Request] = []

    /// Calls that got past the gate, whether they went on to answer or to throw.
    private(set) var answered = 0

    /// - Parameter ignoresCancellation: Makes a parked call finish even after its
    ///   task is cancelled, so a test can produce the one thing cancellation does
    ///   not prevent — a result arriving for a load nobody is waiting for.
    init(_ outcomes: [ScriptedPageOutcome], gate: TaskGate? = nil, ignoresCancellation: Bool = false) {
        self.outcomes = outcomes
        self.gate = gate
        self.ignoresCancellation = ignoresCancellation
    }

    var requestCount: Int { requests.count }

    func loadPage(after cursor: PageCursor?, limit: Int) async throws -> PageSlice<PagedItem> {
        let index = requests.count
        requests.append(Request(cursor: cursor?.rawValue, limit: limit))

        if let gate {
            if ignoresCancellation {
                await gate.waitForOpeningIgnoringCancellation(at: index)
            } else {
                try await gate.waitForOpening(at: index)
            }
        }

        answered += 1

        guard index < outcomes.count else {
            throw ScriptedPageFailure(reason: "the script has no answer for call \(index)")
        }

        switch outcomes[index] {
        case let .page(items, next):
            return PageSlice(items: items, nextCursor: next.flatMap { PageCursor(rawValue: $0) })
        case let .failure(error):
            throw error
        }
    }

    /// Waits until `count` requests have been *made*, so a test can order itself
    /// against work it started but is not holding.
    ///
    /// Polls for the reason `TaskGate` does: the actor is released at every
    /// sleep, which is what lets the calls being waited for get in.
    func waitForRequests(_ count: Int) async {
        while requests.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Waits until `count` calls have got past the gate.
    func waitForAnswers(_ count: Int) async {
        while answered < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

// MARK: - What the HTTP source asked for

/// Records the endpoints a `MockAPIClient` was handed.
///
/// An actor rather than an array, because `MockAPIClient.Handler` is `@Sendable`
/// and a captured array would be shared mutable state.
actor PageEndpointLog {
    private(set) var endpoints: [APIEndpoint] = []

    func record(_ endpoint: APIEndpoint) {
        endpoints.append(endpoint)
    }
}
