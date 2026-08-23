import Foundation
import Testing
@testable import BoilerplateiOSSwift

/// The screen-side half of Phase 8 item 3, rewritten for item 6.
///
/// What these pin is not the sync policies — `SyncStrategyTests` does that —
/// but the claims this feature makes about how it uses them: that an ordinary
/// read goes through the strategy the composition root resolved, that the
/// refresh gesture asks the factory for one that will go to the network, and
/// that a write is adopted as the freshest thing on screen.
///
/// Every assertion `ProfileViewModelTests` made is here. What is new is the
/// half that needs no store at all: `reduce` is a static function over a value,
/// so the decisions it makes are testable without a double, an `await`, or an
/// object that has to be built first.
@Suite("ProfileFeature — the Account section as State + Action + Effect")
@MainActor
struct ProfileFeatureTests {

    // MARK: - The reducer alone

    @Test("Appearing on an idle screen asks for a read; appearing again asks for nothing")
    func appearingIsIdempotentInTheReducer() {
        var state = ProfileFeature.State()

        #expect(ProfileFeature.reduce(&state, on: .appeared) == .loadProfile)
        #expect(state.isLoading)

        let second = ProfileFeature.reduce(&state, on: .appeared)

        #expect(second == nil)
    }

    /// The whole state is `Equatable`, so "this action changed nothing" is one
    /// assertion rather than one per property — which is how a reducer that
    /// quietly clears a field gets caught.
    @Test("An action the screen has no answer for leaves the state exactly as it was")
    func anIgnoredActionChangesNothing() {
        var state = ProfileFeature.State(phase: .loaded(Self.synced(name: "Ada")))
        let before = state

        let effect = ProfileFeature.reduce(&state, on: .appeared)

        #expect(effect == nil)
        #expect(state == before)
    }

    /// The failure the old screen had by construction: `origin` was a property
    /// beside `state`, and only the two methods that assigned both kept them
    /// describing the same user.
    @Test("A refresh keeps the loaded user, and its provenance, on screen while it runs")
    func aRefreshKeepsWhatItIsReplacing() {
        var state = ProfileFeature.State(phase: .loaded(Self.synced(name: "Ada", origin: .localCache)))

        let effect = ProfileFeature.reduce(&state, on: .refreshRequested)

        #expect(effect == .refreshProfile)
        #expect(state.isLoading)
        #expect(state.user?.name == "Ada")
        #expect(state.origin == .localCache)
    }

    @Test("Saving asks for the trimmed name")
    func savingAsksForTheTrimmedName() {
        var state = ProfileFeature.State(phase: .loaded(Self.synced(name: "Before")))
        _ = ProfileFeature.reduce(&state, on: .draftNameEdited("  After  "))

        let effect = ProfileFeature.reduce(&state, on: .saveTapped)

        #expect(effect == .saveName("After"))
        #expect(state.isSaving)
    }

    // MARK: - Loading

    @Test("Appearing reads through the container's strategy")
    func appearingReadsThroughTheStrategy() async {
        let strategy = MockSyncStrategy()
        strategy.stubbedUser = User(email: "read@example.invalid", name: "Read User")
        strategy.stubbedOrigin = .remote
        let store = makeStore(strategy: strategy)

        await store.send(.appeared)

        #expect(strategy.loadCount == 1)
        #expect(store.state.user?.email == "read@example.invalid")
        #expect(store.state.origin == .remote)
        #expect(store.state.draftName == "Read User")
        #expect(store.state.loadErrorMessage == nil)
    }

    /// `.task` fires again on every re-appearance of the view, so a second
    /// `.appeared` must not re-request what is already on screen.
    @Test("Appearing again does not reload")
    func appearingAgainDoesNotReload() async {
        let strategy = MockSyncStrategy()
        let store = makeStore(strategy: strategy)

        await store.send(.appeared)
        await store.send(.appeared)

        #expect(strategy.loadCount == 1)
    }

    /// The provenance has to reach the screen: a cached profile presented as a
    /// live one is the failure mode `SyncOrigin` exists to prevent.
    @Test("A cached answer is reported as cached")
    func cachedAnswerIsReportedAsCached() async {
        let strategy = MockSyncStrategy()
        strategy.stubbedOrigin = .localCache
        let store = makeStore(strategy: strategy)

        await store.send(.appeared)

        #expect(store.state.origin == .localCache)
    }

    @Test("A failed read surfaces its message and leaves no user")
    func failedReadSurfacesItsMessage() async {
        let strategy = MockSyncStrategy()
        strategy.loadError = APIError.unauthorized
        let store = makeStore(strategy: strategy)

        await store.send(.appeared)

        #expect(store.state.user == nil)
        #expect(store.state.origin == nil)
        #expect(store.state.loadErrorMessage == APIError.unauthorized.localizedDescription)
    }

    // MARK: - Refreshing

    /// The Factory half, from the call site. Under `cacheFirst` the container's
    /// strategy would answer a pull-to-refresh from the cache it is trying to
    /// get past, so this asks for a policy that goes to the network and
    /// tolerates being offline.
    @Test("Refreshing asks the factory for a remote-first strategy")
    func refreshAsksTheFactoryForRemoteFirst() async {
        let factory = MockSyncStrategyFactory()
        let store = Store<ProfileFeature>(
            initialState: ProfileFeature.State(),
            effects: ProfileEffectHandler(
                strategy: MockSyncStrategy(),
                strategyFactory: factory,
                events: EventBus()
            )
        )

        await store.send(.refreshRequested)

        #expect(factory.requestedPolicies == [.remoteFirst])
    }

    @Test("Refreshing reloads even when a value is already on screen")
    func refreshReloadsAnyway() async {
        let strategy = MockSyncStrategy()
        let store = makeStore(strategy: strategy)

        await store.send(.appeared)
        await store.send(.refreshRequested)

        #expect(strategy.loadCount == 2)
    }

    /// A refresh that lands while the reader is renaming themselves must not
    /// throw away what they typed.
    @Test("A reload does not clobber an edit in progress")
    func reloadDoesNotClobberAnEdit() async {
        let strategy = MockSyncStrategy()
        strategy.stubbedUser = User(email: "edit@example.invalid", name: "Original")
        let store = makeStore(strategy: strategy)

        await store.send(.appeared)
        await store.send(.draftNameEdited("Half-typed n"))
        await store.send(.refreshRequested)

        #expect(store.state.draftName == "Half-typed n")
        #expect(store.state.user?.name == "Original")
    }

    // MARK: - Saving

    @Test("Saving sends the trimmed name and adopts the result")
    func savingSendsTheTrimmedName() async {
        let strategy = MockSyncStrategy()
        strategy.stubbedUser = User(email: "save@example.invalid", name: "Before")
        let store = makeStore(strategy: strategy)
        await store.send(.appeared)

        await store.send(.draftNameEdited("  After  "))
        await store.send(.saveTapped)

        #expect(strategy.requestedNames == ["After"])
        #expect(store.state.user?.name == "After")
        #expect(store.state.draftName == "After")
        #expect(store.state.origin == .remote)
        #expect(store.state.saveErrorMessage == nil)
        #expect(!store.state.isSaving)
    }

    @Test("A name that is unchanged or blank is not sent", arguments: [
        "Before",
        "   Before ",
        "   ",
        "",
    ])
    func unchangedOrBlankNamesAreNotSent(draft: String) async {
        let strategy = MockSyncStrategy()
        strategy.stubbedUser = User(email: "save@example.invalid", name: "Before")
        let store = makeStore(strategy: strategy)
        await store.send(.appeared)

        await store.send(.draftNameEdited(draft))

        #expect(!store.state.canSave)
        await store.send(.saveTapped)
        #expect(strategy.updateCount == 0)
    }

    @Test("Nothing is sent before a user has loaded")
    func nothingIsSentBeforeAUserHasLoaded() async {
        let strategy = MockSyncStrategy()
        let store = makeStore(strategy: strategy)

        await store.send(.draftNameEdited("Eager"))

        #expect(!store.state.canSave)
        await store.send(.saveTapped)

        #expect(strategy.updateCount == 0)
    }

    /// A failed save keeps the loaded user on screen — the profile did not
    /// stop existing because the write did not land.
    @Test("A failed save reports itself and keeps the loaded user")
    func failedSaveReportsItself() async {
        let strategy = MockSyncStrategy()
        strategy.stubbedUser = User(email: "save@example.invalid", name: "Before")
        let store = makeStore(strategy: strategy)
        await store.send(.appeared)
        strategy.updateError = APIError.unauthorized

        await store.send(.draftNameEdited("After"))
        await store.send(.saveTapped)

        #expect(store.state.saveErrorMessage == APIError.unauthorized.localizedDescription)
        #expect(store.state.user?.name == "Before")
        #expect(!store.state.isSaving)
    }

    // MARK: - Wiring

    /// The container builds it on the collaborators the root resolved, which is
    /// what makes the chain `SettingsView` → `ProfileEffectHandler` →
    /// `SyncStrategy` → `UserRepository` a chain and not a diagram.
    @Test("The container's factory method injects the container's strategy")
    func containerInjectsItsOwnStrategy() async throws {
        let container = AppContainer.preview
        let strategy = try #require(container.syncStrategy as? MockSyncStrategy)
        let store = container.makeProfileStore()

        await store.send(.appeared)

        #expect(strategy.loadCount == 1)
    }

    // MARK: - Signing out

    /// The button used to call `appState.signOut()` from its action, which
    /// cleared two properties and left both tokens in the Keychain. Announcing
    /// it is what lets `SessionObserver` do the half the screen never did.
    ///
    /// Sent the way `SettingsView` sends it — from a synchronous closure,
    /// leaving the effect unawaited — so what this covers is the path the app
    /// actually takes.
    @Test("Signing out announces the end of the session")
    func signOutAnnouncesTheEndOfTheSession() async {
        let bus = EventBus()
        let stream = bus.events(of: UserSignedOut.self)
        let store = makeStore(strategy: MockSyncStrategy(), events: bus)

        tap(.signOutTapped, on: store)
        await store.settled()
        bus.finish()

        #expect(await collect(from: stream) == [UserSignedOut()])
    }

    @Test("Signing out changes nothing on the screen it was sent from")
    func signOutChangesNothingLocally() async {
        let strategy = MockSyncStrategy()
        let store = makeStore(strategy: strategy)
        await store.send(.appeared)
        let before = store.state

        await store.send(.signOutTapped)

        #expect(store.state == before)
    }

    // MARK: - Helpers

    private func makeStore(
        strategy: MockSyncStrategy,
        events: any EventPublishing = EventBus()
    ) -> Store<ProfileFeature> {
        Store(
            initialState: ProfileFeature.State(),
            effects: ProfileEffectHandler(
                strategy: strategy,
                strategyFactory: MockSyncStrategyFactory(stubbedStrategy: strategy),
                events: events
            )
        )
    }

    /// Sends the way a `Button` action closure does — synchronously, leaving
    /// the effect to the store. See `StoreTests.tap(_:on:)` for why this is not
    /// written inline in an async test.
    private func tap(_ action: ProfileFeature.Action, on store: Store<ProfileFeature>) {
        store.send(action)
    }

    private static func synced(
        name: String,
        origin: SyncOrigin = .remote
    ) -> SyncedUser {
        SyncedUser(
            user: User(email: "fixture@example.invalid", name: name),
            origin: origin
        )
    }
}
