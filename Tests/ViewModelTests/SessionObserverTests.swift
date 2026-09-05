import Foundation
import Testing
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Features
@testable import Networking

// MARK: - Helpers

/// Waits for a main-actor condition, and fails rather than hanging if it never
/// holds.
///
/// `AsyncPoll.until` in `ConcurrencyProbes.swift` does the same job for state
/// that is not actor-isolated. This one exists beside it because everything
/// asserted here is: `AppState` is `@MainActor`, so the condition has to be too,
/// and a `@MainActor` closure literal passed to `AsyncPoll`'s non-isolated
/// parameter would be a conversion rather than a call.
///
/// Polling, not sleeping. The observer applies its effects in a `Task` of its
/// own, so how many main-actor jobs are queued ahead of it is not this test's to
/// know; a fixed sleep would only make the assertion *likely*. A poll is exact
/// when the effect has landed and fails with the reason when it never does.
///
/// ## Why the poll is unbounded, and where the bound went
///
/// It used to carry its own five-second deadline, checked against
/// `ContinuousClock` on every turn. That is a stopwatch held against the main
/// actor's queue depth, and it measured the runner rather than the code: every
/// test in this suite is `@MainActor`, so is the observer's consumer task, and
/// so are two dozen others that Swift Testing runs in parallel with them. Five
/// of these eight went red on a loaded three-core runner in CI run #94, four of
/// them the same way on `main` in run #83, and the effect had landed correctly
/// every time — the main actor had simply not got back to the poll inside the
/// budget. A deadline that fires on a busy machine and not on an idle one
/// reports load, and a suite that reports load is one people learn to re-run.
///
/// So the wait no longer keeps time, and the bound is
/// `.timeLimit(.minutes(1))` on the suite: Swift Testing's own, which cancels
/// the test's task rather than racing it. `Task.sleep` throws on cancellation,
/// which is how the loop ends and how `description` still reaches the report —
/// the reason a wait was hung is the whole value of having written one down.
///
/// Nothing about what is asserted moves. Every `#expect` below is unchanged, a
/// condition that never holds still fails, and it fails naming the wait. The
/// only thing that stopped being asserted is a claim this suite never meant to
/// make: that a loaded CI runner will schedule a main-actor job within five
/// seconds.
@MainActor
private func waitForState(
    _ description: Comment,
    _ condition: @MainActor () async throws -> Bool
) async throws {
    while true {
        if try await condition() { return }
        do {
            try await Task.sleep(for: .milliseconds(5))
        } catch {
            Issue.record(description)
            throw error
        }
    }
}

/// A session graph with nothing live in it: real `AppState`, a real `EventBus`,
/// and the in-memory token store, holding an obviously fake pair.
///
/// One per test. Two tests sharing a bus would share subscriber counts, and the
/// counts are half of what is asserted here.
private struct Harness {
    let appState: AppState
    let tokenStore: InMemoryTokenStore
    let bus: EventBus
    let observer: SessionObserver

    @MainActor
    init() {
        let state = AppState()
        let store = InMemoryTokenStore(
            pair: TokenPair(
                accessToken: "mock-access-token",
                refreshToken: "mock-refresh-token"
            )
        )
        let eventBus = EventBus()

        appState = state
        tokenStore = store
        bus = eventBus
        observer = SessionObserver(
            appState: state,
            tokenStore: store,
            subscriber: eventBus
        )
    }
}

// MARK: - Tests

/// The consumer half of the observer pattern: what the app actually does when a
/// session begins or ends.
///
/// Two of these assert behaviour that did not exist before this suite did.
/// `AppState.currentUserEmail` was declared, cleared on sign-out and read by
/// `SettingsView`, and written by nothing — so the Account row rendered `"—"`
/// for every session. And signing out cleared two properties while leaving both
/// tokens in the Keychain, so the app showed a login screen over a session that
/// was still live. Both were invisible because the code that should have done
/// them was a `.onChange` in a view, where the question "what else does this
/// mean?" never gets asked.
///
/// The time limit is the bound `waitForState` used to carry itself. A minute is
/// four orders of magnitude more than any of these waits needs — they land in
/// microseconds on an idle machine — which is the point: it is a hang detector,
/// not a performance assertion, and a hang detector that can be tripped by a
/// busy runner is neither.
@Suite("SessionObserver — applying the session events", .timeLimit(.minutes(1)))
@MainActor
struct SessionObserverTests {

    // MARK: - Subscribing

    @Test("An observer that was never started has not subscribed")
    func unstartedObserverHasNotSubscribed() {
        let harness = Harness()

        #expect(harness.bus.subscriberCount(for: UserSignedIn.self) == 0)
        #expect(harness.bus.subscriberCount(for: UserSignedOut.self) == 0)
        _ = harness.observer
    }

    @Test("Starting subscribes to both session events")
    func startingSubscribesToBoth() {
        let harness = Harness()

        harness.observer.start()

        #expect(harness.bus.subscriberCount(for: UserSignedIn.self) == 1)
        #expect(harness.bus.subscriberCount(for: UserSignedOut.self) == 1)
    }

    @Test("Starting twice does not subscribe twice")
    func startingTwiceDoesNotSubscribeTwice() {
        let harness = Harness()

        harness.observer.start()
        harness.observer.start()

        #expect(harness.bus.subscriberCount(for: UserSignedIn.self) == 1)
        #expect(harness.bus.subscriberCount(for: UserSignedOut.self) == 1)
    }

    @Test("Stopping deregisters both subscriptions")
    func stoppingDeregisters() async throws {
        let harness = Harness()
        harness.observer.start()

        harness.observer.stop()

        try await waitForState("both subscriptions were deregistered") {
            harness.bus.subscriberCount(for: UserSignedIn.self) == 0
                && harness.bus.subscriberCount(for: UserSignedOut.self) == 0
        }
    }

    // MARK: - Signing in

    /// Also the subscribe-synchronously contract, exercised rather than
    /// described: the publish below is the statement after `start()`, with no
    /// suspension in between, so neither consuming task has run a line — and the
    /// event still cannot be missed.
    @Test("A password sign-in authenticates the app and records the address")
    func passwordSignInSetsStateAndAddress() async throws {
        let harness = Harness()
        harness.observer.start()

        harness.bus.publish(UserSignedIn(method: .password, email: "ada@example.invalid"))

        try await waitForState("the sign-in reached AppState") {
            harness.appState.isAuthenticated
        }
        #expect(harness.appState.currentUserEmail == "ada@example.invalid")
    }

    @Test("A social sign-in records the address the exchange returned")
    func socialSignInRecordsItsAddress() async throws {
        let harness = Harness()
        harness.observer.start()

        harness.bus.publish(UserSignedIn(method: .google, email: "grace@example.invalid"))

        try await waitForState("the sign-in reached AppState") {
            harness.appState.currentUserEmail == "grace@example.invalid"
        }
        #expect(harness.appState.isAuthenticated)
    }

    /// The reason `UserSignedIn.email` is an optional rather than an empty
    /// string. A biometric unlock authenticates the device's owner and learns no
    /// identity, so it must authenticate the app without blanking the address a
    /// previous sign-in established.
    @Test("A biometric unlock authenticates without erasing the known address")
    func biometricUnlockKeepsTheKnownAddress() async throws {
        let harness = Harness()
        harness.observer.start()

        harness.bus.publish(UserSignedIn(method: .password, email: "ada@example.invalid"))
        try await waitForState("the password sign-in reached AppState") {
            harness.appState.currentUserEmail == "ada@example.invalid"
        }

        harness.appState.isAuthenticated = false
        harness.bus.publish(UserSignedIn(method: .biometric, email: nil))

        try await waitForState("the biometric unlock reached AppState") {
            harness.appState.isAuthenticated
        }
        #expect(harness.appState.currentUserEmail == "ada@example.invalid")
    }

    // MARK: - Signing out

    @Test("Signing out clears the app state and the stored tokens")
    func signOutClearsStateAndTokens() async throws {
        let harness = Harness()
        harness.observer.start()

        harness.bus.publish(UserSignedIn(method: .password, email: "ada@example.invalid"))
        try await waitForState("the sign-in reached AppState") {
            harness.appState.isAuthenticated
        }

        harness.bus.publish(UserSignedOut())

        try await waitForState("the sign-out reached AppState") {
            !harness.appState.isAuthenticated
        }
        #expect(harness.appState.currentUserEmail == nil)

        // The consequence the Sign Out button never had. `AppState.signOut()`
        // clears two properties; the access and refresh tokens outlived it, so
        // the next authenticated request would have succeeded.
        try await waitForState("the token store was cleared") {
            do {
                _ = try await harness.tokenStore.currentToken()
                return false
            } catch {
                return true
            }
        }
    }
}
