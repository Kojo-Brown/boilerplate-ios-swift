import Foundation
import Observation

/// The Account section of Settings: reads the signed-in user through a
/// `SyncStrategy` and writes a renamed profile back through the same one.
///
/// This is the caller `docs/solid.md` finding 6 said the repository layer did
/// not have. The chain it completes is
/// `SettingsView` → `ProfileViewModel` → `SyncStrategy` → `UserRepository` →
/// `APIClient`, with a second leg into `UserPersistenceService`, and every hop
/// in it goes through a protocol resolved by `AppContainer`.
///
/// It holds the factory as well as the strategy, and the reason is the refresh
/// gesture. The container resolves one policy for the app; a pull-to-refresh
/// under `cacheFirst` would otherwise be answered by the cache it is trying to
/// get past. Asking the factory for `.remoteFirst` states "go to the server,
/// but do not fail if the device is offline" without this type knowing which
/// concrete strategy that is.
@Observable
@MainActor
final class ProfileViewModel: ViewModelProtocol {

    private let strategy: any SyncStrategy
    private let strategyFactory: any SyncStrategyFactory

    private(set) var state: LoadingState<User> = .idle

    /// Where the currently displayed user came from, or `nil` when there is
    /// nothing displayed. A screen showing a cached profile has to be able to
    /// say so — see `SyncOrigin`.
    private(set) var origin: SyncOrigin?

    private(set) var isSaving = false
    private(set) var saveErrorMessage: String?

    /// The editable copy of the name. Separate from `state`'s user because
    /// `User` is immutable by design and because an in-flight edit must survive
    /// a refresh that lands underneath it.
    var draftName = ""

    init(strategy: any SyncStrategy, strategyFactory: any SyncStrategyFactory) {
        self.strategy = strategy
        self.strategyFactory = strategyFactory
    }

    // MARK: - Derived state

    var user: User? { state.value }
    var isLoading: Bool { state.isLoading }
    var loadErrorMessage: String? { state.error?.localizedDescription }

    var trimmedDraftName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Saving is offered only for a change that is actually a change. A button
    /// that fires a request to rename "Ada" to "Ada" is a request the server
    /// answers and the reader learns nothing from.
    var canSave: Bool {
        guard let user = state.value, !isSaving else { return false }
        let candidate = trimmedDraftName
        return !candidate.isEmpty && candidate != user.name
    }

    // MARK: - Lifecycle

    func onAppear() async {
        guard case .idle = state else { return }
        await load(using: strategy)
    }

    // MARK: - Actions

    /// The refresh gesture. Always goes to the network first, falling back to
    /// the cache only when the device cannot reach it.
    func refresh() async {
        await load(using: strategyFactory.makeStrategy(for: .remoteFirst))
    }

    func saveName() async {
        guard canSave else { return }
        let candidate = trimmedDraftName

        isSaving = true
        saveErrorMessage = nil
        defer { isSaving = false }

        do {
            let updated = try await strategy.updateProfile(name: candidate)
            state = .success(updated)
            // A write is the freshest thing there is, whatever the read policy
            // is: this value came back from the server on this call.
            origin = .remote
            draftName = updated.name
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Private

    private func load(using strategy: any SyncStrategy) async {
        // Captured before `state` moves: "the reader has edited the name" is
        // "the draft differs from the user currently on screen", and assigning
        // the new user first would make that comparison answer about the wrong
        // one.
        let hasUneditedDraft = draftName.isEmpty || draftName == state.value?.name

        state = .loading
        saveErrorMessage = nil

        do {
            let synced = try await strategy.loadCurrentUser()
            state = .success(synced.user)
            origin = synced.origin
            if hasUneditedDraft {
                draftName = synced.user.name
            }
        } catch {
            state = .failure(SyncErrorMessage(error))
            origin = nil
        }
    }
}
