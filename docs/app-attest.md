# App Attest: proving the request came from this app

Certificate pinning decides what this app will accept as the server. App Attest
is the mirror: it is how the server decides what it will accept as this app.

The two are worth keeping straight, because attestation is routinely described
as if it were authentication and it is not. An access token says *who* is
asking. An assertion says *what* is asking — a genuine, unmodified install of
this app, on a real device, holding a key that was certified by Apple and has
never left the Secure Enclave. Neither answers the other's question, and an app
that has both makes a scripted client holding a stolen token useless.

## The shape of it

Three moving parts, and they happen at different rates.

**Once per install.** `DCAppAttestService.generateKey()` creates a key pair in
the Secure Enclave and hands back an identifier — the only handle to it, since
there is no enumeration API. `attestKey` then asks Apple to certify that the
key belongs to a genuine install of this app ID, producing a CBOR attestation
object. The app posts that to `POST /attest/key`, the server verifies it
against Apple's App Attest root and stores the public half against the
identifier. `AppAttestor` does this behind one `Task` that concurrent callers
await, because two registrations racing would leave one certified key stored
and another orphaned in the Enclave.

**Once per request.** `POST /attest/challenge` returns a one-time challenge.
The app builds the canonical client data (below), hashes it, and asks the
Enclave for an assertion over that hash. The assertion, the challenge, the key
identifier and a format marker go out as four headers.

**Once per failure.** A failed attempt opens a breaker for
`AppAttestor.defaultCooldown` seconds. Without it, an app whose attestation
endpoints are down pays for a guaranteed-failing round trip in front of every
real request.

## What the assertion is actually a statement about

This is the part that decides whether attestation is worth having, and it is
the part App Attest itself does not decide for you: the framework signs 32
bytes and has no opinion about what they are a hash of.

An assertion over nothing but a nonce proves a request came from a genuine
install and proves *nothing about which request*. Anyone able to see this app's
own traffic can then lift the four headers off a harmless `GET` and staple them
to a `POST` that moves money, and the server verifies it happily. So
`AttestationClientData` binds the request:

```
attest/v1
POST
/v1/transfers
currency=GBP&to=12345
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
Y2hhbGxlbmdlLWZyb20tdGhlLXNlcnZlcg==
```

Six lines joined with `\n`, UTF-8, SHA-256'd. Method uppercased; the path
exactly as it appears in the request line, base URL prefix included; the query
string as sent, an empty line when there is none; the body as lowercase hex
SHA-256 — the digest of the empty string for a body-less request, so that "no
body" and "empty body" are the same request; then the challenge verbatim.

The body is hashed rather than included because the server already holds the
bytes, and a multi-megabyte upload should not become a multi-megabyte string in
memory twice.

`AttestationClientDataTests` pins that layout as a literal rather than
rebuilding it from the same fields, because a test that rebuilt it would pass
through exactly the change that breaks a deployed server.

### The version marker is inside the signature, not just in the header

`X-Attest-Format` carries `attest/v1` so the server knows which reconstruction
to attempt before doing any work. But a header is attacker-controlled: a server
that picks its verification format from an attacker-supplied string has handed
over the choice of which fields are covered, and a downgrade to a version that
omitted the body would remove the binding entirely. The marker is therefore the
first line of the signed bytes as well. **A server implementing more than one
version must refuse any version it does not accept before it verifies
anything.**

## The headers

| Header | Contents |
| --- | --- |
| `X-Attest-Format` | `attest/v1` — advisory; the signed copy is authoritative |
| `X-Attest-Key-Id` | the key identifier the server verified at registration |
| `X-Attest-Challenge` | the challenge these bytes are bound to |
| `X-Attest-Assertion` | base64 of the CBOR assertion object |

They are declared once, in `AttestationHeaderField`, and
`Tools/assert-request-attestation.py` fails any other file that spells one out.
A header set under one name and read under another looks exactly like
attestation that has not been switched on yet.

## What the server has to do

Nothing here works without a server, and this repository cannot ship one. The
endpoints are `POST /attest/challenge` and `POST /attest/key`, relative to the
app's base URL. Both are unauthenticated on purpose: attestation proves the
app, not the user, and requiring an access token to attest would leave sign-in
— the request an attacker most wants to forge — as the one request that cannot
be attested.

The registration is the one exception to "rebuild it from the request": its
client data names the bare `/attest/key` constant rather than the full path,
because registration is a body the server parses rather than a URL it has to
canonicalise, so there is no base-URL prefix for the two ends to agree on. The
six lines are exactly:

```
attest/v1
POST
/attest/key

e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
<the challenge from the registration body>
```

For registration the server must, following Apple's *Validating Apps That
Connect to Your Server*: verify the attestation certificate chain to Apple's
App Attest root; check that the nonce inside it is
`SHA256(authenticatorData ‖ clientDataHash)` for the client data *it* rebuilds,
not the client's word for it; check the app ID hash and that the counter is 0;
and store the public key and counter against the key identifier.

For each request it must: confirm the challenge is one it issued, is unspent
and is unexpired; rebuild the canonical client data from the request it
actually received; verify the assertion's signature against the stored public
key; and **refuse any assertion whose counter is not strictly greater than the
last one accepted for that key.** That last check is what makes a captured
assertion useless a second time, and it is the reason the 401 retry in
`URLSessionAPIClient` re-attests rather than copying the first delivery's
headers — a copied assertion is a replay, and a server doing this correctly is
right to reject it.

## Rolling it out

`AppContainer` ships `.reportOnly`, and that is a rollout position rather than
a weaker feature. The mechanism is complete; what is missing is the only thing
a template cannot supply, which is a server that issues challenges and verifies
assertions. Against `api.example.com`, a host that does not exist, `.enforced`
would be an app that cannot send a single request.

In order:

1. **Ship the server endpoints first**, verifying assertions and *logging*
   rather than rejecting. A client that enforces before the server verifies has
   built an outage with no upside.
2. **Ship the client in `.reportOnly`.** Watch the `app-attest` category in the
   unified log — `OSLogAttestationReporter` files a line per registration, per
   failure and per invalidation. Registration failures at this stage are
   usually a bundle ID or team ID mismatch between the app and the server's
   expected app ID.
3. **Confirm on a device.** Everything above `AppAttestGenerating` is tested,
   and none of it touches the Secure Enclave: `DCAppAttestService.isSupported`
   is `false` on every simulator, so the CI suite exercises the unsupported
   branch and the four methods of `DeviceCheckAttestService` have never run in
   this repository. Before enforcing, confirm on hardware that a key registers,
   that an assertion verifies server-side, and that a reinstall produces one
   `DCError.invalidKey`, a replacement key, and a request that then succeeds.
4. **Turn the server to rejecting**, then set `attestation: .enforced` in
   `AppContainer.live`.

Know what `.enforced` costs before you take it: an App Attest outage at Apple,
a device that cannot attest, and a `/attest/challenge` that is down each become
a total loss of function rather than a degraded one.

## What this app does when it cannot attest

| Situation | `.reportOnly` | `.enforced` |
| --- | --- | --- |
| Simulator, or no Secure Enclave | sends unattested | `unsupportedDevice` |
| Challenge endpoint down | sends unattested, opens the breaker | `challengeUnavailable` |
| Server refuses the key | sends unattested, opens the breaker | `keyRejected` |
| `DCError.invalidKey` | discards the key, attests a new one, retries once | the same |
| Breaker open | sends unattested | `unattested`, with no round trip |

The `invalidKey` path is the one that is not configurable, because it is the
one that is always right: a key the framework will not sign with is a key to
throw away. It is bounded to a single replacement — a device that refuses a key
it has just issued cannot attest at all, and retrying that in a loop is a
request that never returns.

## Where the key identifier lives, and why

In the Keychain, under `afterFirstUnlockThisDeviceOnly` — the session tokens'
accessibility, because a background refresh has to attest with the device
locked and nobody there to authenticate.

Apple's own sample writes it to `UserDefaults`, and the argument for that is
real: the key dies with the install and so does `UserDefaults`, whereas a
Keychain item outlives a reinstall and leaves a stored identifier pointing at a
key that no longer exists. Two things decide it the other way here.
`ThisDeviceOnly` keeps the identifier off backups and out of a restore onto
another device, which is the case where a carried-over identifier is
*guaranteed* wrong. And the stale-identifier path has to exist either way — the
system can invalidate a key at any time — so handling `DCError.invalidKey` is
not optional, and once it is handled the reinstall case costs one refused
assertion rather than a broken install.

## What is deliberately not here

**A challenge cache.** Every attested request currently costs a challenge round
trip, which doubles the request count. A server issuing short-lived batches, or
accepting a client nonce plus a timestamp and leaning on the Enclave counter
for replay detection, would remove that cost — and each is a protocol decision
this template should not make on an adopter's behalf. `AttestationServing` is
the seam to make it behind.

**Per-endpoint attestation.** Every request the client sends is attested,
including the token refresh. Attestation is a transport-level property here, on
the grounds that a server which requires it anywhere is better served by a
client that produces it everywhere; an app that needs it on writes only should
add the flag to `APIEndpoint` beside `requiresAuth`.

**DeviceCheck's two bits.** The older `DCDevice` API — two bits of per-device
state that survive a reinstall, for tracking a device that has already claimed
a free trial — is a different feature with a different purpose, and nothing
here uses it.

**Any verification.** This is the client half. Nothing in this repository
checks a signature, and the tests use fixture bytes rather than real
attestations; `StubAppAttestService` reproduces App Attest's *protocol* — one
identifier per key, a counter that increments, a key that can be invalidated —
and none of its cryptography.

## Running the gates

```
python3 Tools/assert-request-attestation.py
```

Seven rules, each verified by reintroducing the defect it names: the transport
cannot default its way out of an attestor; exactly one call in it puts bytes on
the wire, and it is the attesting one; the transport never names a header field
itself, so a retry cannot copy a spent assertion; the header names live in one
file; the canonical client data still covers the format, method, path, query,
body and challenge; the attestation endpoints do not go through the client that
attests them; and the composition root states its enforcement out loud. It runs
in the lint job and needs no toolchain, so it also runs on Linux.
