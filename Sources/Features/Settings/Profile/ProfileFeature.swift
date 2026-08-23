import Foundation

/// The Account section of Settings, as a `State` + `Action` + `Effect`
/// contract.
///
/// This is the screen `docs/solid.md` finding 6 was about: the chain
/// `SettingsView` → `SyncStrategy` → `UserRepository` → `APIClient` runs
/// through here, with a second leg into `UserPersistenceService`, and every hop
/// in it goes through a protocol resolved by `AppContainer`. What changed in
/// Phase 8 item 6 is not the chain but who is allowed to move the screen along
/// it: `ProfileEffectHandler` performs, `reduce` decides, and nothing else
/// writes state.
///
/// ## What the old five properties became
///
/// `ProfileViewModel` kept `state`, `origin`, `isSaving`, `saveErrorMessage`
/// and `draftName` as five independent properties, and two private methods were
/// responsible for keeping them agreeing with each other. Three of those
/// agreements are now unrepresentable rather than merely maintained:
///
/// * **`origin` is gone.** It described the provenance of the user in `state`,
///   and `SyncedUser` already carries both, so `Phase.loaded` holds one value
///   where there used to be two properties that could describe different users.
/// * **A refresh no longer blanks the screen.** `Phase.loading(previous:)`
///   carries what was on screen when the reload started, so the rows stay up
///   while `.refreshable` spins — and the reducer still has the user it needs
///   in order to decide whether the name field is the reader's or the server's.
/// * **"The reader has edited the name" is a stored fact.** It used to be
///   inferred by comparing `draftName` against the loaded user's name, which
///   answers "the draft differs" — a different question, and the wrong one for
///   a reader who cleared the field or typed the same name back.
///
/// ## Why `Phase` and not `LoadingState`
///
/// `LoadingState<Value>` is this package's async-lifecycle enum and would fit
/// but for one requirement: a `Feature.State` is `Equatable`, and
/// `LoadingState.failure` carries `any Error & Sendable`, which is not. Rather
/// than widen that type or drop the requirement, the failure here carries
/// `SyncErrorMessage` — the presentable box the strategies already produce —
/// and the whole state becomes comparable in a test.
enum ProfileFeature: Feature {

    // MARK: - State

    struct State: Sendable, Equatable {

        /// Where the profile read has got to.
        enum Phase: Sendable, Equatable {
            case idle
            /// A read is in flight. `previous` is what the screen was showing
            /// when it started, so a refresh does not empty the rows.
            case loading(previous: SyncedUser?)
            case loaded(SyncedUser)
            case failed(SyncErrorMessage)
        }

        var phase: Phase = .idle

        /// The editable copy of the name. Separate from the loaded user because
        /// `User` is immutable by design, and because an in-flight edit has to
        /// survive a reload that lands underneath it.
        var draftName: String = ""

        /// Whether `draftName` is the reader's typing rather than a name
        /// adopted from a load. See the note above on what this replaced.
        var isDraftEdited: Bool = false

        var isSaving: Bool = false

        var saveErrorMessage: String?
    }

    // MARK: - Actions

    enum Action: Sendable, Equatable {
        /// The view appeared. Fires again on every re-appearance.
        case appeared
        /// The pull-to-refresh gesture.
        case refreshRequested
        /// A read came back.
        case profileLoaded(Result<SyncedUser, SyncErrorMessage>)
        /// A keystroke in the name field.
        case draftNameEdited(String)
        case saveTapped
        /// A write came back.
        case profileSaved(Result<User, SyncErrorMessage>)
        case signOutTapped
    }

    // MARK: - Effects

    /// Named for what the screen wants, not for how it is obtained: the
    /// difference between `loadProfile` and `refreshProfile` is a sync policy,
    /// and which policy that is belongs to `ProfileEffectHandler`.
    enum Effect: Sendable, Equatable {
        /// Read under the policy the composition root resolved.
        case loadProfile
        /// Read in a way that will actually go to the network — the refresh
        /// gesture must not be answered by the cache it is trying to get past.
        case refreshProfile
        case saveName(String)
        case announceSignOut
    }

    // MARK: - Reducer

    static func reduce(_ state: inout State, on action: Action) -> Effect? {
        switch action {
        case .appeared:
            // `.task` fires again on every re-appearance, so a screen that
            // already has an answer must not re-request it.
            guard state.phase == .idle else { return nil }
            state.phase = .loading(previous: nil)
            return .loadProfile

        case .refreshRequested:
            state.phase = .loading(previous: state.synced)
            state.saveErrorMessage = nil
            return .refreshProfile

        case .profileLoaded(let result):
            return applyLoad(result, to: &state)

        case .draftNameEdited(let name):
            state.draftName = name
            state.isDraftEdited = true
            return nil

        case .saveTapped:
            guard state.canSave else { return nil }
            state.isSaving = true
            state.saveErrorMessage = nil
            return .saveName(state.trimmedDraftName)

        case .profileSaved(let result):
            return applySave(result, to: &state)

        case .signOutTapped:
            // Nothing changes here and nothing is awaited: the sign-out is
            // finished by whoever subscribed, and `RootView` swaps the whole
            // subtree away the moment it lands. See `docs/events.md`.
            return .announceSignOut
        }
    }

    // MARK: - Reducer branches

    private static func applyLoad(
        _ result: Result<SyncedUser, SyncErrorMessage>,
        to state: inout State
    ) -> Effect? {
        switch result {
        case .success(let synced):
            state.phase = .loaded(synced)
            if !state.isDraftEdited {
                state.draftName = synced.user.name
            }
        case .failure(let error):
            state.phase = .failed(error)
        }
        return nil
    }

    private static func applySave(
        _ result: Result<User, SyncErrorMessage>,
        to state: inout State
    ) -> Effect? {
        state.isSaving = false
        switch result {
        case .success(let user):
            // A write is the freshest thing there is, whatever the read policy
            // is: this value came back from the server on this call.
            state.phase = .loaded(SyncedUser(user: user, origin: .remote))
            state.draftName = user.name
            state.isDraftEdited = false
        case .failure(let error):
            // The loaded user stays: the profile did not stop existing because
            // the write did not land.
            state.saveErrorMessage = error.message
        }
        return nil
    }
}

// MARK: - Derived state

/// Everything the view needs that is a function of the state rather than a
/// second copy of it. Nothing here is stored, so nothing here can disagree with
/// `phase`.
extension ProfileFeature.State {

    /// The user on screen and where it came from, during a reload as well as
    /// after one.
    var synced: SyncedUser? {
        switch phase {
        case .loaded(let value):
            return value
        case .loading(let previous):
            return previous
        case .idle, .failed:
            return nil
        }
    }

    var user: User? { synced?.user }

    /// Where the displayed user came from, or `nil` when there is nothing
    /// displayed. A screen showing a cached profile has to be able to say so —
    /// see `SyncOrigin`.
    var origin: SyncOrigin? { synced?.origin }

    var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    var loadErrorMessage: String? {
        if case .failed(let error) = phase { return error.message }
        return nil
    }

    var trimmedDraftName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Saving is offered only for a change that is actually a change. A button
    /// that fires a request to rename "Ada" to "Ada" is a request the server
    /// answers and the reader learns nothing from.
    var canSave: Bool {
        guard let user, !isSaving else { return false }
        let candidate = trimmedDraftName
        return !candidate.isEmpty && candidate != user.name
    }
}
