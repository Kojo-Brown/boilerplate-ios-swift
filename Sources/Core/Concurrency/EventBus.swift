import Foundation
import os

// MARK: - Protocols

/// Announcing that something happened.
///
/// Split from `EventSubscribing` rather than vended as one protocol, because
/// nothing in this app does both. A view model announces and never listens;
/// `SessionObserver` listens and never announces. Handing each of them the half
/// it needs makes the other half a compile error instead of a convention — the
/// same reasoning `TokenStoring` records for keeping its four requirements down
/// to the ones its callers use.
protocol EventPublishing: Sendable {
    /// Delivers `event` to every subscriber registered for `Event`, and to no
    /// other subscriber. Safe to call from any task, actor or thread.
    func publish<Event: AppEvent>(_ event: Event)
}

/// Listening for one kind of event.
protocol EventSubscribing: Sendable {
    /// A new stream carrying every `Event` published from the moment this call
    /// returns.
    ///
    /// - Parameters:
    ///   - type: The one event type this subscription receives.
    ///   - bufferingPolicy: What becomes of events the consumer has not taken
    ///     yet. `events(of:)` supplies the default and says why it is what it is.
    func events<Event: AppEvent>(
        of type: Event.Type,
        bufferingPolicy: AsyncStream<Event>.Continuation.BufferingPolicy
    ) -> AsyncStream<Event>
}

extension EventSubscribing {

    /// Subscribes with the default policy, `.unbounded`.
    ///
    /// `DelegateStream` argues at length that `.unbounded` is not a default, and
    /// it is right about the producer *it* bridges: a capture device yields at
    /// whatever rate the hardware runs and cannot be told to stop, so the only
    /// question is where the backlog goes. This producer is the opposite. Every
    /// event on this bus is published because a person tapped something — a
    /// handful in a session, never a burst — and each one carries a consequence
    /// a subscriber must not miss. `.bufferingNewest(n)` would trade a leak that
    /// cannot happen for a `UserSignedOut` silently discarded, which leaves the
    /// app showing a signed-in screen with no session behind it.
    ///
    /// The policy stays a parameter so that an event type with a real rate can
    /// pick one. The default is the claim that these do not have one.
    func events<Event: AppEvent>(of type: Event.Type) -> AsyncStream<Event> {
        events(of: type, bufferingPolicy: .unbounded)
    }
}

// MARK: - The bus

/// A typed publish/subscribe bus over `AsyncStream`.
///
/// ```swift
/// // Listen. One event type per subscription; the loop body handles exactly it.
/// for await event in bus.events(of: UserSignedIn.self) {
///     print(event.method)
/// }
///
/// // Announce, from any context.
/// bus.publish(UserSignedOut())
/// ```
///
/// ## Subscribing is synchronous, and that is the contract
///
/// `events(of:)` builds its stream *and registers it* before it returns, so
/// this is guaranteed to see the event:
///
/// ```swift
/// let stream = bus.events(of: UserSignedIn.self)   // registered here
/// Task { for await event in stream { … } }         // has not run a line yet
/// bus.publish(UserSignedIn(method: .password, email: nil))  // still delivered
/// ```
///
/// and this is guaranteed to race:
///
/// ```swift
/// Task { for await event in bus.events(of: UserSignedIn.self) { … } }
/// bus.publish(…)   // the Task may not have reached `events(of:)` yet
/// ```
///
/// The difference is where the subscription is created, not where it is
/// consumed, and it is worth stating because the second shape is the natural one
/// to write and the old `EventBusTests` wrote it five times — each test papered
/// over the race with `Task.sleep(for: .milliseconds(10))` and a hope. Every
/// caller in this package now takes the first shape: `SessionObserver.start()`
/// subscribes on the caller's thread and only then creates its tasks.
///
/// ## Storage
///
/// Subscriptions are bucketed by the `ObjectIdentifier` of the event type, so a
/// publish touches only the bucket for the type published — it does not walk
/// every subscriber asking whether this one is for them. Within a bucket the
/// continuations have all been erased behind `@Sendable` closures, because a
/// dictionary cannot hold an `AsyncStream<UserSignedIn>.Continuation` and an
/// `AsyncStream<UserSignedOut>.Continuation` in one value type.
///
/// Thread safety is `OSAllocatedUnfairLock` with the dictionary *inside* it, so
/// the class has only `let` stored properties of `Sendable` type and the
/// compiler checks the conformance rather than being told to assume it — see
/// `docs/concurrency.md`. Both rules from that document apply here and are
/// marked at the lines that obey them: nothing awaits under the lock, and
/// nothing calls out from under it.
final class EventBus: EventPublishing, EventSubscribing {

    /// One registration, erased to something a single dictionary can hold.
    private struct Subscription: Sendable {
        /// Yields to the stream this was built for.
        let deliver: @Sendable (any AppEvent) -> Void
        /// Ends that stream, so its consumer's `for await` returns.
        let finish: @Sendable () -> Void
    }

    private let subscriptions = OSAllocatedUnfairLock(
        initialState: [ObjectIdentifier: [UUID: Subscription]]()
    )

    init() {}

    // MARK: - Publishing

    func publish<Event: AppEvent>(_ event: Event) {
        let targets = subscriptions.withLock {
            Array(($0[ObjectIdentifier(Event.self)] ?? [:]).values)
        }

        // Outside the lock. `yield` runs the consumer's buffering policy and can
        // resume a suspended task, and a subscriber that publishes in response
        // would meet a non-recursive lock it already holds.
        for target in targets {
            target.deliver(event)
        }
    }

    // MARK: - Subscribing

    func events<Event: AppEvent>(
        of type: Event.Type,
        bufferingPolicy: AsyncStream<Event>.Continuation.BufferingPolicy
    ) -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream(
            of: Event.self,
            bufferingPolicy: bufferingPolicy
        )

        let key = ObjectIdentifier(type)
        let id = UUID()
        // The lock is a struct over a heap allocation, so a copy of it is the
        // same lock. Capturing that instead of `self` keeps the termination
        // handler — which outlives this call — from either retaining the bus for
        // the life of every subscription or, weakly, leaving the entry behind
        // when the bus goes away first.
        let registry = subscriptions

        registry.withLock {
            $0[key, default: [:]][id] = Subscription(
                deliver: { event in
                    // The bucket is keyed by `Event`, so this cast cannot fail.
                    // It is a `guard` rather than `as!` so that a future mistake
                    // in the keying drops an event instead of trapping in an
                    // app somebody shipped.
                    guard let typed = event as? Event else { return }
                    continuation.yield(typed)
                },
                finish: { continuation.finish() }
            )
        }

        continuation.onTermination = { _ in
            registry.withLock { storage in
                // Spelled as assignments rather than as `removeValue(forKey:)`,
                // which returns the entry it removed: an unused non-`Void`
                // result is a warning, and `assert-no-warnings.py` fails the
                // build on one.
                storage[key]?[id] = nil
                if storage[key]?.isEmpty == true {
                    storage[key] = nil
                }
            }
        }

        return stream
    }

    // MARK: - Lifecycle

    /// Ends every live subscription: each consumer drains what it has buffered
    /// and its `for await` returns.
    ///
    /// An owner tearing down deterministically is what this is for — and it is
    /// also what lets a test read a subscription to its end without a deadline,
    /// because a stream that has been finished cannot leave a `for await`
    /// waiting. A bus with no such call obliges every consumer to be cancelled
    /// individually, and a consumer nobody remembered to cancel is a `for await`
    /// that never returns.
    func finish() {
        let ending = subscriptions.withLock { storage -> [Subscription] in
            let snapshot = storage.values.flatMap { $0.values }
            storage.removeAll()
            return snapshot
        }

        // Outside the lock: each `finish()` runs that stream's termination
        // handler, and those come straight back in here.
        for subscription in ending {
            subscription.finish()
        }
    }

    /// How many live subscriptions `Event` currently has.
    ///
    /// Diagnostics, and the only way to observe the half of this type that has
    /// no other outward effect. A subscription that is never deregistered leaks
    /// a continuation for every screen that ever listened, and nothing about the
    /// app's behaviour would say so — the events keep arriving for the
    /// subscribers that are still there. `EventBusTests` reads it to pin both
    /// that registering happens before `events(of:)` returns and that
    /// terminating a stream removes it again.
    func subscriberCount<Event: AppEvent>(for type: Event.Type) -> Int {
        subscriptions.withLock { $0[ObjectIdentifier(type)]?.count ?? 0 }
    }
}
