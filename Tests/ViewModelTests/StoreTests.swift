import Foundation
import os
import Testing
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Features
@testable import Networking

// MARK: - A feature that exists only here

/// The smallest thing that is still a feature: one piece of state, one effect
/// with an answer, one effect with no answer, and one effect that asks for
/// another.
///
/// Written for these tests rather than borrowed from the app, so that what they
/// pin is the store's loop and not `ProfileFeature`'s policy — that is
/// `ProfileFeatureTests`' job.
private enum CounterFeature: Feature {

    struct State: Sendable, Equatable {
        /// Named `value` rather than `count`: SwiftLint's `empty_count` rule
        /// matches on the name, so a plain counter compared against zero reads
        /// to it as a collection that should have been asked `isEmpty`.
        var value = 0
        var isWorking = false
        var trail: [String] = []
    }

    enum Action: Sendable, Equatable {
        case incremented
        case loadRequested
        case loaded(Int)
        case chainRequested
        case chainStepFinished(Int)
        case announceRequested
    }

    enum Effect: Sendable, Equatable {
        case load
        case chain(step: Int)
        case announce
    }

    /// The last chain step. Three is enough to show that the loop keeps going
    /// rather than running the follow-up once.
    static let chainLength = 3

    static func reduce(_ state: inout State, on action: Action) -> Effect? {
        switch action {
        case .incremented:
            state.value += 1
            return nil

        case .loadRequested:
            state.isWorking = true
            return .load

        case .loaded(let loaded):
            state.isWorking = false
            state.value = loaded
            return nil

        case .chainRequested:
            return .chain(step: 1)

        case .chainStepFinished(let step):
            state.trail.append("step \(step)")
            guard step < chainLength else { return nil }
            return .chain(step: step + 1)

        case .announceRequested:
            return .announce
        }
    }
}

/// Records what it was asked to perform, and answers from a stub.
///
/// A `final class` for the same reason `MockSyncStrategy` is one: the store
/// holds its own copy of the handler, and a test that wants to read what was
/// performed needs that copy to be the object it kept.
private final class CounterEffects: EffectHandling {

    typealias Effect = CounterFeature.Effect
    typealias Action = CounterFeature.Action

    let loadedValue: Int
    private let log = OSAllocatedUnfairLock<[Effect]>(initialState: [])

    init(loadedValue: Int = 42) {
        self.loadedValue = loadedValue
    }

    /// The effects performed, in order.
    var performed: [Effect] { log.withLock { $0 } }

    func perform(_ effect: Effect) async -> Action? {
        log.withLock { $0.append(effect) }
        // A real suspension on every effect, so nothing here passes by finishing
        // before the caller has a chance to observe the in-between state.
        await Task.yield()

        switch effect {
        case .load:
            return .loaded(loadedValue)
        case .chain(let step):
            return .chainStepFinished(step)
        case .announce:
            // The handler's other legal answer: this one is nobody's business
            // on screen, like publishing an event.
            return nil
        }
    }
}

// MARK: - Tests

@Suite("Store — the loop that is a feature's whole control flow")
@MainActor
struct StoreTests {

    // MARK: - The reducer on its own

    /// The payoff of a `static` reducer that returns its effect: the decision
    /// half of a screen is testable with no store, no double, no `await` and no
    /// main actor.
    @Test("The reducer runs with nothing but a state and an action")
    func reducerNeedsNothingButAState() {
        var state = CounterFeature.State()

        let effect = CounterFeature.reduce(&state, on: .loadRequested)

        #expect(effect == .load)
        #expect(state.isWorking)
    }

    @Test("An action that changes only state asks for no effect")
    func anActionCanAskForNothing() {
        var state = CounterFeature.State()

        #expect(CounterFeature.reduce(&state, on: .incremented) == nil)
        #expect(state.value == 1)
    }

    // MARK: - Sending

    @Test("An awaited send returns once the chain is quiet")
    func awaitedSendReturnsWhenQuiet() async {
        let effects = CounterEffects(loadedValue: 7)
        let store = Store<CounterFeature>(initialState: CounterFeature.State(), effects: effects)

        await store.send(.loadRequested)

        #expect(store.state.value == 7)
        #expect(!store.state.isWorking)
        #expect(effects.performed == [.load])
    }

    /// The property the `Binding` setter depends on. A send that only scheduled
    /// the reduction would let a `TextField` render the value from before the
    /// keystroke and drop the character.
    @Test("The unawaited send has already reduced when it returns")
    func unawaitedSendReducesBeforeItReturns() {
        let store = Store<CounterFeature>(initialState: CounterFeature.State(), effects: CounterEffects())

        store.send(.incremented)

        #expect(store.state.value == 1)
    }

    /// What a `Button` action does, and how a test waits for it.
    @Test("settled waits for an effect the caller never awaited")
    func settledWaitsForTheUnawaitedPath() async {
        let effects = CounterEffects(loadedValue: 9)
        let store = Store<CounterFeature>(initialState: CounterFeature.State(), effects: effects)

        tap(.loadRequested, on: store)
        #expect(store.state.isWorking, "the reduction happens before send returns")
        #expect(store.state.value == 0, "the effect has not been performed yet")

        await store.settled()

        #expect(store.state.value == 9)
        #expect(!store.state.isWorking)
    }

    // MARK: - The loop

    /// The reason a feature never schedules its own follow-up: an action
    /// produced by an effect is reduced like any other, and the effect *it*
    /// asks for is performed in turn.
    @Test("An effect's answer is reduced, and its next effect performed, until nothing is asked for")
    func theChainRunsToQuiescence() async {
        let effects = CounterEffects()
        let store = Store<CounterFeature>(initialState: CounterFeature.State(), effects: effects)

        await store.send(.chainRequested)

        #expect(store.state.trail == ["step 1", "step 2", "step 3"])
        #expect(effects.performed == [.chain(step: 1), .chain(step: 2), .chain(step: 3)])
    }

    @Test("A handler that reports no action ends the chain")
    func aHandlerCanReportNothing() async {
        let effects = CounterEffects()
        let store = Store<CounterFeature>(initialState: CounterFeature.State(), effects: effects)
        let before = store.state

        await store.send(.announceRequested)

        #expect(effects.performed == [.announce])
        #expect(store.state == before)
    }

    @Test("An action that asks for nothing performs nothing")
    func anActionThatAsksForNothingPerformsNothing() async {
        let effects = CounterEffects()
        let store = Store<CounterFeature>(initialState: CounterFeature.State(), effects: effects)

        await store.send(.incremented)

        #expect(store.state.value == 1)
        #expect(effects.performed.isEmpty)
    }

    // MARK: - Helpers

    /// Sends the way a `Button` action closure does.
    ///
    /// It is a synchronous function on purpose. `send` is overloaded on `async`,
    /// and inside an async test the awaited version is the one the compiler
    /// picks — which is the right default everywhere in the app and the wrong
    /// one here, where the point is to leave the effect unawaited.
    private func tap(_ action: CounterFeature.Action, on store: Store<CounterFeature>) {
        store.send(action)
    }
}
