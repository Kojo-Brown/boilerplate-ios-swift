import Foundation

// MARK: - Error vocabulary

/// The sentences the feature-level errors resolve to.
///
/// Separated from the screen strings in `FeatureStrings.swift` only for file
/// length; `featureString(_:_:)` is shared between the two and is declared
/// there.
///
/// These are the strings behind `errorDescription`, which is a `String` and not
/// a `Text` — so each one is resolved with ``LocalizedStringResource/string``
/// at the point the error is asked to describe itself, rather than at the point
/// it is constructed. An error value can be built on a background task, held in
/// a `Result`, and rendered minutes later; resolving on construction would pin
/// the sentence to whatever locale happened to be current at the time.
extension FeatureStrings {

    package enum AuthError {

        package static var invalidCredentials: LocalizedStringResource {
            featureString("error.auth.invalidCredentials", "Sign-in rejected; does not say which half was wrong.")
        }

        package static var networkUnavailable: LocalizedStringResource {
            featureString("error.auth.networkUnavailable", "The sign-in request never reached the server.")
        }
    }

    package enum SocialError {

        package static var invalidCredential: LocalizedStringResource {
            featureString("error.social.invalidCredential", "The identity provider returned something unusable.")
        }

        package static var userCancelled: LocalizedStringResource {
            featureString("error.social.userCancelled", "The reader dismissed the provider's sheet.")
        }

        package static var notConfigured: LocalizedStringResource {
            featureString("error.social.notConfigured", "The provider has no client id in this build.")
        }

        package static var tokenExchangeFailed: LocalizedStringResource {
            featureString("error.social.tokenExchangeFailed", "This app's server rejected the provider's token.")
        }
    }

    package enum CameraError {

        package static var notAuthorized: LocalizedStringResource {
            featureString("error.camera.notAuthorized", "Camera access is denied; names system screens.")
        }

        package static var deviceUnavailable: LocalizedStringResource {
            featureString("error.camera.deviceUnavailable", "There is no camera to capture from.")
        }

        package static var configurationFailed: LocalizedStringResource {
            featureString("error.camera.configurationFailed", "The capture session could not be assembled.")
        }
    }

    package enum RecognitionError {

        package static var noResult: LocalizedStringResource {
            featureString("error.textRecognition.noResult", "The pass completed and found nothing.")
        }

        /// - Parameter reason: Vision's own message.
        package static func processingFailed(_ reason: String) -> LocalizedStringResource {
            featureString("error.textRecognition.processingFailed \(reason)", "%@ is Vision's own message.")
        }
    }

    package enum BarcodeError {

        /// - Parameter reason: Vision's own message.
        package static func processingFailed(_ reason: String) -> LocalizedStringResource {
            featureString("error.barcode.processingFailed \(reason)", "%@ is Vision's own message.")
        }
    }
}
