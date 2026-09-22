# Certificate pinning, and how to rotate a pinned key

Phase 11 item 2: *Certificate pinning via `URLSessionDelegate` with a rotation
plan.*

Pinning is the easy half. Any app can refuse a certificate whose key it does not
recognise; the code is about eighty lines and this repository now has it. The
half that decides whether pinning is an improvement or a liability is what
happens on the day the pinned key changes — and it will change, because keys are
lost, CAs are compromised, load balancers are replaced and certificates are
re-issued by people who did not know a mobile app was counting on the key inside
them.

An app that pins without a rotation plan has built a remote kill switch and
handed the trigger to its own infrastructure team. This page is the plan.

## What is pinned

The SHA-256 of the DER-encoded `SubjectPublicKeyInfo` — the public key, with the
algorithm identifier that says what kind of key it is. Not the certificate.

That choice is the first thing that makes rotation survivable. A certificate is
a short-lived document: ninety days from a public CA today, and re-issued
immediately after any incident. The key inside it does not have to change when
the document does, and a server operator who renews with the same key produces a
new certificate the app has never seen and pins it already trusts. Pin the
certificate instead and every renewal — including the emergency ones — is a
forced app release.

It is the same value every tool prints, so a pin can be read off a live server
rather than transcribed from a build log:

```
openssl s_client -connect api.example.com:443 -servername api.example.com \
  | openssl x509 -pubkey -noout \
  | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary \
  | base64
```

`PublicKeyPin` recomputes that value from a `SecCertificate`, and it has to
rebuild the `SubjectPublicKeyInfo` to do it: `SecKeyCopyExternalRepresentation`
hands back the *raw* key — PKCS#1 for RSA, the uncompressed point for EC — and
neither is what the pipeline above hashes. `PublicKeyPinTests` compares the
result against that pipeline's output for an EC P-256 key, an EC P-384 key and
an RSA-2048 key, so the equivalence is measured rather than asserted.

## Which key in the chain

Any key in the chain the system built. The policy holds a set of pins and a
match anywhere in the chain satisfies it, which leaves the choice of *what* to
pin to whoever writes the policy:

| Pinning | Survives | Breaks on |
| --- | --- | --- |
| The leaf key | every certificate renewal that reuses the key | a new key pair |
| The issuing CA's key | every leaf change that CA signs | changing CA, or that CA rotating its intermediate |
| The root CA's key | almost everything | changing CA |

Leaf pinning is the strongest and the most brittle. Intermediate pinning is what
most teams end up with, and its weakness is worth stating: it trusts that CA to
never mis-issue for your domain, which is a smaller promise than trusting all
~150 roots in the system store but is not nothing.

This template pins leaf keys, because a boilerplate should demonstrate the
narrow version and because the rotation plan below makes leaf pinning
maintainable.

## The rotation plan

### Before you enforce anything

Generate **two** key pairs, not one.

```
openssl ecparam -name prime256v1 -genkey -noout -out primary.key
openssl ecparam -name prime256v1 -genkey -noout -out backup.key
```

The primary goes into the CSR that becomes your certificate. The backup goes
into a safe — an HSM, a sealed secret, an offline USB key in a drawer, in
descending order of seriousness — and **is never presented to a client until it
has to be**. It appears in no certificate. It is a key that exists only so that
its pin can be shipped.

Compute both pins and put them in the policy:

```
openssl pkey -in primary.key -pubout -outform der | openssl dgst -sha256 -binary | base64
openssl pkey -in backup.key  -pubout -outform der | openssl dgst -sha256 -binary | base64
```

`PinSet` has no initialiser that takes one pin. `CertificatePinningPolicy.problems(at:)`
reports a backup that repeats the primary, and a test runs that audit over the
policy this app ships — so a pin set that cannot rotate cannot be released.

### Rolling out

1. **Ship the pins in `reportOnly`.** The connection proceeds on the system's
   own verdict and every mismatch is reported through `PinningReporting`.
2. **Watch for a full release cycle.** You are looking for a mismatch rate that
   is zero, and for the reasons it might not be. All of these are real, none of
   them is visible from a developer's desk, and each is an outage if the first
   thing that counts it is enforcement:
   * a CDN or load balancer serving a second certificate from some edges;
   * a corporate TLS-inspecting proxy, which is a deliberate man in the middle
     that your enterprise users have consented to;
   * a staging or canary host sharing the pinned hostname;
   * an old app version whose pins were never updated.
3. **Turn on `enforced`** once the rate is zero and stays zero.

Steps 1 and 3 are the same field. There is no separate rollout mechanism,
because a rollout mechanism nobody uses is the reason report-only modes get
skipped.

### The rotation itself

The day the primary key has to go — compromise, loss, a CA that will not reissue
against the same key:

1. **Issue a certificate for the backup key.** It is already pinned by every
   installed copy of the app, so this step needs no release and no coordination
   with the App Store.
2. **Deploy it.** Installed apps accept it immediately: `PinSet.all` contains the
   backup, and a match anywhere in the set is a match. `CertificatePinningDelegateTests`
   has this case — a chain carrying only the backup key is pinned, with no app
   update — because it is the one property of this design that cannot be read
   off the code.
3. **Generate a new backup key** and put it in the safe.
4. **Ship a release** whose policy is `primary: <the old backup>, backup: <the
   new one>`. Until it rolls out, installed copies are running on a set with one
   usable key, which is exactly the situation step 1 of "before you enforce
   anything" exists to prevent. Treat it as an incident-closing task, not a
   backlog item.

Optionally, during a planned migration, put the outgoing key in `additional` so
that both are accepted while traffic moves. Empty it again afterwards: a pin set
that accumulates keys accepts more issuers over time, which is the opposite of
what pinning is for.

### The expiry

Every `HostPinningPolicy` carries an expiry, and past it the app stops enforcing
and falls back to ordinary system trust. That is deliberate, and it is the
failure valve.

Pins are a claim about a key, made at build time, frozen into copies of the app
that may never be updated again. Without an expiry, the oldest installed build
enforces its pins forever — so a rotation eventually strands every user who
stopped updating, silently, months later, with no fix that does not involve the
App Store. An app that has quietly stopped pinning is a much better outcome than
an app that cannot connect.

`CertificatePinningPolicy.maximumPinLifetime` caps it at a year, because an
expiry nobody will live to re-check is not a valve. The date is baked into the
build rather than computed from "now" at launch, for the same reason: a pin set
whose expiry is a year from launch never expires.

## What the delegate does, in order

`CertificatePinningDelegate.decision(forHost:authenticationMethod:trust:)`:

1. Not a server-trust challenge, or not a host in the policy → hand it back to
   the system untouched. A pinning delegate that answers challenges it has no
   opinion about has quietly taken over client certificates and HTTP
   authentication too.
2. Pins expired → hand it back to the system, and report it.
3. **Evaluate the chain against the system's anchors.** A failure here is fatal
   regardless of the pins.
4. Match any key in the built chain against the policy's pins.
5. No match → refuse under `enforced`; under `reportOnly`, report it and fall
   back to the system's verdict, which is already known to be "valid".

Step 3 before step 4 is the whole correctness argument. The inverted version —
match a pin, return `.useCredential`, never evaluate — is the most common way
pinning is implemented wrongly, and it replaces the device's trust store with a
list of two hashes: an expired certificate, a revoked one, or one issued for a
different hostname all sail through as long as the key matches. It is a two-line
difference and every happy-path test of it passes, so
`Tools/assert-pinned-sessions.py` checks the order statically and
`CertificatePinningDelegateTests` checks it behaviourally.

## Why a delegate and not `NSPinnedDomains`

Apple ships pinning in the Info.plist, under `NSAppTransportSecurity` →
`NSPinnedDomains`. It is evaluated by the system, it needs no code, and for many
apps it is the right answer. It is not the one here:

* **It pins CA certificates, not leaves.** `NSPinnedLeafIdentities` exists but
  Apple's guidance is to pin an issuer; the narrow case this template
  demonstrates is not what the plist is shaped for.
* **There is no report-only mode.** The rollout above — ship, watch, enforce —
  has no plist equivalent. It is enforce or nothing.
* **There is no telemetry.** A plist-pinned connection that fails looks like any
  other TLS failure, from inside the app and from the log. `PinningReporting` is
  the difference between "the network is down" and "our CDN's third edge is
  serving a different certificate".
* **It still needs a backup pin and still needs an expiry**, both of which it
  supports — so the plan on this page applies either way. What changes is only
  where the pins are written down.

If an adopter wants the plist version, the policy in `AppContainer` is the list
of pins to copy into it, and everything above about rotation still holds.

## What this app ships

`AppContainer.defaultPinningPolicy` pins `api.example.com` — the placeholder
host in `defaultBaseURL` — with placeholder pins, in `reportOnly`.

The pins are `SHA256("boilerplate-ios-swift placeholder primary pin")` and the
same for `backup`. No key hashes to either, which is the point: they are named
constants (`PublicKeyPin.placeholders`) and `problems(at:)` refuses to let a
policy containing one be *enforced*. An adopter who flips `enforcement` to
`.enforced` without first replacing the pins fails the test suite rather than
shipping an app that can reach nothing at all — the symptom of which would be an
ordinary TLS failure that says nothing about pinning.

So `reportOnly` here is the rollout position, not a weaker version of the
feature. The mechanism is complete and enforcing is one field away; the only
missing ingredient is the one a template cannot supply, which is the pin of a
key belonging to a server that exists.

## What is deliberately not here

* **No pin delivery over the network.** HPKP tried it and was removed from the
  web platform for the reason above: a pin set an attacker can plant is a
  denial-of-service primitive, and a pin set delivered over the connection it
  protects is circular.
* **No OCSP or CRL checking beyond what the system does.** `SecTrustEvaluateWithError`
  applies the platform's revocation policy; pinning does not add to it.
* **No certificate transparency check.** The system applies its CT policy to
  publicly-trusted chains already, and re-implementing it here would be a second
  answer to a question the OS has answered.

## Running the gates

```
python3 Tools/assert-pinned-sessions.py
```

Four rules, each verified by reintroducing the defect it names: sessions are
built in one file only, nothing reaches for `URLSession.shared` (which takes no
delegate and therefore cannot be pinned), the transport has no session default a
caller could silently accept, and the delegate evaluates system trust before it
accepts a pin. It runs in the lint job beside the other audits, needs no
toolchain, and is one of the few gates that can be run on Linux before pushing.

The behavioural half is `CertificatePinningTests`, `CertificatePinningDelegateTests`
and the fixtures in `CertificatePinningFixtures.swift`, which run on the
simulator with the rest of the suite.
