import Foundation
import os

/// Publish/subscribe event bus backed by `AsyncStream`.
///
/// Each call to `events` returns a new `AsyncStream<AppEvent>` that yields
/// events emitted after subscription. Cancelling the consuming `Task` removes
/// the subscriber automatically via `onTermination`.
///
/// Thread-safe via `OSAllocatedUnfairLock`; `emit` is safe to call from any
/// actor or thread.
///
/// Usage:
/// ```swift
/// // Subscribe — inside a Task / .task modifier
/// for await event in EventBus.shared.events {
///     switch event {
///     case .userLoggedOut: handleLogout()
///     default: break
///     }
/// }
///
/// // Publish — from any context
/// EventBus.shared.emit(.userLoggedOut)
/// ```
///
/// The conformance is checked, not asserted. An `NSLock` beside a
/// `private var` cannot be: the compiler has no way to see that the lock guards
/// the dictionary, so that shape needs `@unchecked Sendable` — a promise the
/// compiler takes on trust and stops re-verifying, including after an edit that
/// adds a stored property nothing guards. Putting the dictionary *inside*
/// `OSAllocatedUnfairLock` leaves the class with only `let` stored properties of
/// `Sendable` type, which the compiler can check on its own. It is iOS 16+, so
/// it fits this package's iOS 17 floor where `Synchronization.Mutex` (iOS 18)
/// would not.
final class EventBus: Sendable {
    static let shared = EventBus()

    private let continuations = OSAllocatedUnfairLock(
        initialState: [UUID: AsyncStream<AppEvent>.Continuation]()
    )

    init() {}

    /// Returns a new stream that receives all events emitted after this call.
    var events: AsyncStream<AppEvent> {
        AsyncStream { continuation in
            let id = UUID()
            continuations.withLock { $0[id] = continuation }
            // Capture the lock itself rather than `self`. `onTermination` is a
            // `@Sendable` closure that outlives this call, and the deregistration
            // only ever needs the storage — capturing the bus would either retain
            // it for the lifetime of every subscription or, weakly, leave the
            // entry behind whenever the bus went away first.
            continuation.onTermination = { [continuations = self.continuations] _ in
                // `removeValue` returns the entry it removed, which makes
                // `withLock`'s generic result non-Void; discard it explicitly.
                continuations.withLock { _ = $0.removeValue(forKey: id) }
            }
        }
    }

    /// Broadcasts `event` to all current subscribers. Safe to call from any context.
    func emit(_ event: AppEvent) {
        // Yield outside the critical section: `yield` runs the consumer's
        // buffering policy, and holding the lock across it would invite a
        // re-entrant `emit` from a subscriber to deadlock on a non-recursive lock.
        let snapshot = continuations.withLock { Array($0.values) }
        snapshot.forEach { $0.yield(event) }
    }
}
