# Where this app keeps its credentials

Phase 11 item 1: *Keychain access-control flags with biometric gating, never
`UserDefaults` for tokens.*

CLAUDE.md has stated that rule since the repo existed. Nothing checked it, and
half of it could not have been checked by reading the code: an item's access
control is not readable back out of the Keychain, so "stored with access-control
flags" was a claim about a line of source rather than a property of the running
app. This page is what the claim means now, and `Tools/assert-token-storage.py`
is what keeps it true.

## The policy is named at every write

`KeychainStoring` has one write:

```swift
func set(_ value: String, forKey key: String, policy: KeychainAccessPolicy) throws
```

There is no overload without a policy, and no default value for the argument.
That is deliberate and it is the whole design. `SecItemCopyMatching` does not
return `kSecAttrAccessControl`, and `SecAccessControl` exposes no public
accessor for its constraints, so an item written under
`afterFirstUnlockThisDeviceOnly` and an item written under
`biometryCurrentSet` are indistinguishable from inside the app that wrote them.
Nothing can audit the store after the fact. The call site is the only place the
protection is legible, so the call site has to say it, and a forgotten argument
has to be a build error rather than the weakest option.

## The policies

| Policy | Accessibility | Constraint | Where it is used |
| --- | --- | --- | --- |
| `afterFirstUnlockThisDeviceOnly` | after first unlock | none | both session tokens |
| `whenUnlockedThisDeviceOnly` | while unlocked | none | — |
| `userPresence` | passcode set | biometry **or** passcode | — |
| `biometryAny` | passcode set | any enrolled biometric | — |
| `biometryCurrentSet` | passcode set | the enrolled set, as at write time | — |
| `biometryCurrentSetOrPasscode` | passcode set | that set, **or** the passcode | the unlock record |
| `devicePasscode` | passcode set | passcode only | — |

Every gated policy rests on `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`,
which is not a stylistic choice. It is the one accessibility whose items are
destroyed when the user removes their passcode — the event that would otherwise
leave a "protected" item sitting there with no authentication left to perform.
It also keeps the item off backups, out of iCloud Keychain, and off a restored
device.

The consequence is the one to remember: **a device with no passcode cannot hold
a gated item at all.** `SecItemAdd` fails. Anything that treats that as fatal
has made passcode-less devices unable to sign in.

`biometryCurrentSet` versus `biometryAny` is the difference that matters for an
attacker who has the passcode: `biometryAny` accepts a face enrolled after the
item was written, `biometryCurrentSet` destroys the item instead. The app pairs
it with the passcode fallback (`biometryCurrentSetOrPasscode`) because
`biometryCurrentSet` alone locks a user out permanently when their biometry
stops working for reasons that have nothing to do with an attack.

## Session tokens are not gated, and that is the design

`TokenStore` writes both the access and the refresh token under
`afterFirstUnlockThisDeviceOnly` — no authentication. This is not the rule being
relaxed; it is what the rule can mean for an item read by machinery with nobody
in front of it. Two callers read these:

* the retry after a 401, which happens while the user waits on a screen, and
* `BackgroundRefreshCoordinator`, which the system launches while the phone is
  in a pocket.

`whenUnlocked` fails the second outright. An authentication constraint fails it
worse: before `KeychainWrapper` started attaching a non-interactive `LAContext`,
a gated read from a background task would have blocked waiting for a prompt on a
screen the app does not own. `afterFirstUnlockThisDeviceOnly` is the strongest
accessibility that survives both, and it still never leaves the device and never
enters a backup.

## The biometric unlock record

The gating the app actually has is a *second* copy of the refresh token, under
its own account name, written under `biometryCurrentSetOrPasscode`:

```swift
// AppContainer.live()
let tokenStore = TokenStore(keychain: keychain, biometricUnlock: .deviceOwner)
```

`BiometricUnlockPolicy` is the composition root's decision — `live()` turns it
on, `preview` leaves it off — and `TokenStore` owns the record's lifecycle:

* **written on every `setTokens`**, not only the first. A refresh rotates the
  refresh token, and a record still holding the previous one would authenticate
  the user successfully and then fail the exchange.
* **removed on `clearTokens`**. It is the one item that would otherwise survive
  a sign-out and let the next person holding the phone reach the account with a
  glance.
* **removed by `disableBiometricUnlock()`**, which is what a "stop using Face ID
  for this app" switch calls; the session survives it.
* **best effort.** A device with no passcode cannot hold it. That failure is
  recorded in `lastBiometricUnlockError` and does *not* fail `setTokens` —
  failing a sign-in that succeeded, on the devices least able to do anything
  about it, would be the opposite of the trade the record exists to make.

`.enabled(.afterFirstUnlockThisDeviceOnly)` reads as disabled. A second copy of
a credential is only worth its own key while it is harder to reach than the
first one; an ungated copy is strictly a second thing to steal.

Reading it goes through `TokenStore.biometricRefreshToken(reason:)`, which hops
off the actor with `OffMainActor.run` first. `SecItemCopyMatching` blocks its
thread for as long as the sheet is up — that is user time, not machine time, and
the store has other callers who should not queue behind somebody looking at
their phone. It is a hop rather than a fix: the thread it blocks is still one of
the cooperative pool's. Moving that read to a thread of its own is a change to
make when something other than one screen is calling it.

## Two details in `KeychainWrapper`

**An unauthenticated read never prompts.** `string(forKey:)` attaches an
`LAContext` with `interactionNotAllowed`, so a gated item answers
`errSecInteractionNotAllowed` — surfaced as `KeychainError.authenticationRequired`
— instead of putting a Face ID sheet in front of whatever happened to be
running. Asking for a gated item by mistake is then a caught error rather than a
prompt from a background task.

**A write is a delete followed by an add.** `SecItemUpdate` cannot change an
item's access control, and on a gated item it has to satisfy the existing one
first — so updating in place would both fail to apply a new policy and prompt
the user in the middle of a write. Deleting first makes `set` mean the same
thing whatever was there before.

`KeychainError` keeps the user's answer as an answer: `userCancelled` and
`authenticationFailed` are distinct from `unhandledError`, because a caller has
to be able to tell "they said no" from "the Keychain is broken" without matching
on integers.

## What the tests can and cannot show

`InMemoryKeychain` enforces the gate: it stores the policy with the value,
refuses an unauthenticated read of a gated item, counts the prompts it would
have shown, and can be told to fail a gated write (the passcode-less device) or
to refuse a prompt (`stubbedAuthenticationOutcome = .userCancelled`). A double
that ignored the policy would certify a bug — every test in the suite would pass
against a store where an unauthenticated read succeeds, and the device would be
the first thing to notice it does not.

What it cannot reproduce is everything that belongs to the daemon:

* an item destroyed by a biometric re-enrolment or by the passcode being removed;
* `errSecInteractionNotAllowed` coming back from a real background read;
* whether `SecItemAdd` accepts a given flag combination on a given OS version.

The last one is partly covered: `KeychainAccessPolicyTests` builds a real
`SecAccessControl` for every gated policy, so a combination the platform rejects
fails a test rather than a sign-in. The first two are untested here and are
honestly untestable without a device and a person; they are also why the record
is treated as disposable everywhere it is read.

## What is not done

* **Nothing calls `biometricRefreshToken(reason:)` in the app yet.** The record
  is written, rotated and cleared for real, and the read is exercised by tests,
  but the flow that would consume it — biometric sign-in exchanging the record
  for a fresh session — is not built. `LoginView`'s biometric button still
  publishes `UserSignedIn` on a successful `LAContext` evaluation alone, which
  is a session begun on a local check with no credential behind it. Closing that
  is its own item: it needs a view model, an exchange through the auth service,
  and a settings switch for the enrolment.
* **Enrolment is automatic rather than opt-in.** `live()` writes the record for
  every sign-in on a device that can hold one. It discloses nothing new — the
  refresh token is already on the device, and this copy is harder to reach than
  the original — but a user-facing switch is the right shape, and it arrives
  with the flow above.
* Certificate pinning is Phase 11 item 2 and is built — see
  [certificate-pinning.md](./certificate-pinning.md) for what is pinned, how the
  delegate decides, and the key-rotation procedure. It ships in report-only mode
  with placeholder pins, for the reasons that page gives.
* The rest of Phase 11 — App Attest, jailbreak heuristics, Fastlane Match, the
  privacy manifest, MetricKit — is untouched.

## Running the gate

```
python3 Tools/assert-token-storage.py
```

Six rules, each verified by reintroducing the defect it names: no credential in
a defaults-backed store, no credential written to a file, the token account
names confined to the store that owns them, exactly one `KeychainStoring` write
and it takes a policy, every Keychain write in the app naming one, and the
composition root still naming a `BiometricUnlockPolicy`. It runs in the lint job
beside the other four audits, needs no toolchain, and is one of the few gates
that can be run on Linux before pushing.
