import Foundation
import Security

// MARK: - KeychainAccessPolicy

/// How hard it is to read a Keychain item back: when the device has to be in,
/// and who has to prove they are there.
///
/// Every write through `KeychainStoring` names one of these. There is no
/// default and no convenience overload that omits it, because the attribute it
/// chooses is invisible afterwards — `SecItemCopyMatching` will not hand back
/// an item's access control, and `SecAccessControl` exposes no public accessor
/// for its constraints, so a write that quietly picked the weakest protection
/// is unobservable from the running app. The only place it is legible is the
/// call site, which is why the call site has to say it.
///
/// ## The two halves
///
/// An item carries an *accessibility* attribute and, optionally, an *access
/// control*. They are not alternatives that overlap: `kSecAttrAccessible` says
/// which device states allow the data out at all, and `SecAccessControl` adds
/// an authentication requirement on top of one of those states. The two cannot
/// both be set in the same `SecItemAdd` — passing `kSecAttrAccessible` beside
/// `kSecAttrAccessControl` is `errSecParam` — so the gated cases below carry
/// their accessibility *inside* the access control, and `KeychainWrapper`
/// writes one attribute or the other.
///
/// ## Why every gated case is `WhenPasscodeSetThisDeviceOnly`
///
/// A biometric or passcode constraint is only as durable as the passcode it
/// rests on. `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` is the one
/// accessibility whose item is destroyed when the user removes their passcode,
/// which is exactly the event that would otherwise leave a "protected" item
/// readable with no authentication left to perform. It also never enters a
/// backup, iCloud Keychain, or a restored device. Apple's own sample code pairs
/// the two for the same reason.
///
/// The consequence is worth stating plainly: **a device with no passcode cannot
/// hold a gated item at all.** `SecItemAdd` fails, and a caller that treats
/// that failure as fatal has made passcode-less devices unable to sign in. See
/// `TokenStore.biometricUnlock` for how that is handled here.
package enum KeychainAccessPolicy: Sendable, Hashable, CaseIterable {

    /// Readable once the device has been unlocked at least once since boot.
    /// No authentication. This is what a session token needs: a background
    /// refresh at 04:00 runs with the device locked and nobody to ask.
    case afterFirstUnlockThisDeviceOnly

    /// Readable only while the device is unlocked. No authentication.
    /// For data the app reads in the foreground and never from the background.
    case whenUnlockedThisDeviceOnly

    /// Biometry *or* the device passcode. The broadest gate: it succeeds for a
    /// user with no biometric hardware, no enrolment, or a finger the sensor
    /// cannot read today.
    case userPresence

    /// Any currently enrolled biometric. Adding a new face or finger does not
    /// invalidate the item, so anybody who can enrol on the device can read it.
    case biometryAny

    /// The biometric set exactly as it was enrolled when the item was written.
    /// Enrolling another face or finger — the move an attacker with the
    /// passcode would make — destroys the item rather than granting access.
    case biometryCurrentSet

    /// `biometryCurrentSet`, with the device passcode as a fallback.
    ///
    /// The pairing the app ships with. `biometryCurrentSet` alone locks out a
    /// user whose biometry stops working (a bandaged finger, a re-enrolment
    /// they did for an unrelated reason) with no way back in; adding the
    /// passcode keeps the re-enrolment defence — the new biometric set is not
    /// accepted — while leaving a route that does not end in "reinstall".
    case biometryCurrentSetOrPasscode

    /// The device passcode only. Biometry is not offered even when enrolled.
    case devicePasscode

    // MARK: - Classification

    /// Whether reading the item demands an authentication event.
    ///
    /// `KeychainWrapper` uses this to decide which attribute to write, and
    /// `TokenStore` uses it to refuse to protect the biometric unlock record
    /// with a policy that protects nothing.
    package var requiresAuthentication: Bool {
        switch self {
        case .afterFirstUnlockThisDeviceOnly, .whenUnlockedThisDeviceOnly:
            false
        case .userPresence, .biometryAny, .biometryCurrentSet, .biometryCurrentSetOrPasscode, .devicePasscode:
            true
        }
    }

    /// Whether enrolling a new face or finger destroys the item.
    ///
    /// True only for the two `biometryCurrentSet` cases. `biometryAny` and
    /// `userPresence` accept whatever is enrolled at read time, which is the
    /// property that makes them unsuitable for anything an attacker who has
    /// the passcode should not be able to reach.
    package var invalidatedByBiometricEnrolment: Bool {
        switch self {
        case .biometryCurrentSet, .biometryCurrentSetOrPasscode:
            true
        case .afterFirstUnlockThisDeviceOnly, .whenUnlockedThisDeviceOnly,
             .userPresence, .biometryAny, .devicePasscode:
            false
        }
    }

    // MARK: - Keychain attributes

    /// The `kSecAttrAccessible` value this policy rests on.
    ///
    /// For a gated case this is the accessibility handed to
    /// `SecAccessControlCreateWithFlags` rather than written as its own
    /// attribute — see the type's documentation for why both cannot be set.
    package var accessibility: CFString {
        switch self {
        case .afterFirstUnlockThisDeviceOnly:
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .whenUnlockedThisDeviceOnly:
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .userPresence, .biometryAny, .biometryCurrentSet, .biometryCurrentSetOrPasscode, .devicePasscode:
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        }
    }

    /// The constraint flags for this policy, empty when it is not gated.
    package var accessControlFlags: SecAccessControlCreateFlags {
        switch self {
        case .afterFirstUnlockThisDeviceOnly, .whenUnlockedThisDeviceOnly:
            []
        case .userPresence:
            .userPresence
        case .biometryAny:
            .biometryAny
        case .biometryCurrentSet:
            .biometryCurrentSet
        case .biometryCurrentSetOrPasscode:
            [.biometryCurrentSet, .or, .devicePasscode]
        case .devicePasscode:
            .devicePasscode
        }
    }

    /// Builds the `SecAccessControl` for a gated policy, or `nil` for one that
    /// needs no authentication.
    ///
    /// - Returns: `nil` when `requiresAuthentication` is `false`, which is the
    ///   signal to `KeychainWrapper` to write `kSecAttrAccessible` instead.
    /// - Throws: `KeychainError.unhandledError` carrying the `CFError`'s code
    ///   when the flags are not a combination this platform accepts.
    package func makeAccessControl() throws -> SecAccessControl? {
        guard requiresAuthentication else { return nil }

        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(
            nil,
            accessibility,
            accessControlFlags,
            &error
        ) else {
            // `CFErrorGetCode` is a `CFIndex`; the Security domain puts an
            // `OSStatus` in it, but truncate rather than trap if some other
            // domain ever answers here.
            let code = error.map { OSStatus(truncatingIfNeeded: CFErrorGetCode($0.takeRetainedValue())) }
            throw KeychainError.unhandledError(status: code ?? errSecParam)
        }
        return control
    }
}
