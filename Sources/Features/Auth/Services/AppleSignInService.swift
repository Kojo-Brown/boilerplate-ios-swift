import AuthenticationServices
import CryptoKit
import Foundation

/// Bridges `ASAuthorizationController`'s callback-based API into async/await.
///
/// Conforms to `SocialAuthProvider` so it can be swapped with a mock in tests.
/// `@MainActor` ensures actor-isolated state is safe to access from the delegate
/// callbacks via `MainActor.assumeIsolated` — the system always calls those
/// callbacks on the main thread.
@MainActor
final class AppleSignInService: NSObject, SocialAuthProvider {
    private var continuation: CheckedContinuation<SocialAuthCredential, Error>?
    private var currentNonce: String?
    private var _presentationAnchor: ASPresentationAnchor?

    // MARK: - SocialAuthProvider

    func signIn(anchor: ASPresentationAnchor) async throws -> SocialAuthCredential {
        _presentationAnchor = anchor

        let nonce = Self.generateNonce()
        currentNonce = nonce

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self

        return try await withCheckedThrowingContinuation { [self] cont in
            self.continuation = cont
            controller.performRequests()
        }
    }

    // MARK: - Nonce helpers

    private static func generateNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var bytes = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
            for byte in bytes where remaining > 0 {
                result.append(charset[Int(byte) % charset.count])
                remaining -= 1
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension AppleSignInService: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        // The system calls this on the main thread. `MainActor.assumeIsolated`
        // provides Swift 6-safe access to `@MainActor`-isolated stored properties.
        MainActor.assumeIsolated {
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let token = String(data: tokenData, encoding: .utf8),
                let codeData = credential.authorizationCode,
                let code = String(data: codeData, encoding: .utf8),
                let nonce = currentNonce
            else {
                continuation?.resume(throwing: SocialAuthError.invalidCredential)
                continuation = nil
                return
            }

            continuation?.resume(returning: .apple(
                identityToken: token,
                authorizationCode: code,
                nonce: nonce,
                fullName: credential.fullName
            ))
            continuation = nil
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        MainActor.assumeIsolated {
            let mapped: Error
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                mapped = SocialAuthError.userCancelled
            } else {
                mapped = error
            }
            continuation?.resume(throwing: mapped)
            continuation = nil
        }
    }
}

// MARK: - ASAuthorizationControllerPresentationContextProviding

extension AppleSignInService: ASAuthorizationControllerPresentationContextProviding {
    // Called synchronously on the main thread before the auth sheet appears.
    nonisolated func presentationAnchor(
        for controller: ASAuthorizationController
    ) -> ASPresentationAnchor {
        MainActor.assumeIsolated { _presentationAnchor ?? ASPresentationAnchor() }
    }
}
