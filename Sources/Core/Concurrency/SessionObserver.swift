import Foundation

/// The app's subscriber to its own session events.
///
/// This is the half of the observer pattern the package did not have. `EventBus`
/// has existed since Phase 2 with an `emit`, an `events` and five tests, and
/// with no caller anywhere in `Sources/` — which is `docs/solid.md` finding 6 in
/// a different layer. A mechanism nothing runs is a claim, not a behaviour, and
/// the way to stop it being one is to give it the job the app was doing by hand.
///
/// ## What it replaces, and the two bugs that were in it
///
/// `LoginView` carried three `.onChange` blocks, one per sign-in flow, each
/// copying a view model's `isAuthenticated` into `AppState`'s — plus a fourth
/// assignment in the biometric button's callback, which duplicated the third.
/// Sign-out was a `Button` calling `appState.signOut()` directly. Both shapes
/// have the same defect: the screen that noticed the change was also the place
/// that had to know every consequence of it, so any consequence that did not
/// occur to whoever wrote that call site simply did not happen. Two did not:
///
/// - **`AppState.currentUserEmail` was written by nobody.** It is declared, it
///   is cleared on sign-out, and `SettingsView` renders it when the profile
///   fetch fails — as `"—"`, always, because no sign-in path ever set it. It is
///   set here now, from the event.
/// - **Signing out left the tokens on the device.** `AppState.signOut()` clears
///   two properties and `RootView` swaps to `LoginView`, which looks like a
///   sign-out and is not one: the access and refresh tokens are still in the
///   Keychain, so the next authenticated request succeeds. `applySignOut()`
///   clears them.
///
/// Neither fix belongs in a view. Both belong wherever "a session ended" is
/// turned into consequences, which is here — and the reason to route them
/// through a bus rather than call this type directly is that one event has two
/// unrelated consequences in two layers, and the publisher should know about
/// neither.
///
/// See `docs/events.md`.
@MainActor
final class SessionObserver {

    private let appState: AppState
    private let tokenStore: any TokenStoring
    private let subscriber: any EventSubscribing

    /// One task per event type.
    ///
    /// Two streams cannot be drained by one `for await`, and merging them would
    /// mean erasing both to a common element type — which is the enum this item
    /// removed. Two tasks is what a typed bus costs, and it is cheap: each loop
    /// body handles one concrete event and needs no `switch` to find out which.
    private var consumers: [Task<Void, Never>] = []

    init(
        appState: AppState,
        tokenStore: any TokenStoring,
        subscriber: any EventSubscribing
    ) {
        self.appState = appState
        self.tokenStore = tokenStore
        self.subscriber = subscriber
    }

    // MARK: - Lifecycle

    /// Subscribes, and starts applying what arrives. Calling it again while it
    /// is running does nothing.
    ///
    /// The two `events(of:)` calls are deliberately *before* the tasks rather
    /// than inside them. `EventBus` registers a subscription synchronously, so
    /// once this method returns both subscriptions exist and nothing published
    /// afterwards can be missed — even though neither task has run a line yet.
    /// Subscribing inside `Task { }` would open a window between "the app
    /// started observing" and "the app is registered", and the only way to close
    /// that window from outside is to sleep and hope, which is exactly what the
    /// bus's own tests used to do.
    func start() {
        guard consumers.isEmpty else { return }

        let signIns = subscriber.events(of: UserSignedIn.self)
        let signOuts = subscriber.events(of: UserSignedOut.self)

        consumers = [
            Task { [weak self] in
                for await event in signIns {
                    self?.applySignIn(event)
                }
            },
            Task { [weak self] in
                for await _ in signOuts {
                    await self?.applySignOut()
                }
            },
        ]
    }

    /// Stops observing. Cancelling each consumer ends its `for await`, which
    /// terminates the stream and deregisters it from the bus.
    func stop() {
        for consumer in consumers {
            consumer.cancel()
        }
        consumers = []
    }

    // MARK: - Effects

    private func applySignIn(_ event: UserSignedIn) {
        appState.isAuthenticated = true

        // Only overwrite the address when this flow learned one. A biometric
        // unlock carries no identity — see `UserSignedIn.email` — and writing
        // `nil` over a known email would blank the Account row for a session
        // that is still the same person's.
        if let email = event.email {
            appState.currentUserEmail = email
        }
    }

    private func applySignOut() async {
        appState.signOut()
        await tokenStore.clearTokens()
    }
}
