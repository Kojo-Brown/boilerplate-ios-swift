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

    /// How long a wait here may last before it gives up.
    ///
    /// Every wait in this type is bounded. An unbounded one that is never
    /// satisfied does not fail — it hangs, and `-test-timeouts-enabled` kills it
    /// two minutes later with a timeout that names nothing. Giving up instead
    /// lets the assertion that follows report which expectation was not met.
    private static let waitLimit = Duration.seconds(10)

    private let outcomes: [ScriptedPageOutcome]
    private let parks: Bool
    private var released: Set<Int> = []

    private(set) var requests: [Request] = []

    /// Calls that got as far as consulting the script, whether they went on to
    /// answer or to throw.
    private(set) var answered = 0

    /// - Parameter parking: Holds every call at ``park(at:)`` until ``release(_:)``
    ///   lets it through, so a test can decide the order two in-flight loads
    ///   finish in rather than race them.
    init(_ outcomes: [ScriptedPageOutcome], parking: Bool = false) {
        self.outcomes = outcomes
        parks = parking
    }

    var requestCount: Int { requests.count }

    /// Lets call number `index` proceed. Safe to call before the call exists —
    /// ``park(at:)`` checks the release set on arrival.
    func release(_ index: Int) {
        released.insert(index)
    }

    /// Holds a call until it is released, **whether or not its task has been
    /// cancelled**.
    ///
    /// That is the whole point of it, and it is why this is `Task.yield()` rather
    /// than `TaskGate`'s sleep. A cancelled `Task.sleep` throws *without
    /// suspending*, so a loop around it spins on the actor's executor and no
    /// other call — including the `release` it is waiting for — can ever get in.
    /// `TaskGate` documents that hazard and confines it to a caller that opens
    /// the gate on the line after it cancels; the superseded-page test cannot,
    /// because it has a whole refresh to complete in between.
    ///
    /// `Task.yield()` neither throws nor checks cancellation, and it always
    /// suspends, so the actor is released on every turn of the loop.
    private func park(at index: Int) async {
        let deadline = ContinuousClock.now + Self.waitLimit
        while !released.contains(index), ContinuousClock.now < deadline {
            await Task.yield()
        }
    }

    func loadPage(after cursor: PageCursor?, limit: Int) async throws -> PageSlice<PagedItem> {
        let index = requests.count
        requests.append(Request(cursor: cursor?.rawValue, limit: limit))

        if parks {
            await park(at: index)
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
    /// Yields rather than sleeps for the reason ``park(at:)`` gives, and gives up
    /// at ``waitLimit`` rather than hanging: the caller's next assertion is a
    /// better failure report than a killed test.
    func waitForRequests(_ count: Int) async {
        let deadline = ContinuousClock.now + Self.waitLimit
        while requests.count < count, ContinuousClock.now < deadline {
            await Task.yield()
        }
    }

    /// Waits until `count` calls have got as far as the script.
    func waitForAnswers(_ count: Int) async {
        let deadline = ContinuousClock.now + Self.waitLimit
        while answered < count, ContinuousClock.now < deadline {
            await Task.yield()
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
