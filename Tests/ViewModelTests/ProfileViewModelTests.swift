import Foundation
import Testing
@testable import BoilerplateiOSSwift

/// The screen-side half of Phase 8 item 3.
///
/// What these pin is not the sync policies — `SyncStrategyTests` does that —
/// but the two claims this type makes about how it uses them: that an ordinary
/// read goes through the strategy the composition root resolved, and that the
/// refresh gesture asks the factory for one that will go to the network.
@Suite("ProfileViewModel — the caller finding 6 said the layer did not have")
@MainActor
struct ProfileViewModelTests {

    // MARK: - Loading

    @Test("onAppear reads through the container's strategy")
    func onAppearReadsThroughTheStrategy() async {
        let strategy = MockSyncStrategy()
        strategy.stubbedUser = User(email: "read@example.invalid", name: "Read User")
        strategy.stubbedOrigin = .remote
        let viewModel = makeViewModel(strategy: strategy)

        await viewModel.onAppear()

        #expect(strategy.loadCount == 1)
        #expect(viewModel.user?.email == "read@example.invalid")
        #expect(viewModel.origin == .remote)
        #expect(viewModel.draftName == "Read User")
        #expect(viewModel.loadErrorMessage == nil)
    }

    /// `.task` fires again on every re-appearance of the view, so a second
    /// `onAppear` must not re-request what is already on screen.
    @Test("onAppear does not reload once it has an answer")
    func onAppearIsIdempotent() async {
        let strategy = MockSyncStrategy()
        let viewModel = makeViewModel(strategy: strategy)

        await viewModel.onAppear()
        await viewModel.onAppear()

        #expect(strategy.loadCount == 1)
    }

    /// The provenance has to reach the screen: a cached profile presented as a
    /// live one is the failure mode `SyncOrigin` exists to prevent.
    @Test("A cached answer is reported as cached")
    func cachedAnswerIsReportedAsCached() async {
        let strategy = MockSyncStrategy()
        strategy.stubbedOrigin = .localCache
        let viewModel = makeViewModel(strategy: strategy)

        await viewModel.onAppear()

        #expect(viewModel.origin == .localCache)
    }

    @Test("A failed read surfaces its message and leaves no user")
    func failedReadSurfacesItsMessage() async {
        let strategy = MockSyncStrategy()
        strategy.loadError = APIError.unauthorized
        let viewModel = makeViewModel(strategy: strategy)

        await viewModel.onAppear()

        #expect(viewModel.user == nil)
        #expect(viewModel.origin == nil)
        #expect(viewModel.loadErrorMessage == APIError.unauthorized.localizedDescription)
    }

    // MARK: - Refreshing

    /// The Factory half, from the call site. Under `cacheFirst` the container's
    /// strategy would answer a pull-to-refresh from the cache it is trying to
    /// get past, so this asks for a policy that goes to the network and
    /// tolerates being offline.
    @Test("refresh asks the factory for a remote-first strategy")
    func refreshAsksTheFactoryForRemoteFirst() async {
        let factory = MockSyncStrategyFactory()
        let viewModel = ProfileViewModel(
            strategy: MockSyncStrategy(),
            strategyFactory: factory,
            events: EventBus()
        )

        await viewModel.refresh()

        #expect(factory.requestedPolicies == [.remoteFirst])
    }

    @Test("refresh reloads even when a value is already on screen")
    func refreshReloadsAnyway() async {
        let strategy = MockSyncStrategy()
        let viewModel = makeViewModel(strategy: strategy)

        await viewModel.onAppear()
        await viewModel.refresh()

        #expect(strategy.loadCount == 2)
    }

    /// A refresh that lands while the reader is renaming themselves must not
    /// throw away what they typed.
    @Test("A reload does not clobber an edit in progress")
    func reloadDoesNotClobberAnEdit() async {
        let strategy = MockSyncStrategy()
        strategy.stubbedUser = User(email: "edit@example.invalid", name: "Original")
        let viewModel = makeViewModel(strategy: strategy)

        await viewModel.onAppear()
        viewModel.draftName = "Half-typed n"
        await viewModel.refresh()

        #expect(viewModel.draftName == "Half-typed n")
        #expect(viewModel.user?.name == "Original")
    }

    // MARK: - Saving

    @Test("Saving sends the trimmed name and adopts the result")
    func savingSendsTheTrimmedName() async {
        let strategy = MockSyncStrategy()
        strategy.stubbedUser = User(email: "save@example.invalid", name: "Before")
        let viewModel = makeViewModel(strategy: strategy)
        await viewModel.onAppear()

        viewModel.draftName = "  After  "
        await viewModel.saveName()

        #expect(strategy.requestedNames == ["After"])
        #expect(viewModel.user?.name == "After")
        #expect(viewModel.draftName == "After")
        #expect(viewModel.origin == .remote)
        #expect(viewModel.saveErrorMessage == nil)
    }

    @Test("A name that is unchanged, blank or unloaded is not sent", arguments: [
        "Before",
        "   Before ",
        "   ",
        "",
    ])
    func unchangedOrBlankNamesAreNotSent(draft: String) async {
        let strategy = MockSyncStrategy()
        strategy.stubbedUser = User(email: "save@example.invalid", name: "Before")
        let viewModel = makeViewModel(strategy: strategy)
        await viewModel.onAppear()

        viewModel.draftName = draft

        #expect(!viewModel.canSave)
        await viewModel.saveName()
        #expect(strategy.updateCount == 0)
    }

    @Test("Nothing is sent before a user has loaded")
    func nothingIsSentBeforeAUserHasLoaded() async {
        let strategy = MockSyncStrategy()
        let viewModel = makeViewModel(strategy: strategy)

        viewModel.draftName = "Eager"
        #expect(!viewModel.canSave)
        await viewModel.saveName()

        #expect(strategy.updateCount == 0)
    }

    /// A failed save keeps the loaded user on screen — the profile did not
    /// stop existing because the write did not land.
    @Test("A failed save reports itself and keeps the loaded user")
    func failedSaveReportsItself() async {
        let strategy = MockSyncStrategy()
        strategy.stubbedUser = User(email: "save@example.invalid", name: "Before")
        let viewModel = makeViewModel(strategy: strategy)
        await viewModel.onAppear()
        strategy.updateError = APIError.unauthorized

        viewModel.draftName = "After"
        await viewModel.saveName()

        #expect(viewModel.saveErrorMessage == APIError.unauthorized.localizedDescription)
        #expect(viewModel.user?.name == "Before")
        #expect(!viewModel.isSaving)
    }

    // MARK: - Wiring

    /// The container builds it on the collaborators the root resolved, which is
    /// what makes the chain `SettingsView` → `ProfileViewModel` →
    /// `SyncStrategy` → `UserRepository` a chain and not a diagram.
    @Test("The container's factory method injects the container's strategy")
    func containerInjectsItsOwnStrategy() async throws {
        let container = AppContainer.preview
        let strategy = try #require(container.syncStrategy as? MockSyncStrategy)
        let viewModel = container.makeProfileViewModel()

        await viewModel.onAppear()

        #expect(strategy.loadCount == 1)
    }

    // MARK: - Signing out

    /// The button used to call `appState.signOut()` from its action, which
    /// cleared two properties and left both tokens in the Keychain. Announcing
    /// it is what lets `SessionObserver` do the half the screen never did.
    @Test("signOut announces the end of the session")
    func signOutAnnouncesTheEndOfTheSession() async {
        let bus = EventBus()
        let stream = bus.events(of: UserSignedOut.self)
        let viewModel = makeViewModel(strategy: MockSyncStrategy(), events: bus)

        viewModel.signOut()
        bus.finish()

        #expect(await collect(from: stream) == [UserSignedOut()])
    }

    // MARK: - Helpers

    private func makeViewModel(
        strategy: MockSyncStrategy,
        events: any EventPublishing = EventBus()
    ) -> ProfileViewModel {
        ProfileViewModel(
            strategy: strategy,
            strategyFactory: MockSyncStrategyFactory(stubbedStrategy: strategy),
            events: events
        )
    }
}
