import AuthenticationServices
import GoogleSignIn
import UIKit

/// Wraps `GIDSignIn`'s callback-based API in async/await.
///
/// **Setup required in your App struct:**
/// ```swift
/// GoogleSignInService.configure(clientID: "YOUR_GOOGLE_CLIENT_ID")
/// ```
/// **And handle the redirect URL:**
/// ```swift
/// .onOpenURL { url in GIDSignIn.sharedInstance.handle(url) }
/// ```
/// The `CLIENT_ID` value comes from `GoogleService-Info.plist` (key: `CLIENT_ID`).
@MainActor
package final class GoogleSignInService: SocialAuthProvider {
    package init() {}

    // MARK: - Configuration

    package static func configure(clientID: String) {
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
    }

    // MARK: - SocialAuthProvider

    package func signIn(anchor: ASPresentationAnchor) async throws -> SocialAuthCredential {
        guard
            let clientID = GIDSignIn.sharedInstance.configuration?.clientID,
            !clientID.isEmpty
        else {
            throw SocialAuthError.notConfigured
        }

        guard let presentingVC = topViewController(from: anchor) else {
            throw SocialAuthError.notConfigured
        }

        return try await withCheckedThrowingContinuation { continuation in
            GIDSignIn.sharedInstance.signIn(withPresenting: presentingVC) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard
                    let result,
                    let idToken = result.user.idToken?.tokenString
                else {
                    continuation.resume(throwing: SocialAuthError.invalidCredential)
                    return
                }
                continuation.resume(returning: .google(
                    idToken: idToken,
                    accessToken: result.user.accessToken.tokenString
                ))
            }
        }
    }

    // MARK: - Session restoration

    /// Re-authenticates a previously signed-in Google user without showing the picker.
    package func restorePreviousSignIn() async throws -> SocialAuthCredential {
        try await withCheckedThrowingContinuation { continuation in
            GIDSignIn.sharedInstance.restorePreviousSignIn { user, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard
                    let user,
                    let idToken = user.idToken?.tokenString
                else {
                    continuation.resume(throwing: SocialAuthError.invalidCredential)
                    return
                }
                continuation.resume(returning: .google(
                    idToken: idToken,
                    accessToken: user.accessToken.tokenString
                ))
            }
        }
    }

    // MARK: - Helpers

    private func topViewController(from window: UIWindow) -> UIViewController? {
        var controller: UIViewController? = window.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}
