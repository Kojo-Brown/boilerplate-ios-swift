import AuthenticationServices
import Core
import CryptoKit
import Foundation
import Observation
import Security

/// Manages state for Sign in with Apple and Google Sign-In flows.
///
/// Apple flow: call `prepareAppleNonce()` to get the SHA-256 nonce hash to
/// embed in the `ASAuthorizationAppleIDRequest`, then pass the resulting
/// `ASAuthorization` to `handleAppleResult(_:)`.
///
/// Google flow: call `signInWithGoogle(anchor:)` — it is fully async and drives
/// the picker UI through `GoogleSignInService`.
@Observable
@MainActor
package final class SocialLoginViewModel {
    package var isLoadingApple = false
    package var isLoadingGoogle = false
    package var errorMessage: String?
    package var isAuthenticated = false

    package var isLoading: Bool { isLoadingApple || isLoadingGoogle }

    private(set) var appleNonceHash: String = ""
    private var appleNonce: String = ""

    private let googleProvider: any SocialAuthProvider
    private let exchangeService: any SocialAuthExchangeService
    private let events: any EventPublishing

    /// Built by `AppContainer.makeSocialLoginViewModel()`; no defaults, so the
    /// identity provider that runs is named in one place rather than here.
    package init(
        googleProvider: any SocialAuthProvider,
        exchangeService: any SocialAuthExchangeService,
        events: any EventPublishing
    ) {
        self.googleProvider = googleProvider
        self.exchangeService = exchangeService
        self.events = events
    }

    // MARK: - Apple Sign-In

    /// Call before presenting `SignInWithAppleButton` to refresh the nonce.
    /// Assign `appleNonceHash` to `request.nonce` in the button's request closure.
    package func prepareAppleNonce() {
        let nonce = Self.generateNonce()
        appleNonce = nonce
        appleNonceHash = Self.sha256(nonce)
    }

    /// Processes the `ASAuthorization` delivered by `SignInWithAppleButton.onCompletion`.
    package func handleAppleResult(_ result: Result<ASAuthorization, Error>) async {
        guard !isLoading else { return }
        isLoadingApple = true
        errorMessage = nil
        defer { isLoadingApple = false }

        do {
            let auth = try result.get()
            guard
                let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let token = String(data: tokenData, encoding: .utf8),
                let codeData = credential.authorizationCode,
                let code = String(data: codeData, encoding: .utf8)
            else {
                throw SocialAuthError.invalidCredential
            }

            let socialCredential = SocialAuthCredential.apple(
                identityToken: token,
                authorizationCode: code,
                nonce: appleNonce,
                fullName: credential.fullName
            )
            // Bound rather than discarded. The exchange has always answered with
            // a `LoginResponse` carrying the signed-in `User`, and `_ =` threw
            // it away — which is half of why `AppState.currentUserEmail` was
            // never set by anything.
            let session = try await exchangeService.exchange(socialCredential)
            isAuthenticated = true
            events.publish(UserSignedIn(method: .apple, email: session.user.email))
        } catch let error as ASAuthorizationError where error.code == .canceled {
            // User dismissed — no error message needed.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Google Sign-In

    package func signInWithGoogle(anchor: ASPresentationAnchor) async {
        guard !isLoading else { return }
        isLoadingGoogle = true
        errorMessage = nil
        defer { isLoadingGoogle = false }

        do {
            let credential = try await googleProvider.signIn(anchor: anchor)
            let session = try await exchangeService.exchange(credential)
            isAuthenticated = true
            events.publish(UserSignedIn(method: .google, email: session.user.email))
        } catch let error as SocialAuthError where error == .userCancelled {
            // User dismissed — no error message needed.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    package func clearError() {
        errorMessage = nil
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
