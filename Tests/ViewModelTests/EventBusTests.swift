import Testing
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Features
@testable import Networking

// MARK: - Probe events

/// Events that exist only here, so that a test of the bus cannot pass or fail
/// because of something a view model publishes.
private struct ProbeEvent: AppEvent, Equatable {
    let value: Int
}

private struct OtherProbeEvent: AppEvent, Equatable {
    let value: Int
}

// MARK: - Tests

/// Every test in this suite is synchronous up to the point where it drains a
/// stream, and none of them sleeps.
///
/// The previous version of this file slept `10ms` in five of its five tests,
/// because it subscribed *inside* a `Task` and then published from outside it —
/// so the only thing standing between the suite and a race was the hope that the
/// task had reached its `for await` first. Both halves of that are gone.
/// `events(of:)` registers before it returns, so the subscription exists on the
/// line after it is asked for; and `finish()` ends every stream, so a `for await`
/// that collects the result terminates rather than waiting for an event that is
/// never coming. A broken bus fails these tests instead of hanging them.
@Suite("EventBus — a typed bus over AsyncStream")
struct EventBusTests {

    // MARK: - Registration

    @Test("Subscribing registers before events(of:) returns")
    func subscribingRegistersSynchronously() {
        let bus = EventBus()
        #expect(bus.subscriberCount(for: ProbeEvent.self) == 0)

        let stream = bus.events(of: ProbeEvent.self)

        #expect(bus.subscriberCount(for: ProbeEvent.self) == 1)
        // Keeps the stream alive to the end of the test, so the count above is
        // not being read against a subscription ARC has already torn down.
        _ = stream
    }

    @Test("Each subscription is counted against its own event type")
    func subscriptionsAreBucketedByType() {
        let bus = EventBus()

        let probes = bus.events(of: ProbeEvent.self)
        let others = bus.events(of: OtherProbeEvent.self)

        #expect(bus.subscriberCount(for: ProbeEvent.self) == 1)
        #expect(bus.subscriberCount(for: OtherProbeEvent.self) == 1)
        _ = (probes, others)
    }

    @Test("Finishing the bus ends every subscription and deregisters it")
    func finishingEndsAndDeregisters() async {
        let bus = EventBus()
        let stream = bus.events(of: ProbeEvent.self)
        #expect(bus.subscriberCount(for: ProbeEvent.self) == 1)

        bus.finish()

        #expect(bus.subscriberCount(for: ProbeEvent.self) == 0)
        let received = await collect(from: stream)
        #expect(received.isEmpty)
    }

    /// The other half of the registration contract, and the one with no outward
    /// symptom: a subscription that is never removed leaks a continuation for
    /// every screen that ever listened, while the events keep arriving perfectly
    /// well for the subscribers that are still there.
    @Test("A cancelled consumer is deregistered from the bus")
    func cancelledConsumerIsDeregistered() async throws {
        let bus = EventBus()
        let stream = bus.events(of: ProbeEvent.self)
        #expect(bus.subscriberCount(for: ProbeEvent.self) == 1)

        let consumer = Task {
            for await _ in stream {}
        }
        consumer.cancel()
        await consumer.value

        try await AsyncPoll.until("the cancelled subscription was deregistered") {
            bus.subscriberCount(for: ProbeEvent.self) == 0
        }
    }

    // MARK: - Delivery

    @Test("An event reaches a subscriber of its type")
    func eventReachesItsSubscriber() async {
        let bus = EventBus()
        let stream = bus.events(of: ProbeEvent.self)

        bus.publish(ProbeEvent(value: 7))
        bus.finish()

        #expect(await collect(from: stream) == [ProbeEvent(value: 7)])
    }

    @Test("Every subscriber of a type receives the same event")
    func allSubscribersOfATypeReceiveIt() async {
        let bus = EventBus()
        let first = bus.events(of: ProbeEvent.self)
        let second = bus.events(of: ProbeEvent.self)

        bus.publish(ProbeEvent(value: 3))
        bus.finish()

        #expect(await collect(from: first) == [ProbeEvent(value: 3)])
        #expect(await collect(from: second) == [ProbeEvent(value: 3)])
    }

    /// The claim the word "typed" is making. A subscriber to one event type does
    /// not receive another, and does not have to `switch` to find that out — the
    /// stream's element type is the filter.
    @Test("An event does not reach a subscriber of a different type")
    func eventDoesNotReachOtherTypes() async {
        let bus = EventBus()
        let probes = bus.events(of: ProbeEvent.self)
        let others = bus.events(of: OtherProbeEvent.self)

        bus.publish(ProbeEvent(value: 1))
        bus.finish()

        #expect(await collect(from: probes) == [ProbeEvent(value: 1)])
        #expect(await collect(from: others).isEmpty)
    }

    @Test("Events arrive in the order they were published")
    func eventsArriveInOrder() async {
        let bus = EventBus()
        let stream = bus.events(of: ProbeEvent.self)

        for value in 1...3 {
            bus.publish(ProbeEvent(value: value))
        }
        bus.finish()

        #expect(await collect(from: stream) == [
            ProbeEvent(value: 1),
            ProbeEvent(value: 2),
            ProbeEvent(value: 3),
        ])
    }

    @Test("Publishing with no subscribers is a no-op rather than a failure")
    func publishingWithNoSubscribersIsSafe() {
        let bus = EventBus()
        bus.publish(ProbeEvent(value: 1))
        #expect(bus.subscriberCount(for: ProbeEvent.self) == 0)
    }

    /// A subscription only carries what is published after it exists. This is
    /// the property that makes *where* you subscribe matter, and the reason
    /// `SessionObserver.start()` subscribes on the caller's thread rather than
    /// inside its tasks.
    @Test("A subscriber receives nothing published before it subscribed")
    func subscribersDoNotReceiveHistory() async {
        let bus = EventBus()

        bus.publish(ProbeEvent(value: 1))
        let stream = bus.events(of: ProbeEvent.self)
        bus.publish(ProbeEvent(value: 2))
        bus.finish()

        #expect(await collect(from: stream) == [ProbeEvent(value: 2)])
    }

    // MARK: - Buffering

    /// `.unbounded` is the default and this is the other side of it: an event
    /// type with a real rate can ask for a policy that drops, and the drop
    /// happens where the policy says rather than silently everywhere.
    @Test("A subscription can choose a lossy buffering policy")
    func bufferingPolicyIsHonoured() async {
        let bus = EventBus()
        let stream = bus.events(of: ProbeEvent.self, bufferingPolicy: .bufferingNewest(1))

        for value in 1...3 {
            bus.publish(ProbeEvent(value: value))
        }
        bus.finish()

        #expect(await collect(from: stream) == [ProbeEvent(value: 3)])
    }

    // MARK: - The session events

    /// Every `AuthMethod` survives the round trip, so a case added to the enum
    /// and forgotten in a publisher is visible here rather than at a call site
    /// that reads `method` and finds a value it did not expect.
    @Test("Every sign-in method round-trips", arguments: AuthMethod.allCases)
    func signInMethodsRoundTrip(method: AuthMethod) async {
        let bus = EventBus()
        let stream = bus.events(of: UserSignedIn.self)

        bus.publish(UserSignedIn(method: method, email: "probe@example.invalid"))
        bus.finish()

        #expect(await collect(from: stream) == [
            UserSignedIn(method: method, email: "probe@example.invalid"),
        ])
    }

    @Test("A sign-in and a sign-out do not reach each other's subscribers")
    func sessionEventsAreSeparate() async {
        let bus = EventBus()
        let signIns = bus.events(of: UserSignedIn.self)
        let signOuts = bus.events(of: UserSignedOut.self)

        bus.publish(UserSignedOut())
        bus.finish()

        #expect(await collect(from: signIns).isEmpty)
        #expect(await collect(from: signOuts) == [UserSignedOut()])
    }
}
