/// What `HomeView` needs from the composition root. See `LoginDependencies` for
/// why each screen declares this rather than taking `AppContainer`.
package protocol HomeDependencies {
    @MainActor func makeHomeViewModel() -> HomeViewModel
}
