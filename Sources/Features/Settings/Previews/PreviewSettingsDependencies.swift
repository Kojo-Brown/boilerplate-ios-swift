import Core
import Networking

/// The preview stand-in for the composition root. See
/// `PreviewLoginDependencies` for why each feature ships one.
package struct PreviewSettingsDependencies: SettingsDependencies {

    /// One strategy, handed to the store *and* vended by the factory, so a
    /// preview that pulls to refresh sees the profile it was already showing —
    /// the same pairing `AppContainer.preview` makes and for the same reason.
    private let strategy = MockSyncStrategy()

    private let bus = EventBus()

    package init() {}

    @MainActor
    package func makeProfileStore() -> Store<ProfileFeature> {
        Store(
            initialState: ProfileFeature.State(),
            effects: ProfileEffectHandler(
                strategy: strategy,
                strategyFactory: MockSyncStrategyFactory(stubbedStrategy: strategy),
                events: bus
            )
        )
    }
}
