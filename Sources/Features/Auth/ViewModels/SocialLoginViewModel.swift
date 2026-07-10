import AuthenticationServices
import CryptoKit
import Foundation
import Observation

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
final class SocialLoginViewModel {
    var isLoadingApple = false
    var isLoadingGoogle = false
    var errorMessage: String?
    var isAuthenticated = false

    var isLoading: Bool { isLoadingApple || isLoadingGoogle }

    private(set) var appleNonceHash: String = ""
    private var appleNonce: String = ""

    private let googleProvider: any SocialAuthProvider
    private let exchangeService: any SocialAuthExchangeService

    init(
        googleProvider: any SocialAuthProvider = GoogleSignInService(),
        exchangeService: any SocialAuthExchangeService = LiveSocialAuthExchangeService()
    ) {
        self.googleProvider = googleProvider
        self.exchangeService = exchangeService
    }

    // MARK: - Apple Sign-In

    /// Call before presenting `SignInWithAppleButton` to refresh the nonce.
    /// Assign `appleNonceHash` to `request.nonce` in the button's request closure.
    func prepareAppleNonce() {
        let nonce = Self.generateNonce()
        appleNonce = nonce
        appleNonceHash = Self.sha256(nonce)
    }

    /// Processes the `ASAuthorization` delivered by `SignInWithAppleButton.onCompletion`.
    func handleAppleResult(_ result: Result<ASAuthorization, Error>) async {
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
            _ = try await exchangeService.exchange(socialCredential)
            isAuthenticated = true
        } catch let error as ASAuthorizationError where error.code == .canceled {
            // User dismissed — no error message needed.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Google Sign-In

    func signInWithGoogle(anchor: ASPresentationAnchor) async {
        guard !isLoading else { return }
        isLoadingGoogle = true
        errorMessage = nil
        defer { isLoadingGoogle = false }

        do {
            let credential = try await googleProvider.signIn(anchor: anchor)
            _ = try await exchangeService.exchange(credential)
            isAuthenticated = true
        } catch let error as SocialAuthError where error == .userCancelled {
            // User dismissed — no error message needed.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearError() {
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
