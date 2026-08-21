# The event bus

Phase 8 item 5, "Observer pattern: typed event bus on `AsyncStream`".

`EventBus` already existed when this item came up. It had `emit`, it had `events`,
it was `Sendable` by construction rather than by assertion, and it had five tests.
It also had **no caller anywhere in `Sources/`** — the same shape as
[`docs/solid.md`](./solid.md) finding 6, one layer over. A mechanism nothing runs
is a claim, and the way to stop it being one is to give it the job the app was
already doing by hand.

So this item is two changes: the bus became typed, and it acquired both ends of a
real path — publishers that mean something and a subscriber that does something.

## What the app was doing instead

The observer pattern was there, written out at the call sites. `LoginView`:

```swift
.onChange(of: viewModel.isAuthenticated) { _, authenticated in
    if authenticated { appState.isAuthenticated = true }
}
.onChange(of: socialViewModel.isAuthenticated) { _, authenticated in
    if authenticated { appState.isAuthenticated = true }
}
.onChange(of: biometricViewModel.isAuthenticated) { _, authenticated in
    if authenticated { appState.isAuthenticated = true }
}
```

plus a fourth assignment in the biometric button's success callback, which
duplicated the third. `SettingsView` had the other half: a Sign Out button
calling `appState.signOut()` directly.

Three observers watching three flags to perform one assignment is not a shape
worth keeping, but the duplication is the least of it. The defect is that **the
screen that noticed the change was the thing that had to know every consequence
of it**, so a consequence nobody thought of at that call site did not happen.
Two did not:

- **`AppState.currentUserEmail` was written by nothing.** It is declared, it is
  cleared by `signOut()`, and `SettingsView` renders it on the profile-fetch
  failure path. No sign-in ever set it, so that row read `"—"` in every session
  the app ever had. `SettingsView`'s own comment described it as "set by the
  login response", which it never was — the response carries the `User`, and both
  the password path and the social path threw it away.
- **Signing out left the tokens on the device.** `AppState.signOut()` clears two
  properties and `RootView` swaps to `LoginView`. That looks like a sign-out. The
  access and refresh tokens were still in the Keychain, so the next authenticated
  request would have succeeded and the next person to pick up the device would
  have inherited the session.

Both fixes live in `SessionObserver` now, and neither of them is something a view
should have been holding.

## Why a bus, and not a call

A bus is worth its indirection when one thing that happened has consequences in
places that should not know about each other. `UserSignedOut` has exactly that
shape: it updates SwiftUI state **and** clears the Keychain, in two layers, and
the Settings screen that announces it should know about neither. `UserSignedIn`
is the same argument in a weaker form today — one subscriber, two effects — and
the shape it makes possible is the point: an analytics sink, a push-token
registration, a cache warm-up are each a subscription, not an edit to the login
screen.

Where that argument does *not* apply, this package does not use the bus. A view
model still calls its repository directly. A strategy still calls its store. An
event bus used for a request that expects an answer is a call with the caller
erased, which is worse than the call.

## What "typed" means here

The old bus vended one `AsyncStream<AppEvent>` over an enum of every case:

```swift
for await event in bus.events {
    switch event {
    case .userLoggedOut: handleLogout()
    default: break            // ← every other event in the app
    }
}
```

Every subscriber received everything and filtered its way back to the one case it
wanted. That is what an untyped `NotificationCenter` obliges you to do, and the
whole claim of a typed bus is that the filter is the type:

```swift
for await event in bus.events(of: UserSignedOut.self) { handleLogout() }
```

`AppEvent` is now a protocol whose single requirement is `Sendable`, and each
event is its own type. Subscriptions are bucketed by the `ObjectIdentifier` of
the event type, so publishing touches only the bucket for the type published
rather than waking every subscriber to ask whether this one is for them.

**The cost, stated.** There is no exhaustive `switch` over "every event in the
app" any more, so adding an event breaks no build and reminds nobody. That is the
same trade `Notification.Name` makes, minus the untyped payload. It is the right
one here because no subscriber wants every event — `SessionObserver` wants two,
separately — and a shared enum makes adding a third event an edit to a type that
unrelated features depend on. [`docs/solid.md`](./solid.md)'s open/closed section
used to list `AppEvent` among the closed enums that were fine; that paragraph has
been rewritten rather than left standing.

## Subscribing is synchronous, and that is the contract

`events(of:)` builds its stream *and registers it* before it returns. So this is
guaranteed to see the event:

```swift
let stream = bus.events(of: UserSignedIn.self)   // registered here
Task { for await event in stream { … } }         // has not run a line yet
bus.publish(UserSignedIn(method: .password, email: nil))   // still delivered
```

and this is guaranteed to race:

```swift
Task { for await event in bus.events(of: UserSignedIn.self) { … } }
bus.publish(…)   // the Task may not have reached `events(of:)` yet
```

The difference is where the subscription is *created*, not where it is consumed.
It is worth stating because the second shape is the natural one to write and the
old `EventBusTests` wrote it in all five of its tests, papering over the race each
time with `Task.sleep(for: .milliseconds(10))`. `SessionObserver.start()` takes
the first shape deliberately: both `events(of:)` calls happen on the caller's
thread, and only then are the two tasks created.

The same property is what makes the current tests deterministic. They subscribe,
publish, call `finish()` — which ends every live subscription — and then drain the
stream to its end. What comes back is everything that was published to that
subscription, in order, and an empty array means nothing was rather than that
nothing had arrived yet. No test in this area sleeps, and a broken bus fails them
instead of hanging them.

## Buffering

The default is `.unbounded`, which `DelegateStream` argues at length is not a
default. It is right about the producer *it* bridges: a capture device yields at
the rate the hardware runs and cannot be told to stop, so the only question is
where the backlog goes.

This producer is the opposite. Every event on this bus is published because a
person tapped something — a handful in a session, never a burst — and each one
carries a consequence a subscriber must not miss. `.bufferingNewest(n)` would
trade a leak that cannot happen for a `UserSignedOut` silently discarded, which
leaves the app showing a signed-in screen with no session behind it. The policy
is still a parameter, so an event type with a real rate can pick one; the default
is the claim that these do not have one.

## Who publishes what

| Event | Published by | Consumed by |
| --- | --- | --- |
| `UserSignedIn(method: .password, email:)` | `LoginViewModel.login()` | `SessionObserver` |
| `UserSignedIn(method: .apple/.google, email:)` | `SocialLoginViewModel` | `SessionObserver` |
| `UserSignedIn(method: .biometric, email: nil)` | `LoginView`'s biometric button | `SessionObserver` |
| `UserSignedOut()` | `ProfileViewModel.signOut()` | `SessionObserver` |

Three of the four are announced by the view model that did the work. The
biometric one is announced by the *screen*, and that is deliberate: a successful
Face ID evaluation means "this is the device's owner", and whether that begins a
session or merely re-confirms one depends on who asked. `BiometricAuthButton` is
a reusable component — `AuthPreviews` builds it standalone — and a version of it
guarding a destructive action would unlock that action and announce nothing. So
`BiometricAuthViewModel` stays a view model that answers a yes/no question, and
`LoginView`, which knows the answer means a session began, is what says so.

`UserSignedIn.email` is optional for the same reason. A biometric unlock learns
no identity, so `nil` there means "this flow did not find out" rather than "there
is no address", and `SessionObserver` reads it that way: it never writes `nil`
over an address a previous sign-in established.

## What this item did not do

Recorded rather than deferred to an item that would not have done them either.

- **`UserSignedOut` carries no reason.** `.userInitiated` beside `.sessionExpired`
  is the obvious second field, and only one thing publishes this event: the Sign
  Out button. Expiry does not go through the bus — `TokenStore.refreshIfNeeded`
  clears the pair when a refresh fails and tells nobody, so the app keeps showing
  a signed-in UI over a session that has gone. That is a real gap and a
  transport-layer one, in the same neighbourhood as `docs/decorators.md`'s note
  that the 401 refresh still lives in transport. A case nothing can construct
  would have described the app as it is not.
- **`AuthServiceProtocol.login` still returns `Bool`.** `LiveAuthService` has the
  `LoginResponse` in hand, complete with its `User`, and discards it to answer
  `true`. So the password path publishes the address the *request* was made with
  rather than the one the server confirmed. The social path, which had the same
  `_ =` discard, now binds the response and publishes the server's address.
  Widening the auth contract is a change to the package's vocabulary, not to an
  event.
- **`AppState` still holds `isAuthenticated` and `currentUserEmail` as
  independent properties.** The observer keeps them consistent; nothing makes
  them consistent by construction. A `Session` enum with `.signedOut` and
  `.signedIn(email: String?)` would, and it is a change to the state model rather
  than to the observer that writes it.
- **`HomeViewModel` still fabricates its list with a `Task.sleep`.** The old enum
  had an `itemRefreshRequested` case with no publisher and no subscriber; it is
  gone rather than carried forward, because an event nothing sends and nothing
  receives is the thing this item exists to stop shipping.
