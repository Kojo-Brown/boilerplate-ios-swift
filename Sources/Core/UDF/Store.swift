import Foundation
import Observation

/// Holds one feature's state and is the only thing allowed to change it.
///
/// A store is what a view owns instead of a view model. It is `@Observable` and
/// `@MainActor` for the same reasons the view models were — SwiftUI reads
/// `state` from the main actor and re-renders when it changes — and it differs
/// in the one way that matters: it has no methods that change state. It has one
/// method, `send`, which hands the action to `F.reduce` and hands whatever comes
/// back to the effect handler.
///
/// ```swift
/// struct SettingsView: View {
///     @State private var store: Store<ProfileFeature>
///
///     var body: some View {
///         List { … }
///             .task { await store.send(.appeared) }
///             .refreshable { await store.send(.refreshRequested) }
///     }
/// }
/// ```
///
/// ## The loop
///
/// `send` reduces, performs the effect the reducer asked for, and reduces the
/// action that effect reported — repeating until a reduction asks for nothing
/// or a handler reports nothing. That is the whole cycle, and it is why a
/// feature never has to schedule its own follow-up: a save that must reload
/// afterwards returns `.reload` from the reducer branch that handled
/// `.profileSaved`, and the loop takes it from there.
///
/// Reductions are synchronous, so state moves in whole steps: no `await`
/// happens between an action being applied and the next one being read, and
/// there is no window in which the screen holds half of a change.
///
/// ## Two ways to send, and why
///
/// `send(_:) async` performs the effect chain in the caller's task, so it
/// inherits the caller's cancellation — `.task` and `.refreshable` cancel their
/// work when the view goes away, and a test awaits the whole cycle without
/// sleeping.
///
/// `send(_:)` is for a call site that cannot await: a `Button` action, a
/// `Binding` setter. It reduces *before it returns* — which is what makes it
/// usable behind a `TextField`, where a setter that deferred the change would
/// let the field snap back to the old value — and performs any resulting effect
/// in a task the store keeps. Swift picks the overload from the context, so a
/// button gets the first and an `await`ed call gets the second.
///
/// Nothing here cancels an effect, deliberately. The awaited path already
/// inherits cancellation from its caller. For the unawaited path there is
/// nothing to hang the decision on: the two effects that reach it in this app
/// are a profile write and an event publication, and abandoning either
/// mid-flight is worse than letting it finish. A feature whose fire-and-forget
/// effects *are* worth cancelling needs them keyed — see
/// `docs/unidirectional-data-flow.md`.
@Observable
@MainActor
final class Store<F: Feature> {

    /// Everything the view renders. Written only by `F.reduce`, and only from
    /// inside this type.
    private(set) var state: F.State

    /// The half of the feature that is allowed to talk to the world.
    @ObservationIgnored
    private let effects: any EffectHandling<F.Effect, F.Action>

    /// Effects started by the unawaited `send`, kept so `settled()` can wait
    /// for them.
    ///
    /// Each entry holds a task that holds this store, so a store with work in
    /// flight keeps itself alive — which is what lets a save that outlives its
    /// screen still land somewhere consistent. The cycle is not a leak: every
    /// task removes its own entry as its last statement.
    @ObservationIgnored
    private var inFlight: [UInt64: Task<Void, Never>] = [:]

    @ObservationIgnored
    private var nextEffectID: UInt64 = 0

    init(
        initialState: F.State,
        effects: any EffectHandling<F.Effect, F.Action>
    ) {
        self.state = initialState
        self.effects = effects
    }

    // MARK: - Sending

    /// Applies `action`, then performs the effect chain it started, returning
    /// when the chain is quiet.
    ///
    /// Cancelling the task that called this cancels the effect in flight, since
    /// the chain runs inside it.
    func send(_ action: F.Action) async {
        guard let effect = F.reduce(&state, on: action) else { return }
        await run(effect)
    }

    /// Applies `action` now and returns; any effect it started is performed in
    /// a task this store keeps.
    ///
    /// For call sites that cannot await — see the note on the type. The state
    /// change is finished by the time this returns; only the effect is not.
    func send(_ action: F.Action) {
        guard let effect = F.reduce(&state, on: action) else { return }

        let id = nextEffectID
        nextEffectID &+= 1

        // Registered before the body can run: `Task` schedules its closure, and
        // this method returns to the executor before any of it executes, so the
        // removal inside cannot race the insertion outside.
        inFlight[id] = Task { [self] in
            await run(effect)
            inFlight[id] = nil
        }
    }

    /// Waits for every effect started by the unawaited `send` to finish.
    ///
    /// The seam that makes the fire-and-forget path assertable: a test taps
    /// what a `Button` taps and then awaits this, rather than sleeping and
    /// hoping. Nothing in the app calls it — SwiftUI's own entry points all
    /// await `send` directly.
    func settled() async {
        while let task = inFlight.values.first {
            await task.value
        }
    }

    // MARK: - Private

    /// Performs `effect`, reduces whatever it reports, and repeats until
    /// nothing more is asked for.
    private func run(_ effect: F.Effect) async {
        var next: F.Effect? = effect
        while let current = next {
            guard let action = await effects.perform(current) else { return }
            next = F.reduce(&state, on: action)
        }
    }
}
