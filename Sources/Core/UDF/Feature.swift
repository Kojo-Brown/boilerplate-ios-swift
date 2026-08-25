import Foundation

// MARK: - The contract

/// One screen's whole contract: what it can be (`State`), what can happen to it
/// (`Action`), and what it can ask the outside world to do (`Effect`).
///
/// A conformer is a namespace, not an object — `enum ProfileFeature: Feature`
/// with no cases. It owns three types and one function, holds nothing, and is
/// never instantiated.
///
/// ## What this replaces
///
/// The `@Observable` view models in this package each keep the screen's state as
/// a handful of independent stored properties, and every method that changes one
/// of them is responsible for keeping the rest consistent. `ProfileViewModel`
/// was five: a `LoadingState<User>`, a `SyncOrigin?` beside it, an `isSaving`
/// flag, a `saveErrorMessage`, and a `draftName`. Nothing but discipline stopped
/// `origin` from describing a user that `state` no longer held, and the pairing
/// only ever appeared inside the two private methods that assigned both.
///
/// Under this contract that screen has one value. `origin` is gone as a property
/// because `SyncedUser` already pairs a user with its provenance, so the two
/// cannot disagree — not by convention, but because there is no second place to
/// write. That is the property the pattern buys, and it is worth more than the
/// indirection it costs.
///
/// ## The three types
///
/// **`State` is `Equatable`.** A state a test cannot compare as a whole is a
/// state a test has to poke at property by property, which is the assertion
/// style this pattern exists to remove — and it is how a reducer that leaves one
/// field stale keeps passing. It is `Sendable` because the store hands it across
/// isolation boundaries.
///
/// **`Action` is everything that can happen**, including the outcome of an
/// effect. `.saveTapped` and `.profileSaved(_)` are both actions: the reducer is
/// the only writer, so the answer that came back from the network has to arrive
/// as an action or it cannot land at all.
///
/// **`Effect` is a request, not the work.** It says *what* to do — `.saveName`,
/// `.refreshProfile` — and never how, because the how is a collaborator and the
/// reducer must not hold one. It is `Equatable` in practice for the same reason
/// `State` is: `#expect(effect == .saveName("Ada"))` is the whole test for a
/// branch of the reducer, and it needs no store, no double and no `await`.
package protocol Feature {

    /// Everything the screen shows, and nothing else. See the note above on why
    /// this is `Equatable`.
    associatedtype State: Sendable & Equatable

    /// Everything that can happen to the screen: what a person did, and what an
    /// effect came back with.
    associatedtype Action: Sendable

    /// What the screen asks the outside world for.
    associatedtype Effect: Sendable

    /// Applies `action` to `state`, and returns the one thing the outside world
    /// must do as a result.
    ///
    /// This is the only function in the app allowed to change this screen's
    /// state, and it is pure: same state, same action, same result, every time.
    /// It cannot await, cannot fail, and cannot reach a collaborator — a
    /// requirement carried by the signature rather than by a comment, since
    /// `static` leaves it nothing to reach *from*. What it can do is decide, and
    /// a decision that needs the network says so by returning an effect.
    ///
    /// - Returns: The effect to perform, or `nil` when the action is entirely a
    ///   change of state.
    ///
    /// ## At most one effect
    ///
    /// The return type is `Effect?`, not `[Effect]`, and that is a constraint
    /// rather than an omission: one action means one consequence. A reducer
    /// reaching for two is usually an action that means two things and wants
    /// splitting; a feature that genuinely needs a pair says so with an effect
    /// case that names the pair, which keeps it readable at the point where a
    /// handler has to perform it. `docs/unidirectional-data-flow.md` records
    /// what this would cost if a feature here outgrew it.
    static func reduce(_ state: inout State, on action: Action) -> Effect?
}

// MARK: - Performing the effects

/// The other half of a feature: the part that is allowed to talk to the world.
///
/// A handler holds the collaborators — a `SyncStrategy`, an `EventPublishing`,
/// a repository — and turns an effect into the action its outcome means. It is
/// where every `await` in a feature lives, and it is the only piece a test has
/// to substitute, because the reducer beside it needs nothing substituted at
/// all.
///
/// It is `Sendable` and its requirement is `nonisolated`, so `perform` runs off
/// the main actor: the store is `@MainActor` and awaits it, which is the hop
/// `OffMainActor` describes, made once here for every feature instead of once
/// per view model.
package protocol EffectHandling<Effect, Action>: Sendable {

    /// The effects this handler knows how to perform — a `Feature.Effect`.
    associatedtype Effect: Sendable

    /// The actions it reports back — a `Feature.Action`.
    associatedtype Action: Sendable

    /// Performs `effect` and reports the one action its outcome means, or `nil`
    /// when the outcome is not the screen's business.
    ///
    /// It does not throw, and that is the point of the signature. A failure is
    /// something the screen has to say — a message in a row, a retry button —
    /// so it is an action like any other. A handler that could throw would open
    /// a second way out of an effect that the reducer never sees, and the state
    /// left behind by the action that started it would be the state the screen
    /// keeps: an `isSaving` that stays `true` because the error went somewhere
    /// else.
    func perform(_ effect: Effect) async -> Action?
}
