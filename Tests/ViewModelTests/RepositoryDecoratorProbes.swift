import Foundation
import os
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Features
@testable import Networking

// MARK: - Doubles shared by the decorator suites

/// What one scripted call produced.
///
/// A `Result` cannot be returned out of `withLock`, whose return type must be
/// `Sendable` and whose `Failure` would be a bare `any Error`. Constraining the
/// failure to `any Error & Sendable` — which is what the scripts hold anyway —
/// makes this enum `Sendable` and keeps the throw outside the lock.
enum ScriptedOutcome<Value: Sendable>: Sendable {
    case success(Value)
    case failure(any Error & Sendable)
}

/// A repository whose failures are scripted per operation and whose calls are
/// counted.
///
/// `ScriptedUserRepository` in `SyncStrategyTests` is the nearest thing and is
/// not enough: these suites need a *sequence* of failures rather than one
/// sticky error, because everything a retry policy does is about what happens
/// on the second call. `beforeFetch` is the other addition — it is where a test
/// puts a sleep to hold a read open, or a clock advance to spend a freshness
/// window without spending any wall-clock time.
///
/// Nonisolated with its state in a lock, like the live repository and unlike
/// `MockUserRepository` — `docs/solid.md` finding 5's recommendation.
final class ScriptedRepository: UserRepository {

    private struct State: Sendable {
        var user = User(email: "decorated@example.invalid", name: "Decorated User")
        var fetchFailures: [any Error & Sendable] = []
        var updateFailures: [any Error & Sendable] = []
        var deleteFailures: [any Error & Sendable] = []
        var fetchCount = 0
        var updateCount = 0
        var deleteCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let beforeFetch: @Sendable () async -> Void

    /// - Parameter beforeFetch: Runs at the start of every `fetchCurrentUser`,
    ///   before the call is counted.
    init(beforeFetch: @escaping @Sendable () async -> Void = {}) {
        self.beforeFetch = beforeFetch
    }

    var user: User {
        get { state.withLock { $0.user } }
        set { state.withLock { $0.user = newValue } }
    }

    /// Failures handed to the next calls, one each, oldest first. An empty
    /// script succeeds.
    var fetchFailures: [any Error & Sendable] {
        get { state.withLock { $0.fetchFailures } }
        set { state.withLock { $0.fetchFailures = newValue } }
    }

    var updateFailures: [any Error & Sendable] {
        get { state.withLock { $0.updateFailures } }
        set { state.withLock { $0.updateFailures = newValue } }
    }

    var deleteFailures: [any Error & Sendable] {
        get { state.withLock { $0.deleteFailures } }
        set { state.withLock { $0.deleteFailures = newValue } }
    }

    var fetchCount: Int { state.withLock { $0.fetchCount } }
    var updateCount: Int { state.withLock { $0.updateCount } }
    var deleteCount: Int { state.withLock { $0.deleteCount } }

    func fetchCurrentUser() async throws -> User {
        await beforeFetch()
        let outcome = state.withLock { current -> ScriptedOutcome<User> in
            current.fetchCount += 1
            if current.fetchFailures.isEmpty {
                return .success(current.user)
            }
            return .failure(current.fetchFailures.removeFirst())
        }
        return try ScriptedRepository.value(of: outcome)
    }

    func updateProfile(name: String) async throws -> User {
        let outcome = state.withLock { current -> ScriptedOutcome<User> in
            current.updateCount += 1
            if current.updateFailures.isEmpty {
                current.user = current.user.with(name: .set(name))
                return .success(current.user)
            }
            return .failure(current.updateFailures.removeFirst())
        }
        return try ScriptedRepository.value(of: outcome)
    }

    func deleteAccount() async throws {
        let outcome = state.withLock { current -> ScriptedOutcome<Bool> in
            current.deleteCount += 1
            if current.deleteFailures.isEmpty {
                return .success(true)
            }
            return .failure(current.deleteFailures.removeFirst())
        }
        _ = try ScriptedRepository.value(of: outcome)
    }

    private static func value<Value: Sendable>(of outcome: ScriptedOutcome<Value>) throws -> Value {
        switch outcome {
        case let .success(value):
            return value
        case let .failure(error):
            throw error
        }
    }
}

/// A monotonic instant the test moves by hand.
///
/// The same shape as `SyncStrategyTests`' clock, for the same reason: a
/// freshness window asserted with `Task.sleep` costs the suite the window, and
/// a duration asserted against the system clock can only ever be a range.
struct ManualClock: Sendable {

    private let instant = OSAllocatedUnfairLock<ContinuousClock.Instant>(
        initialState: ContinuousClock.now
    )

    var now: @Sendable () -> ContinuousClock.Instant {
        let instant = self.instant
        return { instant.withLock { $0 } }
    }

    func advance(by duration: Duration) {
        instant.withLock { $0 = $0.advanced(by: duration) }
    }
}

// MARK: - Shared fixtures

/// A transport failure the server never saw.
let neverDelivered = APIError.networkUnavailable(URLError(.notConnectedToInternet))

/// A transport failure that says nothing about whether the request arrived.
let deliveryUnknown = APIError.networkUnavailable(URLError(.timedOut))

/// A failure the server answered with, so it certainly received the request.
let serverAnswered = APIError.httpError(statusCode: 503, data: Data())

/// The decorator chain from `repository` inwards, outermost first.
///
/// This is what `UserRepositoryDecorator.base` is a requirement for: without it
/// the only assertable fact about the composition would be its outermost type,
/// and every reordering underneath would be invisible.
func chainNames(of repository: any UserRepository) -> [String] {
    var names = [String(describing: type(of: repository))]
    var current: any UserRepository = repository
    while let decorator = current as? any UserRepositoryDecorator {
        current = decorator.base
        names.append(String(describing: type(of: current)))
    }
    return names
}
