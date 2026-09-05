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

    /// Someone waiting for a counter to reach `threshold`.
    private struct Watcher {
        let threshold: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let outcomes: [ScriptedPageOutcome]
    private let parks: Bool

    private var released: Set<Int> = []
    private var parked: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var requestWatchers: [Watcher] = []
    private var answerWatchers: [Watcher] = []

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
        for continuation in parked.removeValue(forKey: index) ?? [] {
            continuation.resume()
        }
    }

    /// Holds a call until it is released, **whether or not its task has been
    /// cancelled**.
    ///
    /// Surviving cancellation is the whole point: the superseded-page test needs
    /// a page that arrives for a load nobody is waiting for, and there is no
    /// other way to produce one. `CheckedContinuation` gives it for free — it
    /// neither throws nor consults cancellation — where the two obvious
    /// alternatives cost more than they look:
    ///
    /// * `TaskGate`'s `Task.sleep` loop throws the moment the task is cancelled,
    ///   so a cancelled call would not park at all. Its
    ///   `waitForOpeningIgnoringCancellation` swallows that and spins instead,
    ///   which its own doc confines to a caller that opens the gate on the line
    ///   after it cancels. This suite cannot be that caller: it has a whole
    ///   refresh round trip in between.
    /// * A `Task.yield()` loop parks correctly and costs a core to do it. That is
    ///   what the first version of this file did, and on a three-core runner it
    ///   starved an unrelated `@MainActor` XCTest until it blew its two-minute
    ///   execution allowance — a test in a suite this branch does not touch,
    ///   failing twice while `main` stayed green.
    ///
    /// A continuation costs nothing while parked, so the runner is free for the
    /// tests running beside this one.
    ///
    /// There is no lost wakeup: the release check and the enrolment below both
    /// run on this actor with no `await` between them, so a `release(_:)` cannot
    /// land in the gap.
    private func park(at index: Int) async {
        guard !released.contains(index) else { return }
        await withCheckedContinuation { continuation in
            parked[index, default: []].append(continuation)
        }
    }

    func loadPage(after cursor: PageCursor?, limit: Int) async throws -> PageSlice<PagedItem> {
        let index = requests.count
        requests.append(Request(cursor: cursor?.rawValue, limit: limit))
        wakeRequestWatchers()

        if parks {
            await park(at: index)
        }

        answered += 1
        wakeAnswerWatchers()

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
    /// Continuation-based for the reason ``park(at:)`` gives, and unbounded on
    /// purpose. A deadline here would be a spin or a timer for a wait that is
    /// satisfied by construction — every parking test releases every index it
    /// parks — and the bound the first version carried is exactly what cost a
    /// core. A script that genuinely never satisfies a wait is a bug in the
    /// script, and one the suite timeout reports well enough.
    func waitForRequests(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { continuation in
            requestWatchers.append(Watcher(threshold: count, continuation: continuation))
        }
    }

    /// Waits until `count` calls have got as far as the script.
    func waitForAnswers(_ count: Int) async {
        guard answered < count else { return }
        await withCheckedContinuation { continuation in
            answerWatchers.append(Watcher(threshold: count, continuation: continuation))
        }
    }

    private func wakeRequestWatchers() {
        let reached = requests.count
        let ready = requestWatchers.filter { $0.threshold <= reached }
        requestWatchers.removeAll { $0.threshold <= reached }
        for watcher in ready { watcher.continuation.resume() }
    }

    private func wakeAnswerWatchers() {
        let reached = answered
        let ready = answerWatchers.filter { $0.threshold <= reached }
        answerWatchers.removeAll { $0.threshold <= reached }
        for watcher in ready { watcher.continuation.resume() }
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
