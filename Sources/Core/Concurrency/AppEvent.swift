import Foundation

// MARK: - The event contract

/// Anything the app broadcasts through `EventBus`.
///
/// One requirement, `Sendable`, because that is the whole of what a bus needs
/// from an event: it is published by whichever task noticed something and
/// consumed by whichever tasks care, so it crosses an isolation boundary by
/// construction. Everything else about an event is the event's own business.
///
/// ## Why a protocol, where there used to be an enum
///
/// This was `enum AppEvent { case userLoggedIn(email:), userLoggedOut, … }`, and
/// the bus vended one `AsyncStream<AppEvent>` carrying all of the cases. That
/// makes every subscriber a subscriber to everything: a listener that cares
/// about sign-out is handed every sign-in as well, and has to `switch` its way
/// back to the one case it asked for with a `default: break` absorbing the rest.
///
/// Filtering in the consumer is what an untyped `NotificationCenter` obliges you
/// to do. The claim a *typed* bus makes is that the filter is the type:
/// `events(of: UserSignedOut.self)` is an `AsyncStream<UserSignedOut>`, its loop
/// body handles a `UserSignedOut`, and no other event can reach it — checked by
/// the compiler rather than by a `switch` nobody re-reads.
///
/// The cost, stated rather than glossed: there is no exhaustive `switch` over
/// "every event in the app" any more, so adding an event breaks no build and
/// reminds nobody. That is the same trade `Notification.Name` makes, minus the
/// untyped payload, and it is the right one here — no subscriber in this app
/// wants every event (`SessionObserver` wants two, separately), while a shared
/// enum would make adding a third event an edit to a type that unrelated
/// features depend on.
package protocol AppEvent: Sendable {}

// MARK: - Session events

/// How a session was established.
///
/// Carried on `UserSignedIn` because "somebody is signed in" and "somebody typed
/// a password just now" are different facts, and the second one is the one a
/// subscriber needs to decide whether to offer biometric enrolment, or to skip a
/// welcome screen for a returning user.
package enum AuthMethod: String, Sendable, Equatable, CaseIterable {
    case password
    case apple
    case google
    case biometric
}

/// The app acquired an authenticated session.
package struct UserSignedIn: AppEvent, Equatable {

    /// Which flow established it.
    package let method: AuthMethod

    /// The account that signed in, when the flow that signed it in knows one.
    ///
    /// `nil` for `.biometric`, and only there. Face ID and Touch ID evaluate
    /// whoever is holding the device against credentials that are already on it,
    /// so what comes back is a yes, not an identity. An optional keeps "this
    /// flow learned no address" distinct from "this account has no address", and
    /// `SessionObserver` reads it that way: a biometric unlock does not blank
    /// the email a password sign-in already put on `AppState`.
    package let email: String?

    package init(method: AuthMethod, email: String?) {
        self.method = method
        self.email = email
    }
}

/// The app gave up its session.
///
/// Deliberately payload-free. A reason code — `.userInitiated` beside
/// `.sessionExpired` — is the obvious second field and is absent because only
/// one thing publishes this: the Sign Out button in Settings. Expiry does not go
/// through the bus; `TokenStore.refreshIfNeeded(using:)` clears the pair when a
/// refresh fails and tells nobody, which is a real gap and a transport-layer one.
/// A case nothing can construct would describe the app as it is not. See
/// `docs/events.md`.
package struct UserSignedOut: AppEvent, Equatable {
    package init() {}
}
