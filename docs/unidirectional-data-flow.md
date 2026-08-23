# Unidirectional data flow

Phase 8 item 6, "Unidirectional data flow: single `State` + `Action` + `Effect`
contract per feature".

Three types, one function, and one object that runs them:

```
        ┌──────────────────────────────────────────────┐
        │                                              │
     Action                                            │
        │                                              │
        ▼                                              │
  ┌───────────┐   Effect?   ┌───────────────┐   Action?│
  │  reduce   │────────────▶│ EffectHandling│──────────┘
  │  (pure)   │             │  (the world)  │
  └───────────┘             └───────────────┘
        │
      State  ───▶  the view
```

`reduce` is a `static` function from `(inout State, Action)` to `Effect?`. It is
the only thing in the app allowed to change a screen's state. It cannot await,
cannot fail and cannot reach a collaborator — `static` leaves it nothing to
reach *from* — so everything it does is decide. A decision that needs the
network is spelled as an effect, and the answer comes back as another action.

`Store` is what a view holds instead of a view model. It is `@Observable` and
`@MainActor`, like the view models were, and it differs in the one way that
matters: **it has no methods that change state.** It has `send`.

## What this replaced, on the screen it replaced it on

`ProfileViewModel` — the Account section of Settings — kept the screen in five
independent stored properties:

```swift
private(set) var state: LoadingState<User> = .idle
private(set) var origin: SyncOrigin?
private(set) var isSaving = false
private(set) var saveErrorMessage: String?
var draftName = ""
```

Nothing but discipline kept them agreeing. `origin` described the provenance of
the user in `state`, and the pairing existed only inside the two private methods
that assigned both; a third method assigning one of them would have been a
screen claiming a cached profile was live, with no compile error and no failing
test. That is not a hypothetical shape — `SyncOrigin` exists precisely because
"an offline screen silently presenting stale data as live data" is the failure
this feature was built to avoid.

Under the contract the screen is one value, and three of those agreements are
now unrepresentable rather than merely maintained:

- **`origin` is gone as a property.** `SyncedUser` already pairs a user with its
  provenance, so `Phase.loaded(SyncedUser)` holds one value where there used to
  be two that could describe different users.
- **A refresh no longer blanks the screen.** `Phase.loading(previous:)` carries
  what was on screen when the reload started. The old `load()` assigned
  `.loading` first, which is why it had to capture `hasUneditedDraft` *before*
  the assignment: the information it needed was about to be destroyed.
- **"The reader has edited the name" is a stored fact.** It used to be inferred
  by comparing `draftName` against the loaded user's name, which answers "the
  draft differs" — a different question, and the wrong one for a reader who
  cleared the field or typed the same name back.

The view got smaller in the same move. `SettingsView` renders from derived
properties of one state rather than switching over a `LoadingState` and reading
four more properties inside one of its branches, and every gesture in it is one
`send` — there is no call in that file that changes what the screen shows.

## What is testable that was not

`ProfileFeatureTests` keeps every assertion `ProfileViewModelTests` made. What
is new is the half that needs nothing built first:

```swift
var state = ProfileFeature.State(phase: .loaded(synced(name: "Before")))
_ = ProfileFeature.reduce(&state, on: .draftNameEdited("  After  "))

#expect(ProfileFeature.reduce(&state, on: .saveTapped) == .saveName("After"))
```

No store, no double, no `await`, no main actor. `Feature.State` is `Equatable`
for the assertion that comes with it — "this action changed nothing" is one
`#expect` over the whole value rather than one per property, which is how a
reducer that quietly clears a field gets caught.

`Sendable` needs no audit row here either: `Feature` requires it of all three
associated types, so a state that stops being `Sendable` stops conforming.

## Decisions

**At most one effect per action.** `reduce` returns `Effect?`, not `[Effect]`.
One action means one consequence; a reducer reaching for two is usually an
action that means two things and wants splitting. The cost, stated plainly: a
feature that genuinely needs a pair has to name the pair in an effect case, and
if one ever needs *concurrent* fan-out the honest change is to widen this return
type rather than to nest a composite case inside another.

**Two ways to send, overloaded on `async`.** `send(_:) async` performs the
effect chain in the caller's task, so `.task` and `.refreshable` cancel their
work when the view goes away and a test awaits the whole cycle without sleeping.
`send(_:)` is for a call site that cannot await — a `Button` action, a `Binding`
setter — and it reduces *before it returns*, which is what makes it usable
behind a `TextField`: a setter that scheduled the change instead of making it
would let the field render the value from before the keystroke.

Swift picks the overload from the context, which is right at every call site in
the app and wrong in exactly one place: inside an `async` test, the awaited
version wins even when the point is to leave the effect unawaited. Both suites
send from a small synchronous `tap(_:on:)` helper there, which is also a fair
model of what a `Button` action closure is.

**Nothing here cancels an effect.** The awaited path inherits cancellation from
its caller. The unawaited path deliberately offers none: the two effects that
reach it in this app are a profile write and an event publication, and
abandoning either mid-flight is worse than letting it finish. A feature whose
fire-and-forget effects *are* worth cancelling needs them keyed — an identifier
on the effect, a table of tasks in the store, a new one cancelling the old — and
that is a real design, not a line to add in passing.

**The handler does not throw.** A failure is something the screen has to say, so
it is an action. A handler that could throw would open a second way out of an
effect that the reducer never sees, and the state left behind by the action that
started it — an `isSaving` that stays `true` — would be the state the screen
keeps.

## Known gaps

- **Two in-flight reads are not ordered.** The store applies actions in the
  order their effects complete, so an `.appeared` load that is slower than a
  `.refreshRequested` one lands last and wins. `ProfileViewModel` had the same
  defect and this item does not fix it. The fix is a request generation carried
  in the state and checked in the reducer — the same argument `LatestOnlyTask`
  makes about deciding by generation rather than by cancellation, moved into a
  place where it is data rather than a class. Nothing here is search-as-you-type,
  which is why it is recorded rather than done.
- **One feature is converted.** `HomeViewModel`, `LoginViewModel`,
  `SocialLoginViewModel`, `BiometricAuthViewModel`, `TextRecognitionViewModel`
  and `BarcodeScannerViewModel` are still `@Observable` view models. The item
  says "per feature", and this is the feature it was demonstrated on — the one
  with a real data path and the one whose properties could disagree.
  `HomeViewModel` in particular should not be converted before it has a
  repository: `docs/solid.md` finding 6 is that it fabricates its list with a
  `Task.sleep`, and a UDF contract over invented data would be a shape with
  nothing behind it.
- **`ViewModelProtocol` is untouched.** `onAppear`/`onDisappear` is the view
  models' lifecycle, and a store has no need for it: appearing is an action.
  The protocol stays because five view models still conform to it.

## Where the pins are

| Claim | Test |
| --- | --- |
| The reducer runs with nothing but a state and an action | `StoreTests.reducerNeedsNothingButAState` |
| An awaited send returns once the chain is quiet | `StoreTests.awaitedSendReturnsWhenQuiet` |
| The unawaited send has already reduced when it returns | `StoreTests.unawaitedSendReducesBeforeItReturns` |
| `settled()` waits for an effect the caller never awaited | `StoreTests.settledWaitsForTheUnawaitedPath` |
| An effect's answer is reduced, and its next effect performed | `StoreTests.theChainRunsToQuiescence` |
| A handler that reports no action ends the chain | `StoreTests.aHandlerCanReportNothing` |
| An ignored action leaves the state exactly as it was | `ProfileFeatureTests.anIgnoredActionChangesNothing` |
| A refresh keeps the loaded user, and its provenance, on screen | `ProfileFeatureTests.aRefreshKeepsWhatItIsReplacing` |
| Reading goes through the strategy the root resolved | `ProfileFeatureTests.appearingReadsThroughTheStrategy` |
| Refreshing asks the factory for a network-going policy | `ProfileFeatureTests.refreshAsksTheFactoryForRemoteFirst` |
| A reload does not clobber an edit in progress | `ProfileFeatureTests.reloadDoesNotClobberAnEdit` |
| Saving sends the trimmed name and adopts the result | `ProfileFeatureTests.savingSendsTheTrimmedName` |
| A failed save reports itself and keeps the loaded user | `ProfileFeatureTests.failedSaveReportsItself` |
| The button's unawaited send still announces the sign-out | `ProfileFeatureTests.signOutAnnouncesTheEndOfTheSession` |
