/// The preview stand-in for the composition root. See
/// `PreviewLoginDependencies` for why each feature ships one.
package struct PreviewHomeDependencies: HomeDependencies {

    package init() {}

    @MainActor
    package func makeHomeViewModel() -> HomeViewModel {
        HomeViewModel()
    }
}
