import Foundation

/// Publish/subscribe event bus backed by `AsyncStream`.
///
/// Each call to `events` returns a new `AsyncStream<AppEvent>` that yields
/// events emitted after subscription. Cancelling the consuming `Task` removes
/// the subscriber automatically via `onTermination`.
///
/// Thread-safe via `NSLock`; `emit` is safe to call from any actor or thread.
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
final class EventBus: @unchecked Sendable {
    static let shared = EventBus()

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<AppEvent>.Continuation] = [:]

    init() {}

    /// Returns a new stream that receives all events emitted after this call.
    var events: AsyncStream<AppEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.withLock { continuations.removeValue(forKey: id) }
            }
        }
    }

    /// Broadcasts `event` to all current subscribers. Safe to call from any context.
    func emit(_ event: AppEvent) {
        let snapshot = lock.withLock { Array(continuations.values) }
        snapshot.forEach { $0.yield(event) }
    }
}
