import Foundation
import Testing
@testable import BoilerplateiOSSwift

// MARK: - The audit primitive

/// Records `type` in the audit, and — the point of the exercise — requires it to
/// be `Sendable` in order to compile at all.
///
/// Swift 6 checks `Sendable` at every use site, which sounds like enough until
/// you notice what it does *not* check: a type nothing has yet sent across an
/// isolation boundary is never asked whether it could be. Most types here get
/// their conformance by inference — an internal struct whose stored properties
/// all happen to be `Sendable` is `Sendable` too, silently, with nothing in the
/// source saying so. Add one `NSMutableArray` property and the conformance
/// disappears just as silently. Nothing fails until some distant future call
/// site tries to send it, and then the error lands there rather than on the
/// property that caused it.
///
/// Naming the type here turns that inference into a stated requirement. The
/// failure mode becomes a compile error in this file, pointing at the type whose
/// conformance was lost.
private func auditSendable<T: Sendable>(_ type: T.Type) -> String {
    String(describing: type)
}

/// Every audited name must be distinct, so a copy-paste that repeats a line
/// cannot pad the count in place of a type that was dropped.
private func expectAudit(_ audited: [String], count: Int) {
    #expect(audited.count == count)
    #expect(Set(audited).count == audited.count)
}

// MARK: - Tests

@Suite("Sendable conformance audit")
struct SendableConformanceTests {

    /// The wire and domain models. These all declare `Sendable` explicitly
    /// today; the audit is what stops one of them from quietly losing it.
    @Test("Model and value types are Sendable")
    func modelTypesAreSendable() {
        let audited = [
            auditSendable(User.self),
            auditSendable(APIResponse<User>.self),
            auditSendable(APIResponseError.self),
            auditSendable(ResponseMeta.self),
            auditSendable(Page<User>.self),
            auditSendable(PageInfo.self),
            auditSendable(CursorPage<User>.self),
            auditSendable(CursorInfo.self),
            auditSendable(TokenPair.self),
            auditSendable(TokenRefreshRequest.self),
            auditSendable(HTTPMethod.self),
            auditSendable(APIEndpoint.self),
            auditSendable(EmptyResponse.self),
            auditSendable(APIError.self),
            auditSendable(LoginRequest.self),
            auditSendable(LoginResponse.self),
            auditSendable(UpdateProfileRequest.self),
            auditSendable(SocialLoginRequest.self),
            auditSendable(SocialAuthCredential.self),
            auditSendable(SocialAuthError.self),
            auditSendable(RecognizedTextBlock.self),
            auditSendable(RecognitionResult.self),
            auditSendable(BarcodeSymbology.self),
            auditSendable(DetectedBarcode.self),
            auditSendable(ScanResult.self),
            auditSendable(AppColorScheme.self),
            auditSendable(AppEvent.self),
            auditSendable(BiometricType.self),
            auditSendable(BiometricAuthError.self),
            auditSendable(KeychainError.self),
            auditSendable(KeychainWrapper.self),
            auditSendable(FieldUpdate<String>.self),
            // Conditional and *unchecked*: the conformance rests on the
            // uniqueness check in `makeUnique()`, not on anything the compiler
            // re-verifies. Auditing it here pins the other half of the promise —
            // that the conformance is conditional on `Value` and has not been
            // widened to every payload.
            auditSendable(CopyOnWriteBox<[Int]>.self),
        ]
        expectAudit(audited, count: 33)
    }

    /// Types that are `Sendable` only by inference — nothing in their
    /// declaration says so, so nothing but this list would notice it going away.
    ///
    /// `LoadingState` is here as a conditional conformance: it is `Sendable`
    /// when its `Value` is, which is why it is audited at a concrete `Value`
    /// rather than as a bare generic.
    ///
    /// `LatestOnlyTask` is here for a different reason: it is a `class`, and
    /// classes are not `Sendable` by inference — this one is only because it is
    /// `@MainActor`-isolated, which makes the conformance implicit. Dropping the
    /// global actor from it would leave a mutable reference type that view
    /// models hold and hand closures to, with nothing in the source saying the
    /// conformance had gone.
    ///
    /// The four diagnostics classes are the same case as `LatestOnlyTask` and
    /// the reason it generalises: they are `Sendable` only because they are
    /// isolated to `@DiagnosticsActor`. `FileDiagnosticSink` holds a
    /// `FileHandle`, which is not `Sendable` and never will be, so the moment
    /// that annotation comes off, the class stops being sendable and the journal
    /// that stores it as `any DiagnosticSink` stops with it.
    ///
    /// `SerialDispatchExecutor` is audited because its conformance is
    /// *load-bearing and easy to lose*: `Executor` inherits `Sendable`, so the
    /// class only compiles at all while every stored property is an immutable
    /// `Sendable` one. Adding a mutable `var` for, say, a job counter would turn
    /// a checked conformance into a demand for `@unchecked Sendable` — the exact
    /// slide the audit script polices from the other side.
    @Test("Types that rely on inferred conformance still have it")
    func inferredConformancesHold() {
        let audited = [
            auditSendable(Route.self),
            auditSendable(LoadingState<User>.self),
            auditSendable(UserRepositoryError.self),
            auditSendable(PersistenceError.self),
            auditSendable(CameraError.self),
            auditSendable(TextRecognitionError.self),
            auditSendable(AuthError.self),
            auditSendable(LatestOnlyTask<Int>.self),
            auditSendable(DiagnosticRecord.self),
            auditSendable(DiagnosticCategory.self),
            auditSendable(DiagnosticSinkError.self),
            auditSendable(SerialDispatchExecutor.self),
            auditSendable(DiagnosticJournal.self),
            auditSendable(DiagnosticBudget.self),
            auditSendable(InMemoryDiagnosticSink.self),
            auditSendable(FileDiagnosticSink.self),
        ]
        expectAudit(audited, count: 16)
    }

    /// The service layer: the protocols that cross isolation boundaries, and
    /// every type that implements one.
    ///
    /// The existentials matter as much as the concrete types. `any APIClient` is
    /// `Sendable` because `APIClient` inherits `Sendable`, and that is what lets
    /// `LiveUserRepository` hold one as a stored property and stay `Sendable`
    /// itself. Drop `Sendable` from the protocol and every repository holding
    /// one loses its own conformance — an edit to one line with consequences
    /// several files away, which is exactly the kind this list is here to catch.
    ///
    /// The doubles are the reason this suite exists. Four of them asserted
    /// `@unchecked Sendable` over bare mutable stored properties, which is a
    /// data race the compiler had been instructed not to look at.
    @Test("Services, doubles, and their existentials are Sendable")
    func serviceLayerIsSendable() {
        let audited = [
            auditSendable((any APIClient).self),
            auditSendable((any UserRepository).self),
            auditSendable((any UserPersistenceService).self),
            auditSendable((any KeychainStoring).self),
            auditSendable((any BiometricAuthProvider).self),
            auditSendable((any AuthServiceProtocol).self),
            auditSendable((any SocialAuthProvider).self),
            auditSendable((any SocialAuthExchangeService).self),
            auditSendable((any TextRecognizing).self),
            auditSendable((any BarcodeScanning).self),
            auditSendable(TokenStore.self),
            auditSendable(EventBus.self),
            auditSendable(URLSessionAPIClient.self),
            auditSendable(LiveUserRepository.self),
            auditSendable(LiveAuthService.self),
            auditSendable(LiveSocialAuthExchangeService.self),
            auditSendable(LiveBiometricAuthService.self),
            auditSendable(LiveTextRecognitionService.self),
            auditSendable(LiveBarcodeScannerService.self),
            auditSendable(MockAPIClient.self),
            auditSendable(MockBiometricAuthService.self),
            auditSendable(MockSocialAuthProvider.self),
            auditSendable(MockSocialAuthExchangeService.self),
            auditSendable(MockAuthService.self),
            auditSendable(MockTextRecognitionService.self),
            auditSendable(MockBarcodeScannerService.self),
            auditSendable(MockUserRepository.self),
            auditSendable(MockUserPersistenceService.self),
            auditSendable(SwiftDataUserPersistenceService.self),
        ]
        expectAudit(audited, count: 29)
    }

    /// The doubles this item converted off `@unchecked Sendable` are now
    /// safe to configure and read concurrently — that was the whole claim, so
    /// exercise it rather than only asserting the conformance compiles.
    ///
    /// This is not a race detector: a passing run does not prove the absence of
    /// a race, and the old `@unchecked` version would very likely have passed
    /// too. What it does prove is that the lock-backed rewrite kept the
    /// behaviour — every increment is counted, no write is lost — which is the
    /// part a reader would otherwise have to take on faith.
    ///
    /// The shape is a few tasks looping, not one task per call. Contention on
    /// the lock is what is under test, and repeated hammering from a handful of
    /// tasks produces more of it than a wide fan-out does. The width matters
    /// separately: Swift Testing runs suites in parallel, so a task group as
    /// wide as the call count saturates the cooperative pool and starves
    /// whatever is running beside it — here, the `@MainActor` wall-clock tests
    /// in `HomeViewModelConcurrencyTests`, whose four sleeps total ~0.7s and
    /// which took 40s and failed when this test fanned out to 200 tasks.
    @Test("Concurrent configuration of a lock-backed double loses no writes")
    func concurrentMockAccessIsCoherent() async {
        let mock = MockBiometricAuthService()
        let writers = 8
        let callsPerWriter = 25

        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<writers {
                group.addTask {
                    for call in 0..<callsPerWriter {
                        // Interleave reads, writes and recorded calls on
                        // purpose: each one takes the same lock, from a
                        // different task.
                        mock.stubbedIsAvailable = call.isMultiple(of: 2)
                        _ = mock.biometricType
                        try? await mock.authenticate(reason: "Unlock \(writer)")
                    }
                }
            }
        }

        #expect(mock.authenticateCallCount == writers * callsPerWriter)
        #expect(mock.lastReason?.hasPrefix("Unlock ") == true)
    }
}
