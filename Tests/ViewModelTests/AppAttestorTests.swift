import Foundation
import os
import Testing
@testable import Core
@testable import Networking

// MARK: - Helpers

private let attestedURL = URL(string: "https://api.example.com/v1/users")!

private func makeRequest(method: String = "GET", body: Data? = nil) -> URLRequest {
    var request = URLRequest(url: attestedURL)
    request.httpMethod = method
    request.httpBody = body
    return request
}

/// A clock a test can move, since the breaker below is the one behaviour that
/// is about elapsed time and a test that slept for it would be a test that
/// takes a minute.
private final class TestClock: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000_000))

    var now: @Sendable () -> Date {
        { [state] in state.withLock { $0 } }
    }

    func advance(by seconds: TimeInterval) {
        state.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    var currentDate: Date { state.withLock { $0 } }
}

private struct Fixture {
    let service = StubAppAttestService()
    let server = StubAttestationService()
    let keychain = InMemoryKeychain()
    let reporter = RecordingAttestationReporter()
    let clock = TestClock()

    func makeAttestor(
        enforcement: AttestationEnforcement = .reportOnly,
        cooldown: TimeInterval = 60
    ) -> AppAttestor {
        AppAttestor(
            service: service,
            server: server,
            keychain: keychain,
            reporter: reporter,
            enforcement: enforcement,
            cooldown: cooldown,
            now: clock.now
        )
    }
}

// MARK: - The key lifecycle

@Suite("App Attest — the key")
struct AppAttestorKeyTests {

    @Test("The first request registers exactly one key, and stores its identifier")
    func firstRequestRegistersAKey() async throws {
        let fixture = Fixture()
        let attestor = fixture.makeAttestor()

        let attestation = try #require(await attestor.attestation(for: makeRequest()))

        #expect(fixture.service.keysIssued == 1)
        #expect(fixture.server.registrations.count == 1)
        #expect(fixture.server.registrations.first?.keyID == attestation.keyID)
        let stored = try fixture.keychain.string(forKey: AppAttestor.Keys.keyIdentifier)
        #expect(stored == attestation.keyID)
    }

    /// The identifier is not a credential, but it is device-bound state, and
    /// `afterFirstUnlockThisDeviceOnly` is the only accessibility that both
    /// stays off a restore onto another device and is readable by a background
    /// refresh with nobody in front of the phone.
    @Test("The identifier is stored under the session tokens' accessibility")
    func identifierIsStoredUngatedAndDeviceOnly() async throws {
        let fixture = Fixture()
        let attestor = fixture.makeAttestor()

        _ = try await attestor.attestation(for: makeRequest())

        #expect(
            fixture.keychain.policy(forKey: AppAttestor.Keys.keyIdentifier)
                == .afterFirstUnlockThisDeviceOnly
        )
    }

    @Test("A second request reuses the registered key")
    func secondRequestReusesTheKey() async throws {
        let fixture = Fixture()
        let attestor = fixture.makeAttestor()

        let first = try #require(await attestor.attestation(for: makeRequest()))
        let second = try #require(await attestor.attestation(for: makeRequest()))

        #expect(first.keyID == second.keyID)
        #expect(fixture.service.keysIssued == 1)
        #expect(fixture.server.registrations.count == 1)
    }

    /// A fresh attestor with the identifier already in the Keychain is the
    /// second launch of the app, which must not attest a second key.
    @Test("A stored identifier survives the process")
    func storedIdentifierIsReused() async throws {
        let fixture = Fixture()
        _ = try await fixture.makeAttestor().attestation(for: makeRequest())

        let relaunched = fixture.makeAttestor()
        _ = try #require(await relaunched.attestation(for: makeRequest()))

        #expect(fixture.service.keysIssued == 1)
        #expect(fixture.server.registrations.count == 1)
    }

    /// The property the `inflightRegistration` task exists for. Actor isolation
    /// serialises entry to the method, not the awaits inside it, so a version
    /// that simply awaited the registration inline would attest one key per
    /// concurrent caller and leave all but one orphaned in the Enclave.
    @Test("Concurrent first requests share one registration")
    func concurrentRequestsCoalesce() async throws {
        let fixture = Fixture()
        let attestor = fixture.makeAttestor()

        let keyIDs = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let attestation = try? await attestor.attestation(for: makeRequest())
                    return attestation?.keyID
                }
            }
            var collected: [String] = []
            for await keyID in group {
                if let keyID { collected.append(keyID) }
            }
            return collected
        }

        #expect(keyIDs.count == 8)
        #expect(Set(keyIDs).count == 1)
        #expect(fixture.service.keysIssued == 1)
        #expect(fixture.server.registrations.count == 1)
    }

    @Test("Resetting forgets the key, so the next request registers another")
    func resetForgetsTheKey() async throws {
        let fixture = Fixture()
        let attestor = fixture.makeAttestor()

        _ = try await attestor.attestation(for: makeRequest())
        await attestor.reset()
        _ = try await attestor.attestation(for: makeRequest())

        #expect(fixture.service.keysIssued == 2)
        let stored = try fixture.keychain.string(forKey: AppAttestor.Keys.keyIdentifier)
        #expect(stored != nil)
    }

    // MARK: - Invalidation

    @Test("A key DeviceCheck refuses is discarded and replaced, once")
    func invalidKeyIsReplaced() async throws {
        let fixture = Fixture()
        let attestor = fixture.makeAttestor()

        let first = try #require(await attestor.attestation(for: makeRequest()))
        fixture.service.invalidate(first.keyID)

        let second = try #require(await attestor.attestation(for: makeRequest()))

        #expect(second.keyID != first.keyID)
        #expect(fixture.service.keysIssued == 2)
        #expect(fixture.reporter.events.contains(.keyInvalidated(keyID: first.keyID)))
    }

    /// The bound on the replacement. A device that refuses every key it has
    /// just issued is a device that cannot attest, and retrying in a loop turns
    /// that into a request that never returns.
    @Test("A second refusal is a failure rather than another replacement")
    func invalidKeyIsNotReplacedTwice() async throws {
        let fixture = Fixture()
        let attestor = fixture.makeAttestor(enforcement: .enforced)

        let first = try #require(await attestor.attestation(for: makeRequest()))
        fixture.service.invalidate(first.keyID)
        fixture.service.failAssertion(with: .invalidKey)

        await #expect(throws: (any Error).self) {
            _ = try await attestor.attestation(for: makeRequest())
        }
        #expect(fixture.service.keysIssued == 2)
    }
}

// MARK: - What the assertion is bound to

@Suite("App Attest — signing")
struct AppAttestorSigningTests {

    @Test("The assertion is over this request, not over the device")
    func assertionBindsTheRequest() async throws {
        let fixture = Fixture()
        let attestor = fixture.makeAttestor()
        let request = makeRequest(method: "POST", body: Data("{\"amount\":1}".utf8))

        let attestation = try #require(await attestor.attestation(for: request))

        let challenge = try #require(fixture.server.issuedChallenges.last)
        let expected = try #require(AttestationClientData(request: request, challenge: challenge))
        #expect(attestation.clientData == expected)
        #expect(fixture.service.assertedHashes.last == expected.clientDataHash)
    }

    /// Two identical requests must not produce identical headers: the challenge
    /// is what makes an intercepted assertion useless a second time, and a
    /// client that reused one would have removed that property while every
    /// other test still passed.
    @Test("Each request is signed over a fresh challenge")
    func eachRequestGetsAFreshChallenge() async throws {
        let fixture = Fixture()
        let attestor = fixture.makeAttestor()

        let first = try #require(await attestor.attestation(for: makeRequest()))
        let second = try #require(await attestor.attestation(for: makeRequest()))

        #expect(first.clientData.challenge != second.clientData.challenge)
        #expect(first.assertion != second.assertion)
        #expect(Set(fixture.server.issuedChallenges).count == fixture.server.issuedChallenges.count)
    }

    @Test("The key registration is itself bound to a challenge")
    func registrationBindsAChallenge() async throws {
        let fixture = Fixture()
        let attestor = fixture.makeAttestor()

        _ = try await attestor.attestation(for: makeRequest())

        let registration = try #require(fixture.server.registrations.first)
        let expected = AttestationClientData(
            method: "POST",
            path: URLSessionAttestationService.keyPath,
            challenge: registration.challenge
        )
        #expect(fixture.service.attestedHashes == [expected.clientDataHash])
    }

    @Test("A challenge that has already expired is not signed")
    func expiredChallengeIsRefused() async throws {
        let fixture = Fixture()
        let attestor = AppAttestor(
            service: fixture.service,
            server: StubAttestationService(expiresAt: fixture.clock.currentDate.addingTimeInterval(-1)),
            keychain: fixture.keychain,
            reporter: fixture.reporter,
            enforcement: .enforced,
            now: fixture.clock.now
        )

        await #expect(throws: AttestationError.challengeExpired) {
            _ = try await attestor.attestation(for: makeRequest())
        }
    }
}

// MARK: - Failing

@Suite("App Attest — enforcement and the breaker")
struct AppAttestorFailureTests {

    @Test("An unsupported device sends unattested under report-only")
    func unsupportedDeviceIsReportedUnderReportOnly() async throws {
        let fixture = Fixture()
        let service = StubAppAttestService(isSupported: false)
        let attestor = AppAttestor(
            service: service,
            server: fixture.server,
            keychain: fixture.keychain,
            reporter: fixture.reporter,
            enforcement: .reportOnly,
            now: fixture.clock.now
        )

        let attestation = try await attestor.attestation(for: makeRequest())

        #expect(attestation == nil)
        #expect(fixture.reporter.events == [.unsupportedDevice(enforcement: .reportOnly)])
        #expect(service.keysIssued == 0)
    }

    @Test("An unsupported device fails the request under enforcement")
    func unsupportedDeviceThrowsUnderEnforcement() async throws {
        let fixture = Fixture()
        let attestor = AppAttestor(
            service: StubAppAttestService(isSupported: false),
            server: fixture.server,
            keychain: fixture.keychain,
            reporter: fixture.reporter,
            enforcement: .enforced,
            now: fixture.clock.now
        )

        await #expect(throws: AttestationError.unsupportedDevice) {
            _ = try await attestor.attestation(for: makeRequest())
        }
    }

    @Test("A server that cannot issue a challenge does not fail the request under report-only")
    func challengeFailureIsSwallowedUnderReportOnly() async throws {
        let fixture = Fixture()
        fixture.server.failChallenges(with: .challengeUnavailable(statusCode: 503))
        let attestor = fixture.makeAttestor()

        let attestation = try await attestor.attestation(for: makeRequest())

        #expect(attestation == nil)
    }

    @Test("A server that cannot issue a challenge fails the request under enforcement")
    func challengeFailureThrowsUnderEnforcement() async throws {
        let fixture = Fixture()
        fixture.server.failChallenges(with: .challengeUnavailable(statusCode: 503))
        let attestor = fixture.makeAttestor(enforcement: .enforced)

        await #expect(throws: AttestationError.challengeUnavailable(statusCode: 503)) {
            _ = try await attestor.attestation(for: makeRequest())
        }
    }

    /// The whole reason the breaker exists: without it, every request in an
    /// app whose attestation endpoints are down pays for a failing round trip
    /// before the real one.
    @Test("A failure suppresses the next attempt for the cooldown")
    func failureOpensTheBreaker() async throws {
        let fixture = Fixture()
        fixture.server.failChallenges(with: .challengeUnavailable(statusCode: 503))
        let attestor = fixture.makeAttestor(cooldown: 60)

        _ = try await attestor.attestation(for: makeRequest())
        let attemptsAfterFirstFailure = fixture.server.challengeAttempts
        #expect(attemptsAfterFirstFailure > 0)

        _ = try await attestor.attestation(for: makeRequest())

        #expect(fixture.server.challengeAttempts == attemptsAfterFirstFailure)
        let cooledDown = fixture.reporter.events.contains { event in
            if case .coolingDown = event { return true }
            return false
        }
        #expect(cooledDown)
    }

    @Test("The breaker closes once the cooldown has passed, and a success clears it")
    func breakerClosesAfterTheCooldown() async throws {
        let fixture = Fixture()
        fixture.server.failChallenges(with: .challengeUnavailable(statusCode: 503))
        let attestor = fixture.makeAttestor(cooldown: 60)

        _ = try await attestor.attestation(for: makeRequest())
        fixture.clock.advance(by: 61)
        fixture.server.succeedFromNowOn()

        let attestation = try #require(await attestor.attestation(for: makeRequest()))
        #expect(fixture.server.registrations.count == 1)

        let next = try #require(await attestor.attestation(for: makeRequest()))
        #expect(next.keyID == attestation.keyID)
    }

    @Test("Under enforcement a cooled-down attestor fails without a round trip")
    func breakerFailsFastUnderEnforcement() async throws {
        let fixture = Fixture()
        fixture.server.failChallenges(with: .challengeUnavailable(statusCode: 503))
        let attestor = fixture.makeAttestor(enforcement: .enforced, cooldown: 60)

        await #expect(throws: (any Error).self) {
            _ = try await attestor.attestation(for: makeRequest())
        }
        let attempts = fixture.server.challengeAttempts
        #expect(attempts > 0)

        await #expect(throws: AttestationError.unattested) {
            _ = try await attestor.attestation(for: makeRequest())
        }
        #expect(fixture.server.challengeAttempts == attempts)
    }

    @Test("An attestor that attests nothing is what the do-nothing implementation is for")
    func unattestedRequestsAttestNothing() async throws {
        let attestation = try await UnattestedRequests().attestation(for: makeRequest())
        #expect(attestation == nil)
    }
}
