import Testing
@testable import BoilerplateiOSSwift

@Suite("EventBus")
struct EventBusTests {
    @Test("emitted event reaches single subscriber")
    func emittedEventReachesSingleSubscriber() async throws {
        let bus = EventBus()

        // Collect the first event via a Result-carrying Task
        let receiveTask = Task<AppEvent?, Never> {
            for await event in bus.events { return event }
            return nil
        }

        try await Task.sleep(for: .milliseconds(10))
        bus.emit(.userLoggedOut)

        let received = await receiveTask.value
        #expect(received == .userLoggedOut)
    }

    @Test("multiple subscribers each receive the same event")
    func multipleSubscribersReceiveSameEvent() async throws {
        let bus = EventBus()

        let task1 = Task<AppEvent?, Never> {
            for await event in bus.events { return event }
            return nil
        }
        let task2 = Task<AppEvent?, Never> {
            for await event in bus.events { return event }
            return nil
        }

        try await Task.sleep(for: .milliseconds(10))
        bus.emit(.itemRefreshRequested)

        let r1 = await task1.value
        let r2 = await task2.value

        #expect(r1 == .itemRefreshRequested)
        #expect(r2 == .itemRefreshRequested)
    }

    @Test("associated values are preserved through the bus")
    func associatedValuesPreserved() async throws {
        let bus = EventBus()
        let expectedEmail = "hello@example.com"

        let receiveTask = Task<AppEvent?, Never> {
            for await event in bus.events { return event }
            return nil
        }

        try await Task.sleep(for: .milliseconds(10))
        bus.emit(.userLoggedIn(email: expectedEmail))

        let received = await receiveTask.value
        #expect(received == .userLoggedIn(email: expectedEmail))
    }

    @Test("events are delivered in emission order")
    func eventsDeliveredInOrder() async throws {
        let bus = EventBus()

        let collectTask = Task<[AppEvent], Never> {
            var results: [AppEvent] = []
            for await event in bus.events {
                results.append(event)
                if results.count == 3 { break }
            }
            return results
        }

        try await Task.sleep(for: .milliseconds(10))
        bus.emit(.userLoggedOut)
        bus.emit(.itemRefreshRequested)
        bus.emit(.profileUpdated(name: "Alice"))

        let results = await collectTask.value

        #expect(results.count == 3)
        #expect(results[0] == .userLoggedOut)
        #expect(results[1] == .itemRefreshRequested)
        #expect(results[2] == .profileUpdated(name: "Alice"))
    }

    @Test("terminated subscriber no longer receives events")
    func terminatedSubscriberIgnored() async throws {
        let bus = EventBus()

        let collectTask = Task<[AppEvent], Never> {
            var results: [AppEvent] = []
            for await event in bus.events {
                results.append(event)
                if results.count == 1 { break }  // break after first → terminates stream
            }
            return results
        }

        try await Task.sleep(for: .milliseconds(10))
        bus.emit(.userLoggedOut)

        let firstBatch = await collectTask.value
        #expect(firstBatch.count == 1)

        // Emit more events — the terminated subscriber should not receive them
        bus.emit(.itemRefreshRequested)
        try await Task.sleep(for: .milliseconds(10))

        // Verify by collecting from a fresh subscription
        let secondTask = Task<AppEvent?, Never> {
            for await event in bus.events { return event }
            return nil
        }
        try await Task.sleep(for: .milliseconds(10))
        bus.emit(.profileUpdated(name: "Bob"))
        let secondEvent = await secondTask.value
        #expect(secondEvent == .profileUpdated(name: "Bob"))
    }
}
